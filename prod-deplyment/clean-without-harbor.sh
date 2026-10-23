#!/bin/bash
# clean-without-harbor.sh — 清理 deploy-without-harbor.sh 部署的云上 SDP 组件（harbor 不动）。
#
# 与 deploy-without-harbor.sh 的对应关系（逆序回收部署面）：
#   helm release hub/runner/console → 5 个 TLS/CA secret → Gateway sdp-gateway；
#   可选项：默认 StorageClass 标注回退（T9）、节点 hosts DaemonSet、PVC 数据（T2U）。
#   HTTPRoute / BackendTLSPolicy 由各组件 chart 拥有，随 helm uninstall 一并删除。
#   EnvoyProxy CR（T6 收敛）与 CCE Envoy Gateway 插件属共享基础设施，本脚本不动。
#
# 破坏性分级（授权锚点=是否可恢复）：
#   默认动作      T2R 可恢复：helm uninstall / secret / Gateway，重跑部署脚本即可还原；
#   --delete-pvc  T2U 不可恢复：PVC 数据（构建制品/运行数据）删除后无法找回，默认关闭。
#   铁律：任何删除前先备份（helm values / secret yaml / 资源与 PVC 清单）到备份目录。
#
# 用法：
#   ./clean-without-harbor.sh            # 计划模式：只打印将执行的动作，不改集群
#   ./clean-without-harbor.sh --yes      # 备份后执行默认清理（T2R）
#   ./clean-without-harbor.sh --yes --delete-pvc   # 连 PVC 一起删（T2U，慎用）
#
# 例：
#   ./clean-without-harbor.sh --yes --kubeconfig /root/.kube/config
#   ./clean-without-harbor.sh --yes --delete-pvc --revert-storageclass --delete-hosts-ds

set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="sdp-workflow"
KUBECONFIG_PATH=""                # 可选；空=继承环境 KUBECONFIG 或节点 /root/.kube/config
RELEASES=(hub runner console)     # 与 run.sh 的 helm release 名一致
SECRETS=(console-ingress-tls console-tls hub-tls hub-keycloak-tls sdp-ca)
GATEWAY_NAME="sdp-gateway"
STORAGE_CLASS="csi-disk"          # --revert-storageclass 时摘除默认标注的 SC
HOSTS_DS_NAME="sdp-hosts-fix"     # 节点 hosts DaemonSet（log/2026-10-22 沉淀产物）
DELETE_PVC=0                      # T2U：删命名空间内 PVC（含数据）
REVERT_SC=0                       # 回退 T9 的默认 SC 标注
DELETE_HOSTS_DS=0                 # 删节点 hosts DaemonSet（节点 /etc/hosts 条目需手动清，见结尾提示）
YES=0                             # 0=计划模式；1=备份后执行
BACKUP_DIR=""                     # 空=自动 /tmp/sdp-clean-backup-<时间戳>

usage() {
    cat <<USAGE
用法: ./clean-without-harbor.sh [--yes] [选项]

模式:
  （默认）                  计划模式：只打印将执行的动作，不改集群
  --yes                     备份后执行默认清理（T2R：helm release / secret / Gateway）

选项:
  --namespace <ns>          目标命名空间，默认 ${NAMESPACE}
  --kubeconfig <path>       指定 kubeconfig，默认继承环境 KUBECONFIG
  --delete-pvc              T2U 不可恢复：删除命名空间内全部 PVC（构建制品/运行数据），默认关闭
  --revert-storageclass     摘除 '${STORAGE_CLASS}' 的默认 StorageClass 标注（回退 T9）
  --delete-hosts-ds         删除节点 hosts DaemonSet（节点 /etc/hosts 条目仍需按结尾提示手动清理）
  --storage-class <sc>      配合 --revert-storageclass，默认 ${STORAGE_CLASS}
  --backup-dir <dir>        备份目录，默认 /tmp/sdp-clean-backup-<时间戳>
  -h, --help                显示本帮助

范围声明：只动命名空间 ${NAMESPACE} 内 deploy-without-harbor.sh 部署的资源；harbor、
CCE Envoy Gateway 插件、EnvoyProxy CR 一律不动。
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)          [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --kubeconfig)         [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --delete-pvc)         DELETE_PVC=1; shift ;;
        --revert-storageclass) REVERT_SC=1; shift ;;
        --delete-hosts-ds)    DELETE_HOSTS_DS=1; shift ;;
        --storage-class)      [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; STORAGE_CLASS="$2"; shift 2 ;;
        --backup-dir)         [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; BACKUP_DIR="$2"; shift 2 ;;
        --yes)                YES=1; shift ;;
        --dry-run)            echo "提示: 不带 --yes 即为计划模式，--dry-run 已是默认行为"; shift ;;
        -h|--help)            usage; exit 0 ;;
        *)                    echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log()  { echo "[clean] $*"; }
