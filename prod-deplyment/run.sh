#!/bin/bash
# prod-deployment 部署脚本（云上托管 K8s）
# 流程：检查工作目录下组件包 -> 通配匹配解压 -> 上传镜像到 registry -> helm3 安装 chart（不检查安装结果）
# 前提：组件包由三仓 build.sh 产出，格式 software-distribution-platform-<组件>-<版本>.tar.gz，
#       包内含 charts/（chart 源目录）与 images/（docker save 的镜像 tar）。
# registry 的 project 须预先存在（如 harbor 的 sdp 项目），本脚本不创建。

set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}"          # 组件包所在目录
NAMESPACE="sdp-workflow"         # 部署命名空间（同时 --set 覆盖 chart values.namespace）
REGISTRY=""                      # 必填：镜像上传目标，如 registry.example.com/sdp
KUBECONFIG_PATH=""               # 可选：不传则继承环境 KUBECONFIG
REGISTRY_USER=""                 # 可选：registry 认证（提供则先 docker login）
REGISTRY_PASS=""
DRY_RUN=0                        # 1 = 只打印将执行的命令，不实际执行

COMPONENTS=(hub runner console)  # 已知组件前缀（用于从包名稳健提取组件与版本）

usage() {
    cat <<USAGE
用法: ./run.sh --registry <registry[/project]> [选项]

选项:
  --registry <addr>       必填，镜像上传目标（含 project），如 registry.example.com/sdp
  --namespace <ns>        部署命名空间，默认 ${NAMESPACE}
  --kubeconfig <path>     指定 kubeconfig，默认继承环境 KUBECONFIG
  --registry-user <u>     可选，registry 认证用户（与 --registry-pass 成对）
  --registry-pass <p>     可选，registry 认证口令
  --dry-run               只打印将执行的命令，不实际执行
  -h, --help              显示本帮助

示例:
  ./run.sh --registry registry.example.com/sdp
  ./run.sh --registry registry.example.com/sdp --dry-run
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)       [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY="$2"; shift 2 ;;
        --namespace)      [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --kubeconfig)     [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --registry-user)  [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY_USER="$2"; shift 2 ;;
        --registry-pass)  [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY_PASS="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log() { echo "[deploy] $*"; }
warn() { echo "[deploy][WARN] $*" >&2; }

# ---------- 前置检查 ----------
[[ -n "${REGISTRY}" ]] || { echo "错误: --registry 必填"; usage; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "错误: 未找到 docker"; exit 1; }
command -v helm  >/dev/null 2>&1 || { echo "错误: 未找到 helm3"; exit 1; }
if [[ -n "${KUBECONFIG_PATH}" ]]; then
    [[ -f "${KUBECONFIG_PATH}" ]] || { echo "错误: kubeconfig 不存在: ${KUBECONFIG_PATH}"; exit 1; }
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi
[[ -n "${REGISTRY_USER}" ]] || [[ -z "${REGISTRY_PASS}" ]] || { echo "错误: --registry-user 与 --registry-pass 须成对提供"; exit 1; }

# 组件包通配匹配（software-distribution-platform-*.tar.gz）
PKGS=( "${WORKDIR}"/software-distribution-platform-*.tar.gz )
if [[ ! -e "${PKGS[0]}" ]]; then
    echo "错误: ${WORKDIR} 下未找到组件包（software-distribution-platform-*.tar.gz）"
    exit 1
fi

run() {  # dry-run 感知的命令执行
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# 可选 registry 登录（提供凭据时执行；否则假定已 docker login）
if [[ -n "${REGISTRY_USER}" ]]; then
    run docker login "${REGISTRY%%/*}" -u "${REGISTRY_USER}" -p "${REGISTRY_PASS}"
fi

# ---------- 主流程：循环处理每个包 ----------
for pkg in "${PKGS[@]}"; do
    base="$(basename "${pkg}")"; base="${base%.tar.gz}"   # e.g. software-distribution-platform-hub-v0.0.1

    # 从包名提取组件与版本（按已知组件前缀匹配，版本可含 -）
    component=""; version=""
    for comp in "${COMPONENTS[@]}"; do
        prefix="software-distribution-platform-${comp}-"
        if [[ "${base}" == "${prefix}"* ]]; then
            component="${comp}"; version="${base#"${prefix}"}"
            break
        fi
    done
    if [[ -z "${component}" ]]; then
        warn "无法识别包名，跳过: ${base}"
        continue
    fi
    longname="software-distribution-platform-${component}"
    image_ref="${REGISTRY}/${longname}:${version}"
    log "==> 组件=${component} 版本=${version} 包=$(basename "${pkg}")"

    # 1) 解压
    WORKTMP="$(mktemp -d "${TMPDIR:-/tmp}/sdp-deploy-${component}-XXXXXX")"
    run tar -zxf "${pkg}" -C "${WORKTMP}"
    chart_dir="${WORKTMP}/charts/${longname}"
    image_tar="${WORKTMP}/images/${longname}-${version}.tar"
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        [[ -d "${chart_dir}" ]] || { echo "错误: 包内缺 chart 目录 ${chart_dir}"; rm -rf "${WORKTMP}"; exit 1; }
        [[ -f "${image_tar}" ]] || { echo "错误: 包内缺镜像 tar ${image_tar}"; rm -rf "${WORKTMP}"; exit 1; }
    fi

    # 2) 上传镜像（load -> tag -> push；push 失败为脚本级错误，终止）
    run docker load -i "${image_tar}"
    run docker tag "${longname}:${version}" "${image_ref}"
    run docker push "${image_ref}"

    # 3) helm3 安装（不加 --wait、不验证部署结果；install 报错仅告警继续下一个包）
    #    chart values: image.imageAddr 为完整镜像引用；模板 namespace 取 values.namespace，与 -n 保持一致
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[dry-run] helm install ${component} ${chart_dir} -n ${NAMESPACE} --set image.imageAddr=${image_ref} --set namespace=${NAMESPACE}"
    else
        if helm install "${component}" "${chart_dir}" -n "${NAMESPACE}" \
               --set "image.imageAddr=${image_ref}" \
               --set "namespace=${NAMESPACE}" 2>&1 | sed 's/^/[helm] /'; then
            log "helm install ${component} 已提交（不等待/不验证安装结果）"
        else
            warn "helm install ${component} 提交异常（release 已存在或其他错误），继续下一个包"
        fi
    fi

    # 清理解压临时目录
    if [[ "${DRY_RUN}" -ne 1 ]]; then
        rm -rf "${WORKTMP}"
    fi
done

log "全部组件包处理完成"
