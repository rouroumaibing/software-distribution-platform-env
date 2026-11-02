#!/usr/bin/env bash
# 离线镜像缓存加载器：把 images/ 下 docker save 落盘的 tar 全部 load 进宿主 docker。
# 独立工具，不被 deploy-local.sh 引用；部署前手动执行一次即可，后续拉起环境
# 不再依赖到 docker.io 的出网（解决本机出网握手不稳导致的拉取卡死）。
#
# 用法：
#   ./load-images.sh                 # 加载 images/ 下全部 tar（已存在的镜像 docker load 幂等跳过层）
#   ./load-images.sh -l              # 仅列出缓存内容与对应 tar 大小
#   ./load-images.sh <file.tar> ...  # 只加载指定 tar
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${IMG_DIR:-${SCRIPT_DIR}/images}"
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-600}"

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -eq 0 ]] || { [[ "$1" == "-h" || "$1" == "--help" ]] && usage; }

command -v docker >/dev/null 2>&1 || { echo "ERROR: 未找到 docker 命令" >&2; exit 1; }
[[ -d "${IMG_DIR}" ]] || { echo "ERROR: 镜像缓存目录不存在: ${IMG_DIR}（先经 save-images 流程落盘）" >&2; exit 1; }

# 外层超时可选：macOS 无 GNU timeout（gtimeout 由 coreutils 提供）；二者都缺则直接 load——
# 本地 tar 的 docker load 是纯本地 I/O，无网络等待面，去掉外层超时不引入卡死风险。
RUN_LOAD=(docker load -i)
if command -v timeout >/dev/null 2>&1; then
    RUN_LOAD=(timeout "${DOCKER_TIMEOUT}" docker load -i)
elif command -v gtimeout >/dev/null 2>&1; then
    RUN_LOAD=(gtimeout "${DOCKER_TIMEOUT}" docker load -i)
fi

if [[ $# -gt 0 ]]; then
    TARS=("$@")
else
    TARS=("${IMG_DIR}"/*.tar)
    [[ ${#TARS[@]} -gt 0 && -e "${TARS[0]}" ]] || { echo "ERROR: ${IMG_DIR} 下无 *.tar" >&2; exit 1; }
fi

echo "=== 从 ${IMG_DIR} 加载离线镜像缓存 ==="
ok=0; fail=0
for tar in "${TARS[@]}"; do
    [[ -f "${tar}" ]] || { echo "SKIP（不存在）: ${tar}"; continue; }
    fn="$(basename "${tar}")"
    printf 'loading: %s (%s) ... ' "${fn}" "$(du -h "${tar}" | cut -f1)"
    if "${RUN_LOAD[@]}" "${tar}" >/dev/null 2>&1; then
        echo "OK"; ok=$((ok+1))
    else
        echo "FAIL"; fail=$((fail+1))
    fi
done
echo "=== 完成: ok=${ok} fail=${fail} ==="
[[ ${fail} -eq 0 ]] || exit 1
