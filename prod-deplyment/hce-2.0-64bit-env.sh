#!/bin/bash
# =============================================================================
# hce-2.0-64bit-env.sh —— Huawei Cloud EulerOS 2.0 (x86_64) SDP 构建环境就绪脚本
#
# 背景（2026-10-19 依据 CCE 节点实测装机过程固化）：
#   三仓 build/<组件>/build.sh 依赖 make/git/go/node+pnpm，以及镜像构建能力。
#   本脚本逐项判断，缺失才安装；全部步骤幂等，可重复执行。
#
# 与 centos-stream-9-64bit-env.sh 的关键差异（CCE 节点特有）：
#   * 节点是华为云 CCE 托管 K8s 节点：kubelet + CCE 托管 containerd
#     (/usr/local/bin/containerd，socket /run/containerd/containerd.sock) 在跑。
#     **绝不在本节点安装 docker / docker-engine / containerd.io RPM**——
#     containerd.service 会与 CCE 托管单元冲突，可能弄坏 kubelet。
#   * 镜像构建走 build.sh 已内置的 nerdctl + buildkitd(containerd worker) 路线，
#     本脚本只补 nerdctl / buildkitd 两个用户态二进制（GitHub release）。
#   * 副作用红利：nerdctl 构建的镜像直接落在 CCE containerd 的 default namespace，
#     kubelet 使用需在 k8s.io namespace 或推到仓库（交付以 sdp_save 的 .tar 为准，不受影响）。
#
# 网络现实（HCE 2.0 CCE 节点实测，2026-10-19）：
#   可用：HCE base/updates dnf 源（git/make）、GitHub release（nerdctl/buildkit）、
#         mirrors.aliyun.com（golang）、registry.npmmirror.com（node 二进制 / npm 包）
#   docker-engine 在 HCE 源里有（18.09）但禁用：原因见上。
#
# 用法:
#   ./hce-2.0-64bit-env.sh                 # 检查 + 安装缺失项（需 root）
#   ./hce-2.0-64bit-env.sh --check-only    # 只检查不安装（有缺失则 exit 1）
#   ./hce-2.0-64bit-env.sh --pull-test     # 装完后附加 nerdctl pull 基础镜像验证
#   ./hce-2.0-64bit-env.sh -h | --help
#
# 版本/镜像源覆盖示例:
#   GO_VERSION=1.27.2 NODE_VERSION=v22.23.3 ./hce-2.0-64bit-env.sh
#   NERDCTL_VERSION=v2.4.1 BUILDKIT_VERSION=v0.34.0 ./hce-2.0-64bit-env.sh
#
# 范围说明：prod-deplyment/run.sh 运行还需要 helm3 + kubeconfig，属部署机依赖，
#           不在本脚本安装范围内（缺失时仅告警）。
# =============================================================================

set -euo pipefail

# ---------- 可变输入（参数化，逻辑体不写死） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# go：go.mod 要求 >= 1.27.0（MIN），默认安装 2026-10 时点最新 1.27.2
MIN_GO_VERSION="1.27.0"
GO_VERSION="${GO_VERSION:-1.27.2}"
GO_MIRROR="${GO_MIRROR:-https://mirrors.aliyun.com/golang}"

# node：Vite 7 的 Node 22 线基线 22.12（MIN），默认安装 22.23.3
MIN_NODE_VERSION="22.12.0"
NODE_VERSION="${NODE_VERSION:-v22.23.3}"
NODE_DIST_MIRROR="${NODE_DIST_MIRROR:-https://registry.npmmirror.com/-/binary/node}"
NODEJS_INSTALL_DIR="/usr/local/lib/nodejs"

# pnpm：package.json packageManager 钉 pnpm@11.10.0，大版本须为 11
PNPM_MAJOR="11"
PNPM_VERSION="${PNPM_VERSION:-11.10.0}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"

# nerdctl / buildkitd：GitHub release，仅二进制（不动 CCE 的 containerd）
NERDCTL_VERSION="${NERDCTL_VERSION:-v2.4.1}"
BUILDKIT_VERSION="${BUILDKIT_VERSION:-v0.34.0}"
CONTAINERD_SOCK="${CONTAINERD_SOCK:-/run/containerd/containerd.sock}"

PULL_TEST_IMAGES=( ubuntu:22.04 nginx:1.27-alpine )   # 三仓 Dockerfile 的全部基础镜像

# 代码目录治理（macOS tar 传输遗留），目录不存在则跳过
SDP_CODE_DIR="${SDP_CODE_DIR:-/var/sdp}"

CHECK_ONLY=0
PULL_TEST=0
MISSING=0

