#!/bin/bash
# prod-deployment 部署脚本（云上托管 K8s）
# 流程：检查工作目录下组件包 -> 通配匹配解压 -> 上传镜像到 registry -> helm3 安装 chart（渲染预检 + 提交失败即终止；不等待/不验证运行态）
# 前提：组件包由三仓 build.sh 产出，格式 software-distribution-platform-<组件>-<版本>.tar.gz，
#       包内含 charts/（chart 源目录）与 images/（docker 归档格式的镜像 tar）。
# registry 的 project 须预先存在（如 harbor 的 sdp 项目），本脚本不创建。
# 镜像操作走 --runtime 指定的容器运行时：nerdctl（CCE 托管节点，默认；要求 >= 2.x，
# 见 docs 仓 shared/BUILD-TOOLCHAIN.md）或 docker（自管 ECS 节点）。

set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${SCRIPT_DIR}"          # 组件包所在目录
NAMESPACE="sdp-workflow"         # 部署命名空间（同时 --set 覆盖 chart values.namespace）
REGISTRY=""                      # 必填：镜像上传目标，如 registry.example.com/sdp
KUBECONFIG_PATH=""               # 可选：不传则继承环境 KUBECONFIG
REGISTRY_USER=""                 # 可选：registry 认证（提供则先 login）
REGISTRY_PASS=""
KEYCLOAK_IMAGE=""                # 可选：hub 子 chart 的 keycloak 镜像 repository 覆盖（默认沿用 chart values 的 harbor）
ROLLOUT_SVC_TARGET_PORT="80"     # canary 灰度服务 targetPort；example nginx 监听 80，覆盖 runner 的 8080 兜底
ROLLOUT_IMAGE_PULL_SECRET="default-secret"  # canary/stable Pod 拉取私有 registry 镜像的 secret；CCE 预置 default-secret
RUNTIME="nerdctl"                # 镜像操作运行时：nerdctl | docker
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
  --keycloak-image <repo> 可选，覆盖 hub 子 chart 的 keycloak 镜像 repository（tag 沿用 chart 值）
  --rollout-target-port <n> canary 灰度服务 targetPort，默认 ${ROLLOUT_SVC_TARGET_PORT}（example nginx 监听 80）
  --rollout-pull-secret <name> canary/stable Pod 拉取凭据，默认 ${ROLLOUT_IMAGE_PULL_SECRET}；留空=公开仓库
  --runtime <name>        镜像操作运行时 nerdctl|docker，默认 ${RUNTIME}
  --dry-run               只打印将执行的命令，不实际执行
  -h, --help              显示本帮助