warn() { echo "[clean][WARN] $*" >&2; }

run() {  # 计划感知执行：无 --yes 只打印；--yes 才真正执行
    if [[ "${YES}" -ne 1 ]]; then
        echo "[plan] $*"
    else
        "$@"
    fi
}

# ---------- 阶段 0：前置工具与集群可达 ----------
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
kubectl cluster-info >/dev/null 2>&1 || { echo "错误: 集群不可达，检查 kubeconfig"; exit 1; }
log "集群可达（ns=${NAMESPACE}，模式=$([[ "${YES}" -eq 1 ]] && echo 执行 || echo 计划)）"

if [[ "${DELETE_PVC}" -eq 1 && "${YES}" -ne 1 ]]; then
    warn "计划模式附带 --delete-pvc：执行时将删除 PVC 数据（T2U 不可恢复），请先确认备份需求"
fi

# ---------- 阶段 1：现状盘点（只读） ----------
ns_exists=0
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 && ns_exists=1
if [[ "${ns_exists}" -eq 0 ]]; then
    log "命名空间 ${NAMESPACE} 不存在，无需清理，退出"
    exit 0
fi

existing_releases=()
for rel in "${RELEASES[@]}"; do
    helm status "${rel}" -n "${NAMESPACE}" >/dev/null 2>&1 && existing_releases+=("${rel}")
done
existing_secrets=()
for sec in "${SECRETS[@]}"; do
    kubectl get secret "${sec}" -n "${NAMESPACE}" >/dev/null 2>&1 && existing_secrets+=("${sec}")
done
existing_pvc=()
while IFS= read -r p; do
    [[ -n "${p}" ]] && existing_pvc+=("${p}")
