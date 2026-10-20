#!/bin/bash
# Harbor 清理脚本（华为云 CCE / HCE 2.0 托管 K8s）。
#
# 清理范围（默认仅可逆卸载，保留命名空间与 PVC 数据）：
#   - harbor 命名空间下的 helm release：harbor（bitnamicharts/harbor 27.0.3）
#   - harbor 命名空间下的 Gateway `harbor-gateway` 与 HTTPRoute（harbor / harbor-http-redirect，释放 ELB）
#   - harbor 命名空间下的 TLS Secret `harbor-tls`（helm 卸载不清理）
#   - kube-system 下的 `harbor-ca-trust` DaemonSet（特权，向所有节点分发 harbor 自签 CA 并重启 containerd；
#     harbor 移除后不再需要，留之会在节点重启时做无意义 containerd 重启）
#
# 不可逆选项（默认关闭，需显式开启）：
#   --delete-pvc         删除 harbor 下 PVC（registry 50Gi + postgres 8Gi + trivy 5Gi + redis 8Gi + jobservice 1Gi）；
#                        harbor chart 对 registry PVC 设了 resourcePolicy: keep，卸载不删，须显式删；数据不可逆
#   --delete-namespace   删除整个 harbor 命名空间（级联删全部资源+PVC）
#
# 安全：执行任何删除前默认把 harbor / kube-system(harbor-ca-trust) 资源 manifest 备份到 BACKUP_DIR。
#       本脚本不触碰 envoy-gateway GatewayClass（CCE 托管插件）。
set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
NAMESPACE="harbor"
CA_TRUST_NS="kube-system"
CA_TRUST_DS="harbor-ca-trust"
KUBECONFIG_PATH=""
BACKUP_DIR="${SCRIPT_DIR}/.cleanup-backup"
DRY_RUN=0
NO_BACKUP=0
DELETE_PVC=0
DELETE_NAMESPACE=0

usage() {
    cat <<USAGE
用法: ./cleanup-harbor.sh [选项]

选项:
  --namespace <ns>        harbor 命名空间，默认 ${NAMESPACE}
  --kubeconfig <path>    指定 kubeconfig（默认 /root/.kube/config 或环境 KUBECONFIG）
  --backup-dir <dir>     删除前 manifest 备份目录，默认 ${BACKUP_DIR}
  --no-backup            跳过删除前备份
  --delete-pvc           删除 harbor 下 PVC（registry 50Gi 等，数据不可逆），默认关
  --delete-namespace     删除整个 harbor 命名空间（级联删全部资源+PVC），默认关
  --dry-run              只打印将执行的命令，不实际执行
  -h, --help             显示本帮助

示例:
  ./cleanup-harbor.sh                    # 仅可逆卸载（保留 ns+PVC）
  ./cleanup-harbor.sh --delete-namespace # 连 harbor 命名空间与 PVC 一并删除（不可逆）
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)         [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
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

log()  { echo "[cleanup-harbor] $*"; }
warn() { echo "[cleanup-harbor][WARN] $*" >&2; }

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
    out="${BACKUP_DIR}/harbor-$(date +%Y%m%d-%H%M%S).yaml"
    log "备份 ns=${NAMESPACE} 资源到 ${out}"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        kubectl get all,rollout,gateway,httproute,pvc,secret,sa,cm \
            -n "${NAMESPACE}" -o yaml > "${out}" 2>/dev/null \
            || warn "备份 ${NAMESPACE} 部分资源失败（可忽略）"
    fi
    # harbor-ca-trust DaemonSet 备份（在 kube-system）
    dsout="${BACKUP_DIR}/harbor-ca-trust-$(date +%Y%m%d-%H%M%S).yaml"
    log "备份 DaemonSet ${CA_TRUST_DS} (ns ${CA_TRUST_NS}) 到 ${dsout}"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        kubectl get ds "${CA_TRUST_DS}" -n "${CA_TRUST_NS}" -o yaml > "${dsout}" 2>/dev/null \
            || warn "备份 ${CA_TRUST_DS} 失败（可忽略）"
    fi
else
    log "--no-backup 已设，跳过备份"
fi

# ---------- 阶段 2：卸载 harbor helm release ----------
if helm status harbor -n "${NAMESPACE}" >/dev/null 2>&1; then
    log "卸载 release harbor (ns ${NAMESPACE})"
    run helm uninstall harbor -n "${NAMESPACE}"
else
    log "release harbor 在 ${NAMESPACE} 不存在，跳过"
fi

# ---------- 阶段 3：删除网关与路由（释放 ELB） ----------
log "==> 删除网关 harbor-gateway 与 HTTPRoute（释放 ELB）"
run kubectl delete gateway harbor-gateway -n "${NAMESPACE}" --ignore-not-found
run kubectl delete httproute -n "${NAMESPACE}" --all --ignore-not-found
run kubectl delete secret harbor-tls -n "${NAMESPACE}" --ignore-not-found

# ---------- 阶段 4：删除 harbor-ca-trust DaemonSet ----------
log "==> 删除 ${CA_TRUST_NS}/${CA_TRUST_DS} DaemonSet（节点 CA 分发，harbor 移除后无需保留）"
run kubectl delete ds "${CA_TRUST_DS}" -n "${CA_TRUST_NS}" --ignore-not-found

# ---------- 阶段 5：可选删除 PVC / 命名空间 ----------
if [[ "${DELETE_NAMESPACE}" -eq 1 ]]; then
    log "==> 删除整个命名空间 ${NAMESPACE}（级联删除全部资源与 PVC，不可逆）"
    run kubectl delete ns "${NAMESPACE}" --ignore-not-found
else
    if [[ "${DELETE_PVC}" -eq 1 ]]; then
        log "==> 删除 ${NAMESPACE} 下 PVC（registry 50Gi 等数据不可逆；resourcePolicy: keep 须显式删）"
        run kubectl delete pvc -n "${NAMESPACE}" --all --ignore-not-found
    else
        log "保留命名空间 ${NAMESPACE} 与其中 PVC（数据）。删除 PVC 加 --delete-pvc；删 ns 加 --delete-namespace"
    fi
fi

log "harbor 清理完成（可逆部分）。不可逆选项未开启时，命名空间与 PVC 仍保留。"
