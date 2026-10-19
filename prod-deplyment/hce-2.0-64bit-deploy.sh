#!/bin/bash
# SDP 平台一键部署脚本（华为云 CCE / HCE 2.0 托管 K8s）。
# 仅本脚本即可把 SDP 三组件及其依赖在 k8s 集群中拉起。
# 网关（Gateway/ELB）、DNS、端到端验证不在本脚本职责内，另行处理。
#
# 前提（环境类工作不在本脚本职责内）：
#   - kubectl / helm 可用，kubeconfig 已配置（节点默认 /root/.kube/config）
#   - CCE「Envoy Gateway」插件已安装（GatewayClass=envoy-gateway，自动创建 ELB；
#     自建 Envoy Gateway 无法暴露 ELB，云上统一走插件，见 log/2026-10-19-cloud-deploy.md）
#   - harbor 已部署，镜像已推送：software-distribution-platform-{hub,runner,console}
#     与 keycloak:26.x（镜像推送由 run.sh 完成组件包 -> registry）
#
# 幂等：ns / secrets 已存在则跳过，helm 用 upgrade --install，可重复执行。
set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="sdp-workflow"
REGISTRY="harbor.sdpworkflow.com/sdp"   # 镜像仓库（含 project）
PACKAGES_DIR="${SCRIPT_DIR}"            # 组件包目录（software-distribution-platform-*.tar.gz）
INFRA_DIR="${SCRIPT_DIR}"               # 基础设施目录（postgresql-*.tgz + postgresql-values.yaml）
CERT_DIR="$(cd "${SCRIPT_DIR}/../cert-build/certs" 2>/dev/null && pwd || echo "")"  # ca.crt console.crt console.key
KUBECONFIG_PATH=""                      # 空 = 节点默认 /root/.kube/config，否则继承环境
KEYCLOAK_DB_PASSWORD="sdp"              # hub-keycloak-database secret 内容
DRY_RUN=0

COMPONENTS=(hub console runner)         # 部署顺序即数组顺序

usage() {
    cat <<USAGE
用法: ./hce-2.0-64bit-deploy.sh [选项]

选项:
  --registry <addr/project>  镜像仓库，默认 ${REGISTRY}
  --namespace <ns>           部署命名空间，默认 ${NAMESPACE}
  --packages-dir <dir>       组件包目录，默认 ${PACKAGES_DIR}
  --infra-dir <dir>          postgresql chart 与 values 所在目录，默认 ${INFRA_DIR}
  --cert-dir <dir>           证书目录（ca.crt console.crt console.key），默认 ${CERT_DIR:-未找到}
  --kubeconfig <path>        指定 kubeconfig（默认 /root/.kube/config 或环境 KUBECONFIG）
  --keycloak-db-password <p> hub-keycloak-database secret 口令，默认 ${KEYCLOAK_DB_PASSWORD}
  --dry-run                  只打印将执行的命令，不实际执行
  -h, --help                 显示本帮助

示例:
  ./hce-2.0-64bit-deploy.sh
  ./hce-2.0-64bit-deploy.sh --registry harbor.sdpworkflow.com/sdp --dry-run
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)            [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY="$2"; shift 2 ;;
        --namespace)           [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --packages-dir)        [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; PACKAGES_DIR="$2"; shift 2 ;;
        --infra-dir)           [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; INFRA_DIR="$2"; shift 2 ;;
        --cert-dir)            [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; CERT_DIR="$2"; shift 2 ;;
        --kubeconfig)          [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --keycloak-db-password) [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KEYCLOAK_DB_PASSWORD="$2"; shift 2 ;;
        --dry-run)             DRY_RUN=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *)                     echo "错误: 未知参数 $1"; usage; exit 1 ;;
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

# ---------- 阶段 0：前置检查 ----------
for tool in kubectl helm tar; do
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