usage() {
    cat <<'USAGE'
用法: ./hce-2.0-64bit-env.sh [选项]

选项:
  --check-only            只检查不安装（有缺失 exit 1，可用于流水线 gate）
  --pull-test             装完后附加 nerdctl pull 基础镜像验证（ubuntu:22.04 / nginx:1.27-alpine）
  -h, --help              显示本帮助

环境变量覆盖（示例）:
  GO_VERSION=1.27.2            go 安装版本（最低要求 1.27.0）
  NODE_VERSION=v22.23.3        node 安装版本（最低要求 22.12.0）
  PNPM_VERSION=11.10.0         pnpm 安装版本
  NPM_REGISTRY=<url>           npm/pnpm registry
  GO_MIRROR=<url>              go 安装包镜像
  NODE_DIST_MIRROR=<url>       node 二进制镜像
  NERDCTL_VERSION=v2.4.1       nerdctl GitHub release tag
  BUILDKIT_VERSION=v0.34.0     buildkit GitHub release tag
  CONTAINERD_SOCK=<path>       containerd socket（缺省 CCE 标准路径）
  SDP_CODE_DIR=/var/sdp        代码目录（存在则清理 macOS tar 遗留并归一属主）
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)  CHECK_ONLY=1; shift ;;
        --pull-test)   PULL_TEST=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "错误: 未知参数 $1"; usage; exit 1 ;;
    esac
done

log()  { echo "[env] $*"; }
warn() { echo "[env][WARN] $*" >&2; }
die()  { echo "[env][ERROR] $*" >&2; exit 1; }
mark_missing() { MISSING=$((MISSING + 1)); warn "缺失: $*"; }

# 语义化版本比较：ver_ge <have> <want>，have >= want 时返回 0
ver_ge() {
    local have="${1}" want="${2}"
    [[ -n "${have}" && -n "${want}" ]] || return 1
    [[ "$(printf '%s\n%s\n' "${have}" "${want}" | sort -V | head -1)" == "${want}" ]]
}

# ---------- 基础依赖（dnf） ----------
PKG_MGR="$(command -v dnf || command -v yum || true)"
[[ -n "${PKG_MGR}" ]] || die "未找到 dnf/yum 包管理器"

ensure_base_pkgs() {
    local pkg
    for pkg in git make curl tar; do
        if command -v "${pkg}" >/dev/null 2>&1; then
            log "基础依赖已装: ${pkg}"
        elif [[ "${CHECK_ONLY}" -eq 1 ]]; then
            mark_missing "${pkg}（dnf 安装）"
        else
            log "安装 ${pkg}..."
            "${PKG_MGR}" -y install "${pkg}"
        fi
    done
}

# ---------- containerd（CCE 托管，只验证、绝不安装/改动） ----------
containerd_ok() {
    [[ -S "${CONTAINERD_SOCK}" ]] || return 1
    command -v nerdctl >/dev/null 2>&1 && nerdctl info >/dev/null 2>&1
}

ensure_containerd() {
    # CCE 节点铁律：containerd 由 CCE 托管（containerd-monit 看护），
    # 装 docker/docker-engine/containerd.io 会与其 systemd 单元冲突。
    # 本脚本只验证 socket 可达；缺失时给出处置建议并计缺失，不做任何安装。
    if [[ -S "${CONTAINERD_SOCK}" ]]; then
        log "containerd socket 存在: ${CONTAINERD_SOCK}（CCE 托管，保持不动）"
        return 0
    fi
    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        mark_missing "containerd socket ${CONTAINERD_SOCK}（CCE 托管组件；缺失请走 CCE 侧排查，勿手工安装 docker）"
        return 0
    fi
    mark_missing "containerd socket ${CONTAINERD_SOCK} 不存在；CCE 托管组件缺失请走 CCE 侧排查（本脚本绝不代装 docker/containerd 以免冲突）"
    return 0
}

# ---------- nerdctl ----------
nerdctl_ok() {
    command -v nerdctl >/dev/null 2>&1
}

ensure_nerdctl() {
    if nerdctl_ok; then
        log "nerdctl 已就绪: $(nerdctl --version 2>/dev/null | sed -n '1p')"
        return 0
    fi
    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        mark_missing "nerdctl（GitHub release 二进制）"
        return 0
    fi
    local ver="${NERDCTL_VERSION#v}"
    local url="https://github.com/containerd/nerdctl/releases/download/${NERDCTL_VERSION}/nerdctl-${ver}-linux-amd64.tar.gz"
    log "安装 nerdctl ${NERDCTL_VERSION}（GitHub release）..."
    curl -fSL --retry 3 -o /tmp/nerdctl.tar.gz "${url}"
    tar -C /usr/local/bin -xzf /tmp/nerdctl.tar.gz nerdctl
    rm -f /tmp/nerdctl.tar.gz
    nerdctl_ok || die "nerdctl 安装后仍不可用"
    log "nerdctl 就绪: $(nerdctl --version 2>/dev/null | sed -n '1p')"
}

