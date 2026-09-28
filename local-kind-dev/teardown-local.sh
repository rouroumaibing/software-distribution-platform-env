#!/usr/bin/env bash
# teardown-local.sh —— 本地环境彻底清理（devops 根）：**clean --deep + 集群卸载 + docker 资源 + 工作区缓存**。
#
#   ./teardown-local.sh                 交互确认后执行全量清理
#   ./teardown-local.sh --yes           跳过确认（CI / 已确认 scope）
#   ./teardown-local.sh --dangling-only 步骤 5 只清悬空镜像（保留无引用的基础镜像）
#   ./teardown-local.sh --help          显示本帮助
#
# 清理范围（与 2026-09-23 人工清理实录一致）：
#   1. ./clean-local.sh --deep   停服务 + 三仓生成物 + node_modules/.pnpm-store
#   2. kind 集群 sdp-dev         kind delete cluster（集群数据一并消失，不可恢复）
#   3. 容器/网络                 kind-registry、sdp-pgtest、docker 网络 kind（显式点名，不误伤无关容器）
#   4. 镜像                      localhost:5000/*（动态收集）+ kindest/node、registry:2、postgres:16-alpine
#                                （基础镜像带在用守卫：仍有容器引用则跳过）
#   5. docker 回收               volume prune + builder prune + image prune -a（**默认即全量**）
#                                -a 会清掉所有「无容器引用」的镜像 —— 含 ubuntu:22.04 等可能与本项目
#                                无关的基础镜像，以及 envoy/keycloak/postgres 等可重拉镜像；
#                                仅「仍被容器引用」的会被保住（步骤 4 的在用守卫同一标准）。
#                                想保守（只清悬空镜像、保留基础镜像）加 --dangling-only
#   ⚠ 步骤 1/6 的 rm -rf 若被环境守卫（如批量删除确认）拦截，会留下 output/ node_modules 等残留；
#     脚本末尾的「生成物残留核对」会报错并以非零退出，不会静默假装清理成功。
#   6. ./clean-local.sh --all    .bin/ .kubeconfig .gocache/ .gomodcache（deploy-local.sh 按需重建）
#
# 保留（刻意不碰）：
#   - 非本项目容器（如 nostalgic_saha）及其镜像 —— 步骤 3/4 全部显式点名 + 在用守卫
#   - .dockerconfig/（docker 认证目录）
#
# 重建环境：./deploy-local.sh 全量重来。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本已迁至 software-distribution-platform-env/local-kind-dev/；工作区根（含 hub/runner/console/env/deploy 同级）在 SCRIPT_DIR 上两级。
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KIND_CLUSTER="sdp-dev"
PROJECT_CONTAINERS=(kind-registry sdp-pgtest)
BASE_IMAGES=(kindest/node registry:2 postgres:16-alpine)

ASSUME_YES=""
DANGLING_ONLY=""
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --dangling-only) DANGLING_ONLY=1 ;;
    --prune-all-images) echo "[teardown] 提示: --prune-all-images 已废弃（全量清理现为默认行为）" >&2 ;;
    -h|--help) awk 'NR>1 && $0 !~ /^#/ {exit} NR>1 {print}' "$0"; exit 0 ;;
    *) echo "[teardown] 忽略未知参数: $arg" >&2 ;;
  esac
done

log() { echo "[teardown] $*"; }

command -v docker >/dev/null 2>&1 || { log "ERROR: docker 不可用"; exit 1; }

# kind 不一定在 PATH（实测本机在 ~/.workbuddy/binaries/bin/kind），逐个回退探测
KIND="$(command -v kind 2>/dev/null || true)"
if [ -z "$KIND" ]; then
  for c in "$HOME/.workbuddy/binaries/bin/kind" /opt/homebrew/bin/kind /usr/local/bin/kind "$HOME/go/bin/kind"; do
    [ -x "$c" ] && KIND="$c" && break
  done
fi

# ---------- 0. scope 确认（不可逆，默认拦一道） ----------
if [ -z "$ASSUME_YES" ]; then
  echo "==============================================================="
  echo " 即将执行【彻底清理】（不可逆）："
  echo "   - kind 集群 '$KIND_CLUSTER' 及其全部数据（PG 台账/Keycloak 账号等）"
  echo "   - 容器: ${PROJECT_CONTAINERS[*]}"
  echo "   - 镜像: localhost:5000/* + ${BASE_IMAGES[*]}（在用跳过）"
  echo "   - docker 回收: volume / builder / 全部无容器引用的镜像${DANGLING_ONLY:+  (--dangling-only: 仅悬空)}"
  echo "   - 三仓生成物 + node_modules + .bin/.kubeconfig/Go 缓存"
  echo " 重建方式: ./deploy-local.sh"
  echo "==============================================================="
  printf "确认执行? [y/N] "
  read -r answer
  case "$answer" in
    y|Y) ;;
    *) log "已取消"; exit 0 ;;
  esac
fi

# ---------- 1. 先停服务 + 清三仓（clean-local.sh 自带停服务逻辑，幂等） ----------
if [ -x "$SCRIPT_DIR/clean-local.sh" ]; then
  log "步骤 1/6: clean-local.sh --deep（停服务 + 三仓生成物 + 下载依赖）..."
  "$SCRIPT_DIR/clean-local.sh" --deep || log "WARN: clean-local.sh --deep 非零退出，继续"
