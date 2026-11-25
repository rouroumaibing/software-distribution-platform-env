#!/usr/bin/env bash
# gate-cloud.sh — 云上验收总 gate（只编排，不重写断言、不部署、不清理）。
# 串联四个 e2e 脚本，逐条 tee 证据到 gate-evidence/<UTC>/，解析结尾 RESULT 行的 FAIL 数判定：
# FAIL>0、无 RESULT 行或脚本非 0 退出即停（smoke/cancel-rerun 恒返回 0，只看退出码会漏判）。
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 变量入口：均可由环境变量覆盖（与四个 e2e 脚本默认值对齐） ----------
BASE="${BASE:-https://www.sdpworkflow.com/api/v1}"
TOKEN="${TOKEN:-}"
KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
STABLE_IMG="${STABLE_IMG:-swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx-canary:v0.0.1}"
CANARY_IMG="${CANARY_IMG:-swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx-canary:v0.0.2}"
KC_ISSUER="${KC_ISSUER:-https://www.sdpworkflow.com/keycloak/realms/sdp}"
KC_CLIENT="${KC_CLIENT:-sdp-console}"
KC_USER="${KC_USER:-admin}"
KC_PASS="${KC_PASS:-sdp@12345}"
CURL="${CURL:-curl -sk}"   # 可含参数，故按词展开
export BASE TOKEN KUBECONFIG STABLE_IMG CANARY_IMG KC_ISSUER KC_CLIENT KC_USER KC_PASS CURL
export no_proxy="${no_proxy:-*}" NO_PROXY="${NO_PROXY:-*}"

usage() {
    cat <<USAGE
用法: ./gate-cloud.sh [--only=<name>] [-h|--help]

云上验收总 gate：按 smoke -> cancel-rerun -> canary -> example 顺序串行执行（前者是后者的
前置，不可换序）。每步 stdout/stderr tee 到 gate-evidence/<UTC>/<script>.log；判定只认结尾
的 RESULT: PASS=n FAIL=m 行——FAIL>0、无 RESULT 行或脚本非 0 退出即停，汇总写入同目录
summary.txt。只编排，不重写断言、不部署、不清理。

选项:
  --only=<name>      只跑指定步骤演练；name 取 smoke|cancel-rerun|canary|example
                      （可逗号分隔多个，如 --only=canary,example）
  -h, --help         显示本帮助

可由环境变量覆盖（默认值即四个 e2e 脚本的云上默认值）:
  BASE                API 基址，默认 ${BASE}
  TOKEN               访问令牌；留空则预检动态获取能力（KC_* 可调）
  KUBECONFIG         kubeconfig 路径，默认 ${KUBECONFIG}（仅 canary/example 需要）
  STABLE_IMG         稳定版镜像，默认 ${STABLE_IMG}
  CANARY_IMG         灰度版镜像，默认 ${CANARY_IMG}
  KC_ISSUER / KC_CLIENT / KC_USER / KC_PASS   动态换取 token 的 Keycloak 参数
  CURL               curl 调用串，默认 ${CURL}

示例:
  ./gate-cloud.sh                          # 全量四步
  ./gate-cloud.sh --only=smoke             # 单项演练
  ./gate-cloud.sh --only=canary,example    # 指定多步
  STABLE_IMG=swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx-canary:v0.0.1 \\
  CANARY_IMG=swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx-canary:v0.0.2 \\
  ./gate-cloud.sh --only=canary
USAGE
}

# ---------- 参数解析 ----------
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only=*)    ONLY="${1#--only=}"; shift ;;
        --only)      [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数" >&2; usage; exit 1; }; ONLY="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "错误: 未知参数 $1" >&2; usage; exit 1 ;;
    esac
done

# 步骤名 -> 脚本名
script_for() {
    case "$1" in
        smoke)        echo "e2e-smoke.sh" ;;
        cancel-rerun) echo "e2e-cancel-rerun.sh" ;;
        canary)       echo "e2e-canary.sh" ;;
        example)      echo "e2e-example-release.sh" ;;
        *)            return 1 ;;
    esac
}

ALL_STEPS=(smoke cancel-rerun canary example)
SELECTED=()
if [[ -z "${ONLY}" ]]; then
    SELECTED=("${ALL_STEPS[@]}")
