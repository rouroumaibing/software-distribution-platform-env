#!/bin/bash
# deploy-without-harbor.sh — 云上 SDP 平台一键部署（无需 harbor 的自签/任意 registry 路径）。
#
# 与 hce-2.0-64bit-deploy.sh 的差异：
#   - 不要求镜像事先入 harbor；由本脚本把构建包（charts+images）直推到目标 registry（SWR 等）再 helm 安装。
#   - 补齐 hce 脚本缺失的集群前置：证书+TLS secret、平台网关、Envoy proxy 资源收敛（T6）、默认 StorageClass（T9）。
#   - 推送+安装委托 run.sh（已支持 --keycloak-image 透传，eliminates T10）。
#   - 复用 local-kind-dev/deploy-local.sh 的 4 个正确命名 TLS secret 接线（cert-create.sh 输出命名不匹配，此处显式建）。
#
# 覆盖的规避点（详见 log/2026-10-23-workaround-analysis.md）：
#   T2 由 sexec 推送侧解决；T1/T3/T5/T7/T8/T9/T10/T11 已固化进三仓 chart/build.sh；
#   本脚本固化 T6（envoy 资源）、T9（默认 SC）、以及证书/网关前置，使人工跑标准流程无需临时传值或手改。
#
# 用法：
#   ./deploy-without-harbor.sh --registry <registry[/project]> [选项]
# 例：
#   ./deploy-without-harbor.sh --registry swr.cn-north-4.myhuaweicloud.com/sdp-20261022
#   ./deploy-without-harbor.sh --registry swr.cn-north-4.myhuaweicloud.com/sdp-20261022 --verify --dry-run

set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="sdp-workflow"
REGISTRY=""                       # 必填：镜像上传目标（含 project），如 swr.cn-north-4.myhuaweicloud.com/sdp-20261022
KUBECONFIG_PATH=""                # 可选；空=继承环境 KUBECONFIG 或节点 /root/.kube/config
RUNTIME="nerdctl"                 # 镜像操作运行时：nerdctl | docker
KEYCLOAK_IMAGE=""                 # 可选：覆盖 keycloak 镜像 repository；默认 ${REGISTRY}/keycloak
STORAGE_CLASS="csi-disk"          # 无默认 SC 时设为默认的 StorageClass（CCE 标准盘）
GATEWAY_YAML="${SCRIPT_DIR}/gateway-sdp-cce.yaml"
CERT_DIR="$(cd "${SCRIPT_DIR}/../cert-build/certs" 2>/dev/null && pwd || echo "")"
CERT_SCRIPT="${SCRIPT_DIR}/../cert-build/cert-create.sh"
VERIFY=0                         # 1 = 部署后跑 e2e-smoke 验收
E2E_BASE="${E2E_BASE:-https://www.sdpworkflow.com/api/v1}"  # 本脚本只服务云端，验收 BASE 显式指向网关
DRY_RUN=0

usage() {
    cat <<USAGE
用法: ./deploy-without-harbor.sh --registry <registry[/project]> [选项]

选项:
  --registry <addr>        必填，镜像上传目标（含 project），如 swr.cn-north-4.myhuaweicloud.com/sdp-20261022
  --namespace <ns>         部署命名空间，默认 ${NAMESPACE}
  --kubeconfig <path>      指定 kubeconfig，默认继承环境 KUBECONFIG
  --runtime <name>         镜像操作运行时 nerdctl|docker，默认 ${RUNTIME}
  --keycloak-image <repo>  覆盖 hub 子 chart 的 keycloak 镜像 repository（tag 沿用 chart 值）；默认 ${REGISTRY}/keycloak
  --storage-class <sc>     无默认 SC 时设为默认的 StorageClass，默认 ${STORAGE_CLASS}
  --gateway-yaml <file>    平台网关 yaml，默认 ${GATEWAY_YAML}
  --cert-dir <dir>         证书目录（ca.crt/console.crt/...），默认 ${CERT_DIR:-未找到}
  --cert-script <file>     证书生成脚本，默认 ${CERT_SCRIPT}
  --verify                 部署后跑 e2e-smoke 验收
  --dry-run                只打印将执行的命令，不实际执行
  -h, --help               显示本帮助

前置：组件包 software-distribution-platform-{hub,runner,console}-*.tar.gz 须与本脚本同目录（prod-deplyment/）。
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)       [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY="$2"; shift 2 ;;
        --namespace)      [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --kubeconfig)     [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --runtime)        [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; RUNTIME="$2"; shift 2 ;;
        --keycloak-image) [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KEYCLOAK_IMAGE="$2"; shift 2 ;;
        --storage-class)  [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; STORAGE_CLASS="$2"; shift 2 ;;
        --gateway-yaml)   [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; GATEWAY_YAML="$2"; shift 2 ;;
        --cert-dir)       [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; CERT_DIR="$2"; shift 2 ;;
        --cert-script)    [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; CERT_SCRIPT="$2"; shift 2 ;;
        --verify)         VERIFY=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log()  { echo "[deploy] $*"; }