# ---------- buildkitd（nerdctl build 的后端，就地拉起） ----------
# 2026-10-19 HCE 节点实测两个坑：
#   1. buildkit v0.34 的 --containerd-worker 已从 bool 变为 string(true/false/auto)，
#      build.sh ensure_nerdctl 里的旧写法 "--containerd-worker --addr ..." 会把 --addr
#      吃进值里导致 strconv.ParseBool 崩溃。本脚本用 "--containerd-worker=true" 显式赋值，
#      新旧 buildkit 通吃；build.sh 检测到 buildkitd 已在运行即跳过启动，无需改动它。
#   2. CCE 节点直连 registry-1.docker.io 不通，镜像源可达。mirror 写进 buildkit 默认
#      配置路径 /etc/buildkit/buildkitd.toml（省 --config 旗标），幂等：已有 registry
#      段则不动。
BUILDKIT_MIRRORS="${BUILDKIT_MIRRORS:-docker.1panel.live dockerproxy.net docker.m.daocloud.io docker.1ms.run}"
BUILDKIT_ADDR="${BUILDKIT_ADDR:-tcp://127.0.0.1:1234}"

buildkitd_ok() {
    command -v buildkitd >/dev/null 2>&1
}

ensure_buildkit_mirror_conf() {
    local conf="/etc/buildkit/buildkitd.toml"
    if [[ -f "${conf}" ]] && grep -q 'registry."docker.io"' "${conf}"; then
        log "buildkit mirror 配置已存在，跳过: ${conf}"
        return 0
    fi
    mkdir -p /etc/buildkit
    {
        echo '# 由 hce-2.0-64bit-env.sh 生成（CCE 节点 docker.io 直连不通，走镜像源）'
        echo '[registry."docker.io"]'
        local m mirrors_json=""
        for m in ${BUILDKIT_MIRRORS}; do
            mirrors_json="${mirrors_json:+${mirrors_json}, }\"https://${m}\""
        done
        echo "  mirrors = [${mirrors_json}]"
    } > "${conf}"
    log "buildkit mirror 配置写入: ${conf}"
}

ensure_buildkitd() {
    if buildkitd_ok; then
        log "buildkitd 已就绪: $( (buildkitd --version 2>/dev/null || echo buildkitd) | sed -n '1p')"
    else
        if [[ "${CHECK_ONLY}" -eq 1 ]]; then
            mark_missing "buildkitd（GitHub release 二进制，nerdctl build 必需）"
            return 0
        fi
        # 注意（404 排查 2026-10-19 实测）：buildkit 资产名是点分隔且**保留 v 前缀**
        # （buildkit-v0.34.0.linux-amd64.tar.gz），与 nerdctl 资产名
        # （nerdctl-2.4.1-linux-amd64.tar.gz，连字符、无 v）不同，不能共用剥前缀的 ver
        local url="https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz"
        log "安装 buildkit ${BUILDKIT_VERSION}（GitHub release）..."
        curl -fSL --retry 3 -o /tmp/buildkit.tar.gz "${url}"
        tar -C /usr/local -xzf /tmp/buildkit.tar.gz
        rm -f /tmp/buildkit.tar.gz
        buildkitd_ok || die "buildkitd 安装后仍不可用"
        log "buildkitd 就绪: $( (buildkitd --version 2>/dev/null || echo buildkitd) | sed -n '1p')"
    fi

    [[ "${CHECK_ONLY}" -eq 1 ]] && return 0

    # mirror 配置 + 就地拉起（幂等：已在运行则跳过）
    if ! grep -q 'registry."docker.io"' /etc/buildkit/buildkitd.toml 2>/dev/null; then
        ensure_buildkit_mirror_conf
    fi
    if pgrep -x buildkitd >/dev/null 2>&1; then
        log "buildkitd 已在运行（PID $(pgrep -x buildkitd | head -1)），跳过启动"
    elif [[ -S "${CONTAINERD_SOCK}" ]]; then
        log "拉起 buildkitd（containerd worker, addr=${BUILDKIT_ADDR}）..."
        nohup buildkitd --containerd-worker=true --addr "${BUILDKIT_ADDR}" \
            >>/var/log/buildkitd.log 2>&1 </dev/null &
        sleep 3
        pgrep -x buildkitd >/dev/null 2>&1 \
            || die "buildkitd 拉起失败，请查看 /var/log/buildkitd.log"
        log "buildkitd 已拉起（PID $(pgrep -x buildkitd | head -1)）"
    else
        warn "containerd socket 不存在，未拉起 buildkitd（等 containerd 就绪后手工拉起）"
    fi
}

