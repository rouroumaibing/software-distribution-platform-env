#!/bin/bash
# nginx 测试案例清理脚本（华为云 CCE / HCE 2.0 托管 K8s）。
#
# 清理范围（默认仅可逆卸载，保留命名空间与 PVC 数据）：
#   - 两个 nginx-canary helm release：sdp-run（rev2，灰度测试入口）与 sdp-workflow（rev3，基线部署）
#   - sdp-run 中由 runner 控制器动态创建、helm 不管理的灰度遗留：
#       * Rollout CR（pipeline.sdp.io/v1alpha1，如 pr-3b78b722-canary-task）
#       * canary Deployment（nginx-canary-canary）
#       * 分流 Service（nginx-canary-sdp，app-only selector）
#       * taskrun 测试 Job / Pod
#
# 不可逆选项（默认关闭，需显式开启）：
#   --delete-pvc         删除 sdp-run 下 PVC（本案例无持久化 PVC，通常为空，仅兜底）
#   --delete-namespace   删除整个 sdp-run 命名空间（级联删全部资源+PVC）
#
# 安全：执行任何删除前默认把 sdp-run 资源 manifest 备份到 BACKUP_DIR（--no-backup 可跳过）。
#       注意：本脚本只动 nginx 测试相关资源，不触碰 sdp-workflow 的平台组件。
set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RUN_NAMESPACE="sdp-run"
KUBECONFIG_PATH=""
BACKUP_DIR="${SCRIPT_DIR}/.cleanup-backup"
DRY_RUN=0
NO_BACKUP=0
DELETE_PVC=0
DELETE_NAMESPACE=0

# 两个 nginx-canary release 所在命名空间
NGINX_RELEASE_NS=(sdp-run sdp-workflow)

usage() {
    cat <<USAGE
用法: ./cleanup-nginx-canary.sh [选项]

选项:
  --run-namespace <ns>   canary 测试运行命名空间，默认 ${RUN_NAMESPACE}
  --kubeconfig <path>    指定 kubeconfig（默认 /root/.kube/config 或环境 KUBECONFIG）
  --backup-dir <dir>     删除前 manifest 备份目录，默认 ${BACKUP_DIR}
  --no-backup            跳过删除前备份
  --delete-pvc           删除 sdp-run 下 PVC，默认关
  --delete-namespace     删除整个 sdp-run 命名空间（级联删全部资源+PVC），默认关
  --dry-run              只打印将执行的命令，不实际执行
  -h, --help             显示本帮助

示例:
  ./cleanup-nginx-canary.sh                    # 仅可逆卸载（保留 ns+PVC）
  ./cleanup-nginx-canary.sh --delete-namespace # 连 sdp-run 命名空间一并删除（不可逆）
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-namespace)     [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; RUN_NAMESPACE="$2"; shift 2 ;;
        --kubeconfig)        [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --backup-dir)        [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; BACKUP_DIR="$2"; shift 2 ;;
        --no-backup)         NO_BACKUP=1; shift ;;
        --delete-pvc)        DELETE_PVC=1; shift ;;
        --delete-namespace)  DELETE_NAMESPACE=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log()  { echo "[cleanup-nginx] $*"; }
warn() { echo "[cleanup-nginx][WARN] $*" >&2; }

run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# ---------- 阶段 0：前置检查 ----------
for tool in kubectl helm; do
    command -v "${tool}" >/dev/null 2>&1 || { echo "错误: 未找到 ${tool}"; exit 1; }
done

if [[ -z "${KUBECONFIG_PATH}" && -f /root/.kube/config ]]; then
    KUBECONFIG_PATH=/root/.kube/config
fi
if [[ -n "${KUBECONFIG_PATH}" ]]; then
    [[ -f "${KUBECONFIG_PATH}" ]] || { echo "错误: kubeconfig 不存在: ${KUBECONFIG_PATH}"; exit 1; }
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi

run kubectl cluster-info >/dev/null || { echo "错误: 集群不可达，检查 kubeconfig"; exit 1; }
log "集群可达"

# ---------- 阶段 1：删除前备份 ----------
if [[ "${NO_BACKUP}" -ne 1 ]]; then
    mkdir -p "${BACKUP_DIR}"
    for ns in "${NGINX_RELEASE_NS[@]}"; do
        out="${BACKUP_DIR}/nginx-${ns}-$(date +%Y%m%d-%H%M%S).yaml"
        log "备份 ns=${ns} 资源到 ${out}"
        if [[ "${DRY_RUN}" -ne 1 ]]; then
            kubectl get all,rollout,pvc,secret,sa,cm -n "${ns}" -o yaml > "${out}" 2>/dev/null \
                || warn "备份 ${ns} 部分资源失败（可忽略）"
        fi
    done
else
    log "--no-backup 已设，跳过备份"
fi

# ---------- 阶段 2：卸载两个 nginx-canary helm release ----------
uninstall_release() {
    local rel="$1" ns="$2"
    if helm status "${rel}" -n "${ns}" >/dev/null 2>&1; then
        log "卸载 release ${rel} (ns ${ns})"
        run helm uninstall "${rel}" -n "${ns}"
    else
        log "release ${rel} 在 ${ns} 不存在，跳过"
    fi
}

for ns in "${NGINX_RELEASE_NS[@]}"; do
    uninstall_release nginx-canary "${ns}"
done

# ---------- 阶段 3：删除 runner 动态创建的灰度遗留（sdp-run） ----------
# helm uninstall 不会清理 runner 控制器在灰度期间动态建的对象，必须显式删除。
log "==> 删除 sdp-run 中 runner 动态创建的灰度遗留"
run kubectl delete rollout --all -n "${RUN_NAMESPACE}" --ignore-not-found
# 清理 workloads / services / jobs / pods（test 命名空间，全部为测试产物）
run kubectl delete all --all -n "${RUN_NAMESPACE}" --ignore-not-found

# ---------- 阶段 4：可选删除 PVC / 命名空间 ----------
if [[ "${DELETE_NAMESPACE}" -eq 1 ]]; then
    log "==> 删除整个命名空间 ${RUN_NAMESPACE}（级联删除全部资源与 PVC，不可逆）"
    run kubectl delete ns "${RUN_NAMESPACE}" --ignore-not-found
else
    if [[ "${DELETE_PVC}" -eq 1 ]]; then
        log "==> 删除 ${RUN_NAMESPACE} 下 PVC（数据不可逆）"
        run kubectl delete pvc -n "${RUN_NAMESPACE}" --all --ignore-not-found
    else
        log "保留命名空间 ${RUN_NAMESPACE} 与其中资源。删除 PVC 加 --delete-pvc；删 ns 加 --delete-namespace"
    fi
fi

log "nginx 测试案例清理完成（可逆部分）。不可逆选项未开启时，sdp-run 命名空间与 PVC 仍保留。"