done < <(kubectl get pvc -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

log "盘点：helm release=[$(echo "${existing_releases[*]:-无}")] secret=[$(echo "${existing_secrets[*]:-无}")] Gateway=${GATEWAY_NAME} PVC 共 ${#existing_pvc[@]} 个"

# ---------- 阶段 2：备份（--yes 执行时强制，先备份后删除） ----------
if [[ "${YES}" -eq 1 ]]; then
    if [[ -z "${BACKUP_DIR}" ]]; then
        BACKUP_DIR="/tmp/sdp-clean-backup-$(date +%Y%m%d-%H%M%S)"
    fi
    mkdir -p "${BACKUP_DIR}"
    log "备份到 ${BACKUP_DIR}"
    for rel in "${existing_releases[@]:-}"; do
        [[ -z "${rel}" ]] && continue
        helm get values "${rel}" -n "${NAMESPACE}" --all > "${BACKUP_DIR}/helm-values-${rel}.txt" 2>/dev/null || true
        helm get manifest "${rel}" -n "${NAMESPACE}" > "${BACKUP_DIR}/helm-manifest-${rel}.yaml" 2>/dev/null || true
    done
    for sec in "${existing_secrets[@]:-}"; do
        [[ -z "${sec}" ]] && continue
        kubectl get secret "${sec}" -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/secret-${sec}.yaml" 2>/dev/null || true
    done
    kubectl get gateway,httproute,backendtlspolicy,pvc -n "${NAMESPACE}" -o yaml \
        > "${BACKUP_DIR}/gateway-routes-pvc.yaml" 2>/dev/null || true
    if [[ "${#existing_pvc[@]}" -gt 0 ]]; then
        warn "备份只含 PVC 元数据（yaml），未导出数据内容；--delete-pvc 前如需数据请自行导出（如 kubectl exec 打包）"
    fi
    log "备份完成"
fi

# ---------- 阶段 3：helm 卸载三组件（T2R；逆部署序 console→runner→hub） ----------
if [[ "${#existing_releases[@]}" -gt 0 ]]; then
    for (( idx=${#existing_releases[@]}-1; idx>=0; idx-- )); do
        rel="${existing_releases[${idx}]}"
        log "helm uninstall ${rel} -n ${NAMESPACE}"
        run helm uninstall "${rel}" -n "${NAMESPACE}" --wait 2>&1 | sed 's/^/[helm] /' || warn "helm uninstall ${rel} 异常（继续）"
    done
else
    log "无 helm release，跳过卸载"
fi

# ---------- 阶段 4：删部署脚本创建的 5 个 secret（T2R，证书可由 cert-create.sh 重生成） ----------
if [[ "${#existing_secrets[@]}" -gt 0 ]]; then
    log "删除 secret: ${existing_secrets[*]}"
    for sec in "${existing_secrets[@]}"; do
        run kubectl delete secret "${sec}" -n "${NAMESPACE}" --ignore-not-found
    done
else
    log "无目标 secret，跳过"
fi

# ---------- 阶段 5：删平台入口 Gateway（T2R；EG 自动回收 proxy Deployment/Service） ----------
if kubectl get gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log "删除 Gateway ${NAMESPACE}/${GATEWAY_NAME}（源: gateway-sdp-cce.yaml）"
    run kubectl delete gateway "${GATEWAY_NAME}" -n "${NAMESPACE}" --ignore-not-found
else
    log "Gateway ${GATEWAY_NAME} 不存在，跳过"
fi

# ---------- 阶段 6（可选）：回退默认 StorageClass 标注（T2R） ----------
if [[ "${REVERT_SC}" -eq 1 ]]; then
    cur=$(kubectl get sc "${STORAGE_CLASS}" -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null || true)
    if [[ "${cur}" == "true" ]]; then
        log "摘除 StorageClass ${STORAGE_CLASS} 的默认标注"
        run kubectl patch storageclass "${STORAGE_CLASS}" \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":null}}}'
    else
        log "StorageClass ${STORAGE_CLASS} 非默认，跳过回退"
    fi
fi

# ---------- 阶段 7（可选）：删节点 hosts DaemonSet（T2R；节点 /etc/hosts 条目手动清） ----------
if [[ "${DELETE_HOSTS_DS}" -eq 1 ]]; then
    ds_ns=$(kubectl get ds -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk -v n="${HOSTS_DS_NAME}" '$2==n{print $1; exit}')
    if [[ -n "${ds_ns}" ]]; then
        log "删除 DaemonSet ${ds_ns}/${HOSTS_DS_NAME}"
        run kubectl delete ds "${HOSTS_DS_NAME}" -n "${ds_ns}" --ignore-not-found
    else
        log "未找到 DaemonSet ${HOSTS_DS_NAME}，跳过"
    fi
fi

# ---------- 阶段 8（可选，T2U）：删 PVC ----------
if [[ "${DELETE_PVC}" -eq 1 ]]; then
    if [[ "${#existing_pvc[@]}" -eq 0 ]]; then
        log "命名空间无 PVC，跳过"
    else
        log "删除 PVC（T2U 不可恢复）: ${existing_pvc[*]}"
        for pvc in "${existing_pvc[@]}"; do
            size=$(kubectl get pvc "${pvc}" -n "${NAMESPACE}" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo '?')
            log "  delete pvc ${pvc}（申请容量 ${size}；实际数据量以监控为准）"
            run kubectl delete pvc "${pvc}" -n "${NAMESPACE}" --ignore-not-found
        done
    fi
fi

# ---------- 尾声：残留与手动项 ----------
log "清理流程结束"
warn "手动残留项（本脚本不代做）："
warn "  1) 节点 /etc/hosts 的 'www.sdpworkflow.com' 条目：逐节点执行 nsenter -t 1 -- sed -i '/www.sdpworkflow.com/d' /etc/hosts（或重跑 hce-2.0-64bit-env.sh 前人工确认）"
warn "  2) EnvoyProxy CR 的 resources 收敛（T6）保留原状——属插件配置修复，重部署时仍需要"
warn "  3) 镜像仓库（SWR 等）内的镜像不清理；harbor 未触碰"
if [[ "${YES}" -eq 1 && -n "${BACKUP_DIR}" ]]; then
    log "备份目录: ${BACKUP_DIR}"
fi
