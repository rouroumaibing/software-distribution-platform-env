#!/bin/bash
# SDP 平台清理脚本（华为云 CCE / HCE 2.0 托管 K8s）。
#
# 清理范围（默认仅可逆卸载，保留命名空间与 PVC 数据）：
#   - sdp-workflow 下的 helm release：console / hub / runner / postgresql
#     （hub 卸载会一并移除其 chart 托管的 hub-keycloak StatefulSet 与 keycloak HTTPRoute）
#   - sdp-workflow 下的 Gateway `sdp-gateway` 及其全部 HTTPRoute（释放 CCE 插件按 listeners 创建的 ELB）
#
# 不可逆选项（默认关闭，需显式开启）：
#   --delete-crds        删除集群级平台 CRD（pipelineruns/rollouts/taskruns.pipeline.sdp.io）
#                        会级联删除全部 CR；仅在确认不再需要平台 API 时开启
#   --delete-pvc         删除 sdp-workflow 下的 PVC（data-postgres-0 20Gi、hub-artifacts 10Gi）——数据不可逆
#   --delete-namespace   删除整个 sdp-workflow 命名空间（级联删除其中所有资源与 PVC）
#
# 安全：执行任何删除前默认把各命名空间资源 manifest 备份到 BACKUP_DIR（--no-backup 可跳过）。
#       本脚本不触碰 envoy-gateway GatewayClass（CCE 托管插件，删除即破坏插件）。
set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
NAMESPACE="sdp-workflow"
KUBECONFIG_PATH=""
BACKUP_DIR="${SCRIPT_DIR}/.cleanup-backup"
DRY_RUN=0
NO_BACKUP=0
DELETE_CRDS=0
DELETE_PVC=0
DELETE_NAMESPACE=0

# sdp-workflow 下的平台 helm release（卸载顺序：先应用后数据）
PLATFORM_RELEASES=(console hub runner postgresql)

usage() {
    cat <<USAGE
用法: ./cleanup-sdp-platform.sh [选项]

选项:
  --namespace <ns>        平台命名空间，默认 ${NAMESPACE}
  --kubeconfig <path>     指定 kubeconfig（默认 /root/.kube/config 或环境 KUBECONFIG）
  --backup-dir <dir>      删除前 manifest 备份目录，默认 ${BACKUP_DIR}
  --no-backup             跳过删除前备份
  --delete-crds           删除集群级平台 CRD（级联删全部 CR），默认关
  --delete-pvc            删除命名空间下 PVC（数据不可逆），默认关
  --delete-namespace      删除整个命名空间（级联删全部资源+PVC），默认关
  --dry-run               只打印将执行的命令，不实际执行
  -h, --help              显示本帮助

示例:
  ./cleanup-sdp-platform.sh                       # 仅可逆卸载（保留 ns+PVC）
  ./cleanup-sdp-platform.sh --dry-run             # 预览
  ./cleanup-sdp-platform.sh --delete-namespace    # 连命名空间一并删除（不可逆）
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)          [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --kubeconfig)         [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --backup-dir)         [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; BACKUP_DIR="$2"; shift 2 ;;
        --no-backup)          NO_BACKUP=1; shift ;;
        --delete-crds)        DELETE_CRDS=1; shift ;;
        --delete-pvc)         DELETE_PVC=1; shift ;;
        --delete-namespace)   DELETE_NAMESPACE=1; shift ;;
        --dry-run)            DRY_RUN=1; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log()  { echo "[cleanup-platform] $*"; }
warn() { echo "[cleanup-platform][WARN] $*" >&2; }

run() {  # dry-run 感知的命令执行
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
backup_ns() {
    local ns="$1"
    local out="${BACKUP_DIR}/${ns}-$(date +%Y%m%d-%H%M%S).yaml"
    mkdir -p "${BACKUP_DIR}"
    log "备份 ns=${ns} 资源到 ${out}"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        kubectl get all,rollout,gateway,httproute,pvc,secret,sa,cm \
            -n "${ns}" -o yaml > "${out}" 2>/dev/null \
            || warn "备份 ${ns} 部分资源失败（可忽略）"
    fi
}

if [[ "${NO_BACKUP}" -ne 1 ]]; then
    backup_ns "${NAMESPACE}"
else
    log "--no-backup 已设，跳过备份"
fi

# ---------- 阶段 2：卸载平台 helm release ----------
uninstall_release() {
    local rel="$1" ns="$2"
    if helm status "${rel}" -n "${ns}" >/dev/null 2>&1; then
        log "卸载 release ${rel} (ns ${ns})"
        run helm uninstall "${rel}" -n "${ns}"
    else
        log "release ${rel} 在 ${ns} 不存在，跳过"
    fi
}

for rel in "${PLATFORM_RELEASES[@]}"; do
    uninstall_release "${rel}" "${NAMESPACE}"
done

# ---------- 阶段 3：删除网关与路由（释放 CCE ELB） ----------
# 数据面 Deployment（如 sdp-gateway）由 CCE envoy-gateway 插件按 Gateway 资源托管，
# 删除 Gateway 资源即触发插件回收，无需手动删 Deployment。
log "==> 删除网关 sdp-gateway 与 HTTPRoute（释放 ELB）"
run kubectl delete gateway sdp-gateway -n "${NAMESPACE}" --ignore-not-found
run kubectl delete httproute -n "${NAMESPACE}" --all --ignore-not-found

# ---------- 阶段 4：可选删除集群级 CRD ----------
if [[ "${DELETE_CRDS}" -eq 1 ]]; then
    log "==> 删除平台 CRD（级联删全部 CR）"
    for crd in pipelineruns.pipeline.sdp.io rollouts.pipeline.sdp.io taskruns.pipeline.sdp.io; do
        run kubectl delete crd "${crd}" --ignore-not-found
    done
else
    log "保留平台 CRD（如需删除加 --delete-crds）"
fi

# ---------- 阶段 5：可选删除 PVC / 命名空间 ----------
if [[ "${DELETE_NAMESPACE}" -eq 1 ]]; then
    log "==> 删除整个命名空间 ${NAMESPACE}（级联删除全部资源与 PVC，不可逆）"
    run kubectl delete ns "${NAMESPACE}" --ignore-not-found
else
    if [[ "${DELETE_PVC}" -eq 1 ]]; then
        log "==> 删除 ${NAMESPACE} 下 PVC（数据不可逆）"
        run kubectl delete pvc -n "${NAMESPACE}" --all --ignore-not-found
    else
        log "保留命名空间 ${NAMESPACE} 与其中 PVC（数据）。删除 PVC 加 --delete-pvc；删 ns 加 --delete-namespace"
    fi
fi

log "平台清理完成（可逆部分）。不可逆选项未开启时，命名空间与 PVC 仍保留。"
