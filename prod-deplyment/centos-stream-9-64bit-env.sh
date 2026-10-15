#!/bin/bash
# =============================================================================
# centos-stream-9-64bit-env.sh —— CentOS Stream 9 (x86_64) SDP 构建环境就绪脚本
#
# 背景（2026-10-15 依据云上 ECS 实际装机过程固化）：
#   三仓 build/<组件>/build.sh 依赖 make/git/go/node+pnpm/docker(containerd)，
#   本脚本逐项判断，缺失才安装；全部步骤幂等，可重复执行。
#
# 网络现实（国内云 ECS 实测，2026-10-15）：
#   不可用/严重限速：download.docker.com、registry-1.docker.io、GitHub 大文件 clone
#   可用镜像源：mirrors.aliyun.com（docker-ce / golang）
#               registry.npmmirror.com（node 二进制 / npm 包）
#               docker.1panel.live / dockerproxy.net / docker.m.daocloud.io / docker.1ms.run
#   因此所有安装源默认走上述镜像，均可用环境变量覆盖。
#
# 用法:
#   ./centos-stream-9-64bit-env.sh                 # 检查 + 安装缺失项（需 root）
#   ./centos-stream-9-64bit-env.sh --check-only    # 只检查不安装（有缺失则 exit 1）
#   ./centos-stream-9-64bit-env.sh --pull-test     # 装完后附加 docker pull 基础镜像验证
#   ./centos-stream-9-64bit-env.sh -h | --help
#
# 版本/镜像源覆盖示例:
#   GO_VERSION=1.27.2 NODE_VERSION=v22.23.3 ./centos-stream-9-64bit-env.sh
#   NPM_REGISTRY=https://registry.npmmirror.com ./centos-stream-9-64bit-env.sh
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

# docker：官方源/download.docker.com 与 registry-1.docker.io 不可用，走 aliyun 源 + 多镜像
DOCKER_CE_REPO_FILE="/etc/yum.repos.d/docker-ce.repo"
DOCKER_MIRRORS=(
    "https://docker.1panel.live"
    "https://dockerproxy.net"
    "https://docker.m.daocloud.io"
    "https://docker.1ms.run"
)
PULL_TEST_IMAGES=( ubuntu:22.04 nginx:1.27-alpine )   # 三仓 Dockerfile 的全部基础镜像

# 代码目录治理（macOS tar 传输遗留），目录不存在则跳过
SDP_CODE_DIR="${SDP_CODE_DIR:-/var/sdp}"

CHECK_ONLY=0
PULL_TEST=0
MISSING=0

usage() {
    cat <<'USAGE'
用法: ./centos-stream-9-64bit-env.sh [选项]

选项:
  --check-only            只检查不安装（有缺失 exit 1，可用于流水线 gate）
  --pull-test             装完后附加 docker pull 基础镜像验证（ubuntu:22.04 / nginx:1.27-alpine）
  -h, --help              显示本帮助

环境变量覆盖（示例）:
  GO_VERSION=1.27.2            go 安装版本（最低要求 1.27.0）
  NODE_VERSION=v22.23.3        node 安装版本（最低要求 22.12.0）
  PNPM_VERSION=11.10.0         pnpm 安装版本
  NPM_REGISTRY=<url>           npm/pnpm registry
  GO_MIRROR=<url>              go 安装包镜像
  NODE_DIST_MIRROR=<url>       node 二进制镜像
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

# ---------- docker + containerd ----------
docker_ok() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1
}

install_docker_packages() {
    # 坑（2026-10-15 实测）：quoted heredoc（<<'EOF'）不做变量展开，
    # $releasever/$basearch 必须直接写、绝不能加反斜杠转义——
    # 曾因写成 \$releasever 把反斜杠漏进文件，baseurl 变 "...\9/..." → repomd.xml 404
    cat > "${DOCKER_CE_REPO_FILE}" <<'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/$releasever/$basearch/stable
enabled=1
gpgcheck=0
EOF
    log "安装 docker-ce / docker-ce-cli / containerd.io（aliyun 源）..."
    "${PKG_MGR}" -y install docker-ce docker-ce-cli containerd.io
}