# ---------- go ----------
go_ok() {
    command -v go >/dev/null 2>&1 || return 1
    local v
    v="$( (go version 2>/dev/null || true) | sed -nE 's/^go version go([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' )"
    [[ -n "${v}" ]] || return 1
    ver_ge "${v}" "${MIN_GO_VERSION}"
}

ensure_go() {
    if go_ok; then
        log "go 已就绪: $(go version)"
        return 0
    fi
    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        mark_missing "go >= ${MIN_GO_VERSION}"
        return 0
    fi
    local tarball="go${GO_VERSION}.linux-amd64.tar.gz"
    log "安装 go ${GO_VERSION}（${GO_MIRROR}）..."
    curl -fSL --retry 3 -o "/tmp/${tarball}" "${GO_MIRROR}/${tarball}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    go_ok || die "go 安装后仍不满足 >= ${MIN_GO_VERSION}，请检查 GO_VERSION=${GO_VERSION}"
    log "go 就绪: $(go version)"
}

# ---------- node ----------
node_ok() {
    command -v node >/dev/null 2>&1 || return 1
    local v
    v="$( (node --version 2>/dev/null || true) | sed 's/^v//' )"
    [[ -n "${v}" ]] || return 1
    ver_ge "${v}" "${MIN_NODE_VERSION}"
}

ensure_node() {
    if node_ok; then
        log "node 已就绪: $(node --version)"
        return 0
    fi
    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        mark_missing "node >= v${MIN_NODE_VERSION}"
        return 0
    fi
    local tarball="node-${NODE_VERSION}-linux-x64.tar.gz"
    log "安装 node ${NODE_VERSION}（${NODE_DIST_MIRROR}）..."
    curl -fSL --retry 3 -o "/tmp/${tarball}" "${NODE_DIST_MIRROR}/${NODE_VERSION}/${tarball}"
    mkdir -p "${NODEJS_INSTALL_DIR}"
    tar -C "${NODEJS_INSTALL_DIR}" -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"
    ln -sf "${NODEJS_INSTALL_DIR}/node-${NODE_VERSION}-linux-x64/bin/node" /usr/local/bin/node
    ln -sf "${NODEJS_INSTALL_DIR}/node-${NODE_VERSION}-linux-x64/bin/npm"  /usr/local/bin/npm
    ln -sf "${NODEJS_INSTALL_DIR}/node-${NODE_VERSION}-linux-x64/bin/npx"  /usr/local/bin/npx
    node_ok || die "node 安装后仍不满足 >= v${MIN_NODE_VERSION}"
    log "node 就绪: $(node --version)"
}

# ---------- pnpm ----------
pnpm_ok() {
    command -v pnpm >/dev/null 2>&1 || return 1
    local v
    v="$(pnpm --version 2>/dev/null || true)"
    [[ "${v}" == "${PNPM_MAJOR}".* ]]
}

ensure_pnpm() {
    if pnpm_ok; then
        log "pnpm 已就绪: $(pnpm --version)"
        return 0
    fi
    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        mark_missing "pnpm ${PNPM_MAJOR}.x（npm -g 安装）"
        return 0
    fi
    command -v npm >/dev/null 2>&1 || die "npm 不可用，无法安装 pnpm（先确保 node 就绪）"
    log "安装 pnpm@${PNPM_VERSION}（registry=${NPM_REGISTRY}）..."
    npm install -g "pnpm@${PNPM_VERSION}" --registry="${NPM_REGISTRY}"
    # npm -g 的 bin 落在 node 安装根的 bin/ 下，补一个全局 symlink
    ln -sf "$(npm prefix -g)/bin/pnpm" /usr/local/bin/pnpm
    pnpm_ok || die "pnpm 安装后仍不满足 ${PNPM_MAJOR}.x"
    log "pnpm 就绪: $(pnpm --version)"
}

# ---------- 构建机网络韧性（/root/.npmrc，键存在则不动，幂等） ----------
ensure_npmrc() {
    local f="/root/.npmrc" pair key
    [[ -f "${f}" ]] || touch "${f}"
    for pair in \
        "registry=${NPM_REGISTRY}" \
        "network-concurrency=4" \
        "fetch-retries=6" \
        "fetch-retry-mintimeout=20000" \
        "fetch-retry-maxtimeout=120000" \
        "fetch-timeout=600000"; do
        key="${pair%%=*}"
        if ! grep -qE "^${key}=" "${f}"; then
            echo "${pair}" >> "${f}"
            log "npmrc 写入: ${pair}"
        fi
    done
}