warn() { echo "[deploy][WARN] $*" >&2; }

run() {  # dry-run 感知的命令执行
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# ---------- 阶段 0：前置工具检查 ----------
for tool in kubectl helm tar python3 "${RUNTIME}"; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "错误: 未找到 ${tool}"; exit 1; }
done
[[ -n "${REGISTRY}" ]] || { echo "错误: --registry 必填"; usage; exit 1; }
[[ -f "${GATEWAY_YAML}" ]] || { echo "错误: 网关 yaml 不存在: ${GATEWAY_YAML}"; exit 1; }

# ---------- 阶段 1：kubeconfig + 集群可达 ----------
if [[ -z "${KUBECONFIG_PATH}" && -f /root/.kube/config ]]; then
    KUBECONFIG_PATH=/root/.kube/config
fi
if [[ -n "${KUBECONFIG_PATH}" ]]; then
    [[ -f "${KUBECONFIG_PATH}" ]] || { echo "错误: kubeconfig 不存在: ${KUBECONFIG_PATH}"; exit 1; }
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi
run kubectl cluster-info >/dev/null || { echo "错误: 集群不可达，检查 kubeconfig"; exit 1; }
log "集群可达"

# ---------- 阶段 1.5：命名空间（后续 secret/gateway 依赖） ----------
if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
    log "ns ${NAMESPACE} 已存在，跳过"
else
    run kubectl create ns "${NAMESPACE}"
fi

ensure_secret() {  # ensure_secret <name> <type> [kubectl create secret 参数...]
    local name="$1" type="$2"; shift 2
    if kubectl get secret "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        log "secret ${name} 已存在，跳过"
    else
        log "创建 secret ${name} (${type})"
        run kubectl create secret "${type}" "${name}" -n "${NAMESPACE}" "$@"
    fi
}

# ---------- 阶段 2：证书 + 4 个正确命名 TLS secret + sdp-ca（复用 deploy-local.sh 接线） ----------
# cert-create.sh 产出 ${component}-server-secret（命名不匹配且不自动 apply），
# 平台 chart 实际期望 console-tls/hub-tls/hub-keycloak-tls（generic 三 key）与 console-ingress-tls（tls 类型）。
# 故此处显式建 4 个正确命名的 secret，不依赖 cert-create.sh 的输出命名。
cert_phase() {
    log "阶段 2：证书与 TLS secret"
    if [[ -z "${CERT_DIR}" || ! -d "${CERT_DIR}" ]]; then
        warn "证书目录不可用（${CERT_DIR:-未设置}），尝试生成"
        [[ -f "${CERT_SCRIPT}" ]] && bash "${CERT_SCRIPT}" "${NAMESPACE}" || { echo "错误: 证书生成失败"; exit 1; }
    fi
    # 证书文件缺失才生成（避免每次重跑都换新 CA，使既有集群 secret 失效）
    local need_gen=0
    for f in ca.crt console.crt console.key hub.crt hub.key hub-keycloak-http.crt hub-keycloak-http.key; do
        [[ -f "${CERT_DIR}/${f}" ]] || { need_gen=1; break; }
    done
    if [[ "${need_gen}" -eq 1 ]]; then
        log "证书缺失，运行 cert-create.sh"
        [[ -f "${CERT_SCRIPT}" ]] || { echo "错误: 未找到 ${CERT_SCRIPT}"; exit 1; }
        run bash "${CERT_SCRIPT}" "${NAMESPACE}"
    fi
    for f in ca.crt console.crt console.key hub.crt hub.key hub-keycloak-http.crt hub-keycloak-http.key; do
        [[ -f "${CERT_DIR}/${f}" ]] || { echo "错误: ${CERT_DIR} 缺 ${f}"; exit 1; }
    done
    ensure_secret console-ingress-tls tls \
        --cert="${CERT_DIR}/console.crt" --key="${CERT_DIR}/console.key"
    ensure_secret console-tls generic \
        --from-file=ca.crt="${CERT_DIR}/ca.crt" \
        --from-file=server.crt="${CERT_DIR}/console.crt" \
        --from-file=server.key="${CERT_DIR}/console.key"
    ensure_secret hub-tls generic \
        --from-file=ca.crt="${CERT_DIR}/ca.crt" \
        --from-file=server.crt="${CERT_DIR}/hub.crt" \
        --from-file=server.key="${CERT_DIR}/hub.key"
    ensure_secret hub-keycloak-tls generic \
        --from-file=ca.crt="${CERT_DIR}/ca.crt" \
        --from-file=tls.crt="${CERT_DIR}/hub-keycloak-http.crt" \
        --from-file=tls.key="${CERT_DIR}/hub-keycloak-http.key"
    # sdp-ca：hub 挂 /etc/sdp-ca/ca.crt 信任自签证书（auth.trustedCASecret 开启时）
    ensure_secret sdp-ca generic --from-file=ca.crt="${CERT_DIR}/ca.crt"
}
cert_phase