else
    IFS=',' read -r -a wanted <<< "${ONLY}"
    for w in "${wanted[@]}"; do
        w="${w#"${w%%[![:space:]]*}"}"
        w="${w%"${w##*[![:space:]]}"}"
        [[ -z "$w" ]] && continue
        if ! script_for "$w" >/dev/null; then
            echo "错误: --only 未知步骤 '$w'（可选: smoke|cancel-rerun|canary|example）" >&2
            exit 1
        fi
        SELECTED+=("$w")
    done
    [[ ${#SELECTED[@]} -gt 0 ]] || { echo "错误: --only 未指定有效步骤" >&2; exit 1; }
fi

# ---------- 证据目录与汇总 ----------
UTC="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${HERE}/gate-evidence/${UTC}"
mkdir -p "${EVIDENCE_DIR}"
SUMMARY_FILE="${EVIDENCE_DIR}/summary.txt"
SELECTED_STR="$(IFS=,; echo "${SELECTED[*]}")"

log() { echo "[gate] $*"; }

summary_fail() {
    echo "OVERALL: FAIL ($1)" >> "${SUMMARY_FILE}"
    echo "证据目录: ${EVIDENCE_DIR}"
    echo "[gate] 失败: $1" >&2
    exit 1
}

{
    echo "# gate-cloud 云上验收汇总"
    echo "生成时间(UTC): ${UTC}"
    echo "BASE: ${BASE}"
    echo "KUBECONFIG: ${KUBECONFIG}"
    echo "STABLE_IMG: ${STABLE_IMG}"
    echo "CANARY_IMG: ${CANARY_IMG}"
    echo "步骤: ${SELECTED_STR}"
    echo "--- 逐步结果 ---"
} > "${SUMMARY_FILE}"

log "证据目录: ${EVIDENCE_DIR}"
log "步骤: ${SELECTED_STR}"

# ---------- 预检 ----------
log "预检 1/3: BASE 探活 ${BASE}/targets"
if ! ${CURL} -o /dev/null --max-time 5 "${BASE}/targets"; then
    summary_fail "BASE 不可达: ${BASE}"
fi
log "BASE 探活通过"

NEED_K8S=0
for s in "${SELECTED[@]}"; do
    [[ "$s" == "canary" || "$s" == "example" ]] && NEED_K8S=1
done
if [[ "$NEED_K8S" -eq 1 ]]; then
    log "预检 2/3: kubectl / KUBECONFIG"
    command -v kubectl >/dev/null 2>&1 || summary_fail "未找到 kubectl（canary/example 必需）"
    [[ -r "${KUBECONFIG}" ]] || summary_fail "KUBECONFIG 不可读: ${KUBECONFIG}"
    log "kubectl / KUBECONFIG 预检通过"
else
    log "预检 2/3: 本轮步骤无需 kubectl，跳过"
fi

log "预检 3/3: TOKEN 获取能力"
if [[ -n "${TOKEN}" ]]; then
    log "使用环境变量提供的 TOKEN（长度 ${#TOKEN}）"
else
    TOK="$(${CURL} -s --max-time 10 "${KC_ISSUER}/protocol/openid-connect/token" \
        -d grant_type=password -d client_id="${KC_CLIENT}" \
        -d username="${KC_USER}" -d password="${KC_PASS}" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)"
    [[ -n "${TOK}" ]] || summary_fail "TOKEN 获取失败（${KC_ISSUER} client=${KC_CLIENT} user=${KC_USER}）"
    log "TOKEN 动态获取预检通过（${KC_ISSUER}）"
fi

# ---------- 串行执行 ----------
OVERALL="PASS"
for step in "${SELECTED[@]}"; do
    script_name="$(script_for "$step")"
    script_path="${HERE}/${script_name}"
    logfile="${EVIDENCE_DIR}/${script_name}.log"
    [[ -f "${script_path}" ]] || summary_fail "脚本不存在: ${script_path}"

    log "==> 执行 ${step}: ${script_name}（日志: ${logfile}）"
    bash "${script_path}" 2>&1 | tee "${logfile}"
    rc=${PIPESTATUS[0]}

    result_line="$(grep -E '^RESULT: PASS=[0-9]+ FAIL=[0-9]+' "${logfile}" | tail -n 1 || true)"
    pass_n="?"; fail_n="?"
    if [[ "${result_line}" =~ PASS=([0-9]+)[[:space:]]+FAIL=([0-9]+) ]]; then
        pass_n="${BASH_REMATCH[1]}"
        fail_n="${BASH_REMATCH[2]}"
    fi

    verdict="PASS"; reason=""
    if [[ "${rc}" -ne 0 ]]; then reason="exit=${rc}"; fi
    if [[ -z "${result_line}" ]]; then
        reason="${reason:+$reason; }无 RESULT 行"
    elif [[ "${fail_n}" -gt 0 ]]; then
        reason="${reason:+$reason; }FAIL=${fail_n}"
    fi
    [[ -z "${reason}" ]] || verdict="FAIL"

    step_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "[${verdict}] ${step} | RESULT=${result_line:-N/A} | rc=${rc} | PASS=${pass_n} FAIL=${fail_n} | time=${step_time} | STABLE_IMG=${STABLE_IMG} CANARY_IMG=${CANARY_IMG} | log=${logfile}" >> "${SUMMARY_FILE}"

    if [[ "${verdict}" == "FAIL" ]]; then
        OVERALL="FAIL"
        log "${step} 未通过（${reason}），停止后续步骤"
        break
    fi
    log "${step} 通过（${result_line}）"
done

echo "--- 总判定 ---" >> "${SUMMARY_FILE}"
echo "OVERALL: ${OVERALL}" >> "${SUMMARY_FILE}"
echo "证据目录: ${EVIDENCE_DIR}"
echo "[gate] 总判定: ${OVERALL}"
[[ "${OVERALL}" == "PASS" ]]