# ---------- 代码目录治理（macOS tar 传输遗留，可选） ----------
ensure_sdp_code_usable() {
    local dir="${SDP_CODE_DIR}"
    if [[ ! -d "${dir}" ]]; then
        log "代码目录 ${dir} 不存在，跳过传输遗留治理"
        return 0
    fi
    # macOS tar 传输两大遗留：
    #   1) AppleDouble 元数据文件 ._*
    #   2) 归档保留原始 uid → git 因 dubious ownership 拒绝一切操作
    if find "${dir}" -name '._*' -type f -print -quit 2>/dev/null | grep -q .; then
        log "清理 AppleDouble 元数据文件（${dir} 下 ._*）..."
        find "${dir}" -name '._*' -type f -delete
    fi
    if [[ -n "$(find "${dir}" ! -user root -print -quit 2>/dev/null)" ]]; then
        log "归一属主为 root:root（${dir}）..."
        chown -R root:root "${dir}"
    fi
}

# ---------- 核验 ----------
verify_all() {
    log "========== 环境核验 =========="
    local v
    v="MISSING"; command -v make >/dev/null 2>&1 && v="$(make --version | sed -n '1p')"
    printf '%-12s %s\n' "make" "${v}"
    v="MISSING"; command -v git >/dev/null 2>&1 && v="$(git --version)"
    printf '%-12s %s\n' "git" "${v}"
    v="MISSING(需 >= ${MIN_GO_VERSION})"; go_ok && v="$(go version)"
    printf '%-12s %s\n' "go" "${v}"
    v="MISSING(需 >= v${MIN_NODE_VERSION})"; node_ok && v="$(node --version)"
    printf '%-12s %s\n' "node" "${v}"
    v="MISSING(需 ${PNPM_MAJOR}.x)"; pnpm_ok && v="$(pnpm --version)"
    printf '%-12s %s\n' "pnpm" "${v}"
    v="MISSING(${CONTAINERD_SOCK})"; [[ -S "${CONTAINERD_SOCK}" ]] && v="OK(CCE 托管)"
    printf '%-12s %s\n' "containerd" "${v}"
    v="MISSING"; nerdctl_ok && v="$(nerdctl --version 2>/dev/null | sed -n '1p')"
    printf '%-12s %s\n' "nerdctl" "${v}"
    v="MISSING"; buildkitd_ok && v="$( (buildkitd --version 2>/dev/null || echo OK) | sed -n '1p')"
    printf '%-12s %s\n' "buildkitd" "${v}"
    command -v helm >/dev/null 2>&1 || warn "helm 未安装：prod-deplyment/run.sh 部署时需要；不在本脚本安装范围，请另行安装"
    log "============================="
}

pull_test() {
    local img
    for img in "${PULL_TEST_IMAGES[@]}"; do
        log "拉取验证: ${img}"
        nerdctl pull "${img}"
    done
    log "基础镜像拉取验证通过（containerd 链路可用）"
}

# ---------- 主流程 ----------
main() {
    if ! grep -qE 'ID="?hce"?' /etc/os-release 2>/dev/null; then
        warn "当前系统不是 HCE 2.0（$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || echo unknown)），继续执行但请自行确认兼容性"
    fi
    [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64（当前 $(uname -m)）"

    if [[ "${CHECK_ONLY}" -eq 0 ]]; then
        [[ "$(id -u)" -eq 0 ]] || die "安装需 root（写 /usr/local）；只检查请加 --check-only"
    fi

    ensure_base_pkgs
    ensure_containerd
    ensure_nerdctl
    ensure_buildkitd
    ensure_go
    ensure_node
    ensure_pnpm

    if [[ "${CHECK_ONLY}" -eq 0 ]]; then
        ensure_npmrc
        ensure_sdp_code_usable
    fi

    verify_all

    if [[ "${PULL_TEST}" -eq 1 ]]; then
        [[ "${CHECK_ONLY}" -eq 0 ]] || die "--pull-test 需实际安装模式（不能与 --check-only 同用）"
        containerd_ok || die "containerd/nerdctl 不可达，无法 pull-test"
        pull_test
    fi

    if [[ "${MISSING}" -gt 0 ]]; then
        echo "[env] 结果: ${MISSING} 项依赖缺失"
        exit 1
    fi
    log "环境就绪检查完成"
}

main "$@"