else
  log "WARN: 未找到 clean-local.sh，跳过仓级清理"
fi

# ---------- 2. kind 集群 ----------
if [ -n "$KIND" ]; then
  log "步骤 2/6: 删除 kind 集群 '$KIND_CLUSTER'..."
  "$KIND" delete cluster --name "$KIND_CLUSTER" 2>&1 | tail -1 || log "WARN: kind delete 非零退出（可能不存在）"
else
  log "步骤 2/6: 未找到 kind 二进制，跳过集群删除（集群容器将在步骤 3 兜底删除）"
fi

# ---------- 3. 容器与网络（显式点名，绝不误伤无关容器） ----------
log "步骤 3/6: 删除项目容器与 kind 网络..."
for c in "${PROJECT_CONTAINERS[@]}"; do
  docker inspect "$c" >/dev/null 2>&1 || continue
  docker rm -f "$c" >/dev/null 2>&1 && log "  容器已删: $c" || log "WARN: 删除容器失败: $c"
done
# 集群节点容器兜底（kind CLI 缺失时仍能清掉）
for node in $(docker ps -a --format '{{.Names}}' | grep -E "^${KIND_CLUSTER}(-control-plane|$)" || true); do
  docker rm -f "$node" >/dev/null 2>&1 && log "  节点容器已删: $node"
done
docker network rm kind >/dev/null 2>&1 && log "  网络已删: kind" || log "  网络 kind 不存在或仍被占用，跳过"

# ---------- 4. 镜像 ----------
log "步骤 4/6: 删除项目镜像..."
removed=0
while read -r img; do
  [ -z "$img" ] && continue
  docker rmi -f "$img" >/dev/null 2>&1 && { log "  已删: $img"; removed=$((removed+1)); }
done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost:5000/' || true)
log "  localhost:5000/* 共删 $removed 个"
# 基础镜像带在用守卫：仍有任何容器（运行或停止）引用则不动
for img in "${BASE_IMAGES[@]}"; do
  # 逐 tag 匹配（kindest/node 可能存在多个 tag，分别处理）
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -F "$img:" | while read -r t; do
    if [ -n "$(docker ps -a --filter ancestor="$t" --format '{{.ID}}')" ]; then
      log "  跳过（有容器引用）: $t"
    else
      docker rmi -f "$t" >/dev/null 2>&1 && log "  已删: $t" || log "  跳过: $t"
    fi
  done
done

# ---------- 5. docker 回收（volume / builder / image） ----------
log "步骤 5/6: docker volume / builder / image prune..."
docker volume prune -af 2>&1 | tail -1 | sed 's/^/[teardown]   /'
docker builder prune -af 2>&1 | tail -1 | sed 's/^/[teardown]   /'
# 默认全量（-a）：删除所有「无容器引用」的镜像；仅「仍被容器引用」的保留。
if [ -n "$DANGLING_ONLY" ]; then
  log "  --dangling-only: 仅清悬空镜像（保留无引用的基础镜像）..."
  docker image prune -f 2>&1 | tail -1 | sed 's/^/[teardown]   /'
else
  log "  全量清理无容器引用的镜像（-a）..."
  docker image prune -af 2>&1 | tail -1 | sed 's/^/[teardown]   /'
fi

# ---------- 6. 工作区级可再生资源（.bin/.kubeconfig/Go 缓存） ----------
if [ -x "$SCRIPT_DIR/clean-local.sh" ]; then
  log "步骤 6/6: clean-local.sh --all（.bin/.kubeconfig/Go 缓存）..."
  "$SCRIPT_DIR/clean-local.sh" --all --deep || log "WARN: clean-local.sh --all 非零退出"
fi

# ---------- 终态核对 ----------
log "---- 终态 ----"
log "剩余容器: $(docker ps -a --format '{{.Names}}' | tr '\n' ' ')"
log "剩余镜像: $(docker images -a --format '{{.Repository}}:{{.Tag}}' | tr '\n' ' ')"
docker system df 2>/dev/null | sed 's/^/[teardown] /'

# 生成物残留核对：clean-local.sh 若个别仓失败（如 rm -rf 被环境守卫拦截）会留下
# output/ node_modules 等；静默留下"看似清理成功"的残留代价高（实测一次留 707MB），故非零退出。
residue=""
for r in hub runner console; do
  d="$ROOT/software-distribution-platform-$r"
  [ -d "$d" ] || continue
  for g in output dist .vite .run coverage bin node_modules .pnpm-store; do
    [ -e "$d/$g" ] && residue="$residue $r/$g"
  done
done
for g in .bin .kubeconfig .logs .gocache .gomodcache; do
  [ -e "$ROOT/$g" ] && residue="$residue $g"
done
if [ -n "$residue" ]; then
  log "ERROR: 仍存在生成物残留:$residue"
  log "       （多因 rm -rf 批量删除被环境守卫拦截；见上方 clean-local.sh 输出）"
  exit 1
fi
log "done. 无生成物残留。重建环境: ./deploy-local.sh"