# ---------- 阶段 3：平台入口网关（Gateway API，CCE Envoy Gateway 插件） ----------
log "阶段 3：应用平台入口网关（${GATEWAY_YAML}）"
run kubectl apply -f "${GATEWAY_YAML}" --validate=false

# ---------- 阶段 4：Envoy proxy 资源预检（T6） ----------
# CCE「Envoy Gateway」插件默认给 proxy 每副本 request 8 核×2 副本，8 核节点 CPU 不足导致 Gateway PROGRAMMED=False。
# 持久修复优先走 EnvoyProxy CR（EG 原生、会 reconcile 进 Deployment）；无 CR 时打印手动命令并继续。
envoy_preflight() {
    log "阶段 4：Envoy Gateway proxy 资源预检（T6）"
    local eg_ns eg_ep
    eg_ep=$(kubectl get envoyproxy -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    eg_ns=$(kubectl get envoyproxy -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    if [[ -n "${eg_ep}" && -n "${eg_ns}" ]]; then
        log "发现 EnvoyProxy ${eg_ns}/${eg_ep}，收敛 proxy 资源 requests 至 500m/512Mi"
        run kubectl -n "${eg_ns}" patch envoyproxy "${eg_ep}" --type=merge \
            -p '{"spec":{"provider":{"kubernetes":{"envoyDeployment":{"pod":{"resources":{"requests":{"cpu":"500m","memory":"512Mi"}}}}}}}}' \
            || warn "EnvoyProxy patch 失败，见下方手动命令"
        return 0
    fi
    warn "未找到 EnvoyProxy CR，无法自动收敛 envoy proxy 资源；8 核节点可能因 CPU 不足导致 Gateway PROGRAMMED=False。"
    warn "  手动修复（EG 就地更新 proxy deployment，ELB/Service 不变）："
        warn "    kubectl -n kube-system edit cm envoy-gateway-config   # envoyDeployment 的 resources.requests 设为 cpu=500m,memory=512Mi"
    warn "    kubectl -n kube-system rollout restart deploy/envoy-gateway"
}
envoy_preflight

# ---------- 阶段 5：默认 StorageClass 预检（T9） ----------
# hub-artifacts PVC 依赖默认 SC（chart 的 artifact.storageClassName 留空时）；CCE 无默认 SC 须显式设。
storageclass_preflight() {
    log "阶段 5：默认 StorageClass 预检（T9）"
    local def
    def=$(kubectl get sc -o jsonpath='{.items[*].metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null | tr ' ' '\n' | grep -c '^true$' || true)
    if [[ "${def:-0}" -gt 0 ]]; then
        log "已存在默认 StorageClass，跳过"
        return 0
    fi
    if ! kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1; then
        warn "未找到 StorageClass '${STORAGE_CLASS}'，无法设为默认；hub-artifacts PVC 将 Pending"
        warn "  解决：云控制台创建默认 SC，或部署时 --set artifact.storageClassName=<sc>（run.sh 透传 helm --set）"
        return 0
    fi
    log "无默认 StorageClass，将 '${STORAGE_CLASS}' 设为默认（hub-artifacts PVC 依赖默认 SC）"
    run kubectl patch storageclass "${STORAGE_CLASS}" \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
}
storageclass_preflight

# ---------- 阶段 6：推送镜像并 helm 安装（委托 run.sh） ----------
# run.sh 已支持 --keycloak-image 透传（T10）；helm 用 upgrade --install（幂等，re-run 不报 release 已存在）。
deploy_phase() {
    log "阶段 6：推送镜像并 helm 安装（委托 run.sh）"
    local keycloak_img="${KEYCLOAK_IMAGE:-${REGISTRY}/keycloak}"
    local args=(--registry "${REGISTRY}" --keycloak-image "${keycloak_img}" --runtime "${RUNTIME}")
    [[ -n "${KUBECONFIG_PATH}" ]] && args+=(--kubeconfig "${KUBECONFIG_PATH}")
    [[ "${DRY_RUN}" -eq 1 ]] && args+=(--dry-run)
    run bash "${SCRIPT_DIR}/run.sh" "${args[@]}"
}
deploy_phase

# ---------- 阶段 7：可选 e2e-smoke 验收 ----------
if [[ "${VERIFY}" -eq 1 ]]; then
    log "阶段 7：e2e-smoke 验收（BASE 默认走网关对外地址）"
    smoke="${SCRIPT_DIR}/e2e-smoke.sh"
    if [[ -f "${smoke}" ]]; then
        run env BASE="${E2E_BASE}" bash "${smoke}"
    else
        warn "未找到 e2e-smoke.sh，跳过验收"
    fi
fi

log "部署流程结束（不含 DNS/节点 hosts；如需节点内解析 www.sdpworkflow.com，参考 log 中的 sdp-hosts-fix-ds.yaml）"