ensure_docker_mirrors() {
    local dj="/etc/docker/daemon.json"
    mkdir -p /etc/docker
    if [[ -f "${dj}" ]] && grep -q 'registry-mirrors' "${dj}"; then
        log "daemon.json 已配置 registry-mirrors，跳过（如需更新请手工调整 ${dj}）"
        return 0
    fi
    if [[ -f "${dj}" ]]; then
        local bak="${dj}.bak.$(date +%Y%m%d%H%M%S)"
        cp -f "${dj}" "${bak}"
        warn "已有 ${dj}，备份至 ${bak} 后重写（合并 registry-mirrors）"
    fi
    local mirrors_json="" m
    for m in "${DOCKER_MIRRORS[@]}"; do
        if [[ -n "${mirrors_json}" ]]; then mirrors_json="${mirrors_json}, "; fi
        mirrors_json="${mirrors_json}\"${m}\""
    done
    cat > "${dj}" <<EOF
{
  "registry-mirrors": [${mirrors_json}],
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
    log "daemon.json 已写入 ${#DOCKER_MIRRORS[@]} 个 registry mirror（单镜像不稳，多镜像并列才可靠）"
    systemctl restart docker 2>/dev/null || true
}

ensure_docker() {
    if docker_ok; then
        log "docker 已就绪: $(docker --version | sed -n '1p')"
        return 0
    fi
    if [[ "${CHECK_ONLY}" -eq 1 ]]; then
        mark_missing "docker(+containerd.io) 及运行中的 daemon"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        install_docker_packages
    else
        log "docker 命令已存在但 daemon 不可达，尝试拉起..."
    fi
    ensure_docker_mirrors
    systemctl enable --now docker
    docker_ok || die "docker 安装后仍不可用，请排查: systemctl status docker / journalctl -u docker"
    log "docker 就绪: $(docker --version | sed -n '1p')"
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
    # macOS tar 传输两大遗留（2026-10-15 实测）：
    #   1) AppleDouble 元数据文件 ._*
    #   2) 归档保留原始 uid（如 501）→ git 因 dubious ownership 拒绝一切操作
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
    v="MISSING"; docker_ok && v="$(docker --version | sed -n '1p')"
    printf '%-12s %s\n' "docker" "${v}"
    v="MISSING"; command -v containerd >/dev/null 2>&1 && v="$(containerd --version | sed -n '1p')"
    printf '%-12s %s\n' "containerd" "${v}"
    command -v helm >/dev/null 2>&1 || warn "helm 未安装：prod-deplyment/run.sh 部署时需要；不在本脚本安装范围，请另行安装"
    log "============================="
}

pull_test() {
    local img
    for img in "${PULL_TEST_IMAGES[@]}"; do
        log "拉取验证: ${img}"
        docker pull "${img}"
    done
    log "基础镜像拉取验证通过（registry mirror 链路可用）"
}

# ---------- 主流程 ----------
main() {
    if ! grep -qE 'VERSION_ID="9"' /etc/os-release 2>/dev/null; then
        warn "当前系统不是 CentOS 9 系（$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || echo unknown)），继续执行但请自行确认兼容性"
    fi
    [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 x86_64（当前 $(uname -m)）"

    if [[ "${CHECK_ONLY}" -eq 0 ]]; then
        [[ "$(id -u)" -eq 0 ]] || die "安装需 root（写 /usr/local、/etc）；只检查请加 --check-only"
    fi

    ensure_base_pkgs
    ensure_docker
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
        docker_ok || die "docker 不可用，无法 pull-test"
        pull_test
    fi

    if [[ "${MISSING}" -gt 0 ]]; then
        echo "[env] 结果: ${MISSING} 项依赖缺失"
        exit 1
    fi
    log "环境就绪检查完成"
}

main "$@"