PG_CHART="$(ls "${INFRA_DIR}"/postgresql-*.tgz 2>/dev/null | head -1 || true)"
[[ -n "${PG_CHART}" ]] || { echo "错误: ${INFRA_DIR} 下未找到 postgresql-*.tgz"; exit 1; }
PG_VALUES="${INFRA_DIR}/postgresql-values.yaml"
[[ -f "${PG_VALUES}" ]] || { echo "错误: 缺 ${PG_VALUES}"; exit 1; }

PKGS=()
for comp in "${COMPONENTS[@]}"; do
    pkg="$(ls "${PACKAGES_DIR}"/software-distribution-platform-"${comp}"-*.tar.gz 2>/dev/null | head -1 || true)"
    [[ -n "${pkg}" ]] || { echo "错误: ${PACKAGES_DIR} 下未找到组件包 software-distribution-platform-${comp}-*.tar.gz"; exit 1; }
    PKGS+=("${pkg}")
done

# ---------- 阶段 1：ns + secrets（幂等，已存在即跳过） ----------
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

if [[ -n "${CERT_DIR}" && -d "${CERT_DIR}" ]]; then
    for f in ca.crt console.crt console.key; do
        [[ -f "${CERT_DIR}/${f}" ]] || { echo "错误: ${CERT_DIR} 缺 ${f}"; exit 1; }
    done
    ensure_secret console-tls generic \
        --from-file=ca.crt="${CERT_DIR}/ca.crt" \
        --from-file=server.crt="${CERT_DIR}/console.crt" \
        --from-file=server.key="${CERT_DIR}/console.key"
    ensure_secret console-ingress-tls tls \
        --cert="${CERT_DIR}/console.crt" --key="${CERT_DIR}/console.key"
else
    warn "证书目录不可用（${CERT_DIR:-未设置}），console-tls / console-ingress-tls 须已存在"
    kubectl get secret console-tls console-ingress-tls -n "${NAMESPACE}" >/dev/null 2>&1 \
        || { echo "错误: 集群缺 console 证书 secret 且未提供 --cert-dir"; exit 1; }
fi

ensure_secret hub-keycloak-database generic --from-literal=password="${KEYCLOAK_DB_PASSWORD}"
# postgres secret 由 postgresql chart 自动创建，本脚本不管理

# ---------- 阶段 2：postgresql ----------
log "==> postgresql（chart: $(basename "${PG_CHART}")）"
run helm upgrade --install postgresql "${PG_CHART}" -n "${NAMESPACE}" -f "${PG_VALUES}"

# ---------- 阶段 3：三组件（组件包 -> helm upgrade --install） ----------
# chart values: image.imageAddr 为完整镜像引用；模板 namespace 取 values.namespace
for pkg in "${PKGS[@]}"; do
    base="$(basename "${pkg}")"; base="${base%.tar.gz}"   # software-distribution-platform-<comp>-<ver>
    comp=""; version=""
    for c in "${COMPONENTS[@]}"; do
        prefix="software-distribution-platform-${c}-"
        if [[ "${base}" == "${prefix}"* ]]; then
            comp="${c}"; version="${base#"${prefix}"}"
            break
        fi
    done
    longname="software-distribution-platform-${comp}"
    image_ref="${REGISTRY}/${longname}:${version}"
    log "==> 组件=${comp} 版本=${version} 镜像=${image_ref}"

    WORKTMP="$(mktemp -d "${TMPDIR:-/tmp}/sdp-deploy-${comp}-XXXXXX")"
    chart_dir="${WORKTMP}/charts/${longname}"
    run tar -zxf "${pkg}" -C "${WORKTMP}"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        [[ -d "${chart_dir}" ]] || { echo "错误: 包内缺 chart 目录 ${chart_dir}"; rm -rf "${WORKTMP}"; exit 1; }
    fi
    run helm upgrade --install "${comp}" "${chart_dir}" -n "${NAMESPACE}" \
        --set "image.imageAddr=${image_ref}" \
        --set "namespace=${NAMESPACE}"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        rm -rf "${WORKTMP}"
    fi
done

log "全部完成"