示例:
  ./run.sh --registry harbor.sdpworkflow.com/sdp
  ./run.sh --registry registry.example.com/sdp --runtime docker
  ./run.sh --registry swr.cn-north-4.myhuaweicloud.com/<project> --keycloak-image swr.cn-north-4.myhuaweicloud.com/<project>/keycloak
  ./run.sh --registry harbor.sdpworkflow.com/sdp --dry-run
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry)       [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY="$2"; shift 2 ;;
        --namespace)      [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; NAMESPACE="$2"; shift 2 ;;
        --kubeconfig)     [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KUBECONFIG_PATH="$2"; shift 2 ;;
        --registry-user)  [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY_USER="$2"; shift 2 ;;
        --registry-pass)  [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; REGISTRY_PASS="$2"; shift 2 ;;
        --keycloak-image) [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; KEYCLOAK_IMAGE="$2"; shift 2 ;;
        --rollout-target-port) [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; ROLLOUT_SVC_TARGET_PORT="$2"; shift 2 ;;
        --rollout-pull-secret) [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; ROLLOUT_IMAGE_PULL_SECRET="$2"; shift 2 ;;
        --runtime)        [[ $# -lt 2 ]] && { echo "错误: $1 缺少参数"; usage; exit 1; }; RUNTIME="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)                echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log() { echo "[deploy] $*"; }
warn() { echo "[deploy][WARN] $*" >&2; }

# ---------- 前置检查 ----------
[[ "${RUNTIME}" == "nerdctl" || "${RUNTIME}" == "docker" ]] || { echo "错误: --runtime 只支持 nerdctl|docker"; exit 1; }
[[ -n "${REGISTRY}" ]] || { echo "错误: --registry 必填"; usage; exit 1; }
command -v "${RUNTIME}" >/dev/null 2>&1 || { echo "错误: 未找到 ${RUNTIME}"; exit 1; }
command -v helm  >/dev/null 2>&1 || { echo "错误: 未找到 helm3"; exit 1; }
if [[ -n "${KUBECONFIG_PATH}" ]]; then
    [[ -f "${KUBECONFIG_PATH}" ]] || { echo "错误: kubeconfig 不存在: ${KUBECONFIG_PATH}"; exit 1; }
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi
[[ -n "${REGISTRY_USER}" ]] || [[ -z "${REGISTRY_PASS}" ]] || { echo "错误: --registry-user 与 --registry-pass 须成对提供"; exit 1; }

# 组件包通配匹配（software-distribution-platform-*.tar.gz）
PKGS=( "${WORKDIR}"/software-distribution-platform-*.tar.gz )
if [[ ${#PKGS[@]} -eq 0 || ! -e "${PKGS[0]}" ]]; then
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

# 可选 registry 登录（提供凭据时执行；否则假定已 login）
if [[ -n "${REGISTRY_USER}" ]]; then
    run "${RUNTIME}" login "${REGISTRY%%/*}" -u "${REGISTRY_USER}" -p "${REGISTRY_PASS}"
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
    run "${RUNTIME}" load -i "${image_tar}"
    run "${RUNTIME}" tag "${longname}:${version}" "${image_ref}"
    run "${RUNTIME}" push "${image_ref}"

    # 3) helm3 安装（不加 --wait、不验证部署结果；install 报错仅告警继续下一个包）
    #    chart values: image.imageAddr 为完整镜像引用；模板 namespace 取 values.namespace，与 -n 保持一致
    #    hub 带 keycloak 子 chart，其镜像默认 harbor.sdpworkflow.com/sdp/keycloak；
    #    --keycloak-image 非空时覆盖 repository（tag 沿用 chart values）。
    helm_sets=(--set "image.imageAddr=${image_ref}" --set "namespace=${NAMESPACE}")
    # canary 灰度服务 <workload>-sdp 的 targetPort：example nginx 镜像声明 80，
    # 但 runner 的 resolveServiceTargetPort 从 stable workload 取不到时兜底 8080。
    # 显式设 80，避免流量采样 curl 打到 8080 空端口（RESULT FAIL）。
    if [[ "${component}" == "runner" && -n "${ROLLOUT_SVC_TARGET_PORT}" ]]; then
        helm_sets+=(--set "rollout.serviceTargetPort=${ROLLOUT_SVC_TARGET_PORT}")
    fi
    # 私有 registry：canary/stable Pod 显式带拉取凭据。运行命名空间由 runner 动态创建，
    # 部署期 patch default SA 的时机赶不上，必须在 Pod spec 注入（chart -> env 变量）。
    if [[ "${component}" == "runner" && -n "${ROLLOUT_IMAGE_PULL_SECRET}" ]]; then
        helm_sets+=(--set "rollout.imagePullSecret=${ROLLOUT_IMAGE_PULL_SECRET}")
    fi
    if [[ "${component}" == "hub" && -n "${KEYCLOAK_IMAGE}" ]]; then
        helm_sets+=(--set "keycloak.image.repository=${KEYCLOAK_IMAGE}")
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "[dry-run] helm upgrade --install ${component} ${chart_dir} -n ${NAMESPACE} ${helm_sets[*]}"
    else
        # 渲染预检：渲染失败是确定性错误（模板/schema/CRD 字段面），继续装下一个包必然得到残缺部署——终止部署链
        if ! helm template "${component}" "${chart_dir}" -n "${NAMESPACE}" "${helm_sets[@]}" >/dev/null 2>&1; then
            echo "错误: chart 渲染失败（${component}），helm template 预检未过，部署链终止" >&2
            exit 1
        fi
        # upgrade --install：首次=install，重复执行=upgrade（幂等；避免 re-run 报 release 已存在）。
        # 提交失败多为渲染/schema 级确定性错误，终止而非继续；运行态验证归 e2e，本脚本不 --wait。
        if helm upgrade --install "${component}" "${chart_dir}" -n "${NAMESPACE}" "${helm_sets[@]}" 2>&1 | sed 's/^/[helm] /'; then
            log "helm upgrade --install ${component} 已提交（幂等；不等待/不验证安装结果）"
        else
            echo "错误: helm upgrade --install ${component} 提交失败，部署链终止" >&2
            exit 1
        fi
    fi

    # 清理解压临时目录（mktemp 创建目录这一副作用不走 run() 门控，无论何种模式都须回收）
    rm -rf "${WORKTMP}"
done

log "全部组件包处理完成"
