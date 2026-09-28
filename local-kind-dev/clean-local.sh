#!/usr/bin/env bash
# clean-local.sh —— 工作区级清理（devops 根）：**先停服务，再清三仓生成物**。
#
#   ./clean-local.sh         停本地服务 + 清三仓生成物（保留下载依赖）
#   ./clean-local.sh --deep  额外删下载依赖（console 的 node_modules / .pnpm-store）
#   ./clean-local.sh --all   额外清工作区级可再生资源（.bin/ .kubeconfig .gocache/ .gomodcache）
#   ./clean-local.sh --purge-docs  连 hub 的 swaggo 生成物一起删（默认保留，见下）
#
# hub 的 docs/{docs.go,swagger.{json,yaml}} **是编译必需输入且已入库**（BUILD-ARTIFACTS.md 附 C 已裁决：
#   编译/打包必需 → 入库），所以本脚本默认**不删**它——删了 `make build` 必挂。确要删用 --purge-docs。
#
# 清理范围（只删生成物，绝不碰源码）：
#   hub / runner : output/（make build 的 output/bin、build.sh 的交付产物）、.run/、coverage/、
#                  历史位置 bin/、仓根裸编译二进制
#   console      : output/（vite 产物 output/dist、构建缓存、本地自签证书 output/certs、
#                  pnpm image 交付产物）、历史位置 dist/ .vite/ coverage/ .run/
#   工作区根     : .logs/（deploy-local.sh 的构建日志）
#
# 顺序为什么是「先停服务」：服务在运行时仍持有产物与 pid 文件，先停再删才不会留下孤儿进程，
#   也不会删出"进程还在、文件已没"的半状态。仓级 `make clean` / `pnpm clean` 各自也会先停自己的服务。
#
# 刻意不碰（属部署形态，由 deploy-local.sh / undeploy-local.sh 管理）：
#   - .dockerconfig/（DOCKER_CONFIG 目录，docker 用；空目录，删了没收益）
#   - kind 集群、kind-registry 容器与 docker 网络（卸载跑 ./undeploy-local.sh）
#   - 证书：集群内的 console-tls / console-ingress-tls 由运维/部署流程管理；本地文件在 console/output/certs
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本已迁至 software-distribution-platform-env/local-kind-dev/；工作区根（含 hub/runner/console/env/deploy 同级）在 SCRIPT_DIR 上两级。
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOS=(software-distribution-platform-hub software-distribution-platform-runner software-distribution-platform-console)

DEEP=""
ALL=""
PURGE_DOCS=""
for arg in "$@"; do
  case "$arg" in
    --deep)       DEEP=1 ;;
    --all)        ALL=1 ;;
    --purge-docs) PURGE_DOCS=1 ;;
    -h|--help) awk 'NR>1 && $0 !~ /^#/ {exit} NR>1 {print}' "$0"; exit 0 ;;
    *) echo "[clean] 忽略未知参数: $arg" >&2 ;;
  esac
done

log() { echo "[clean] $*"; }

# ---------- 1. 先停服务（工作区级兜底清扫：go run / vite / 编译产物 / port-forward） ----------
log "停止本地服务（工作区级，含 go run / vite / port-forward）..."
if [ -x "$SCRIPT_DIR/stop-dev.sh" ]; then
  "$SCRIPT_DIR/stop-dev.sh" kill || log "WARN: stop-dev.sh 返回非 0，继续清理"
else
  log "WARN: 未找到 stop-dev.sh，跳过工作区级清扫"
fi

# ---------- 2. 逐仓清理（各仓自带 clean 也会先停自己的服务，双保险） ----------
fail=0

clean_go_repo() {   # $1 = 仓名（hub | runner）
  local dir="$ROOT/software-distribution-platform-$1"
  [ -d "$dir" ] || { log "跳过（不存在）: $1"; return 0; }
  # hub 的 docs/{docs.go,swagger.{json,yaml}} 是**编译必需输入且已入库**（附 C 裁决），
  # 仓级 `make clean` 默认已保留它；本脚本默认与之保持一致，--purge-docs 时才显式传 PURGE_DOCS=1。
  local extra=""
  [ "$1" = "hub" ] && [ -n "$PURGE_DOCS" ] && extra="PURGE_DOCS=1"
  if [ -n "$DEEP" ]; then
    log "clean-deep: $1${extra:+ ($extra)}"
    ( cd "$dir" && make clean-deep $extra ) || { log "ERROR: $1 clean 失败"; fail=1; }
  else
    log "clean: $1${extra:+ ($extra)}"
    ( cd "$dir" && make clean $extra ) || { log "ERROR: $1 clean 失败"; fail=1; }
  fi
}

clean_console() {
  local dir="$ROOT/software-distribution-platform-console"
  [ -d "$dir" ] || { log "跳过（不存在）: console"; return 0; }
  if [ -n "$DEEP" ]; then
    log "clean: console (--deep)"
    ( cd "$dir" && bash scripts/clean.sh --deep ) || { log "ERROR: console clean 失败"; fail=1; }
  else
    log "clean: console"
    ( cd "$dir" && bash scripts/clean.sh ) || { log "ERROR: console clean 失败"; fail=1; }
  fi
}

clean_go_repo hub
clean_go_repo runner
clean_console

# ---------- 3. 可选：工作区级可再生资源（.bin 工具链 / kubeconfig / Go 缓存） ----------
if [ -n "$ALL" ]; then
  log "--all: 清理工作区级可再生资源（deploy-local.sh 会按需重建）..."
  # .bin/helm：缺失时 deploy-local.sh 自动重新下载
  rm -rf "$ROOT/.bin"
  # .kubeconfig：deploy-local.sh 每次都会 `kind export kubeconfig` 重建
  rm -f "$ROOT/.kubeconfig"
  # Go 构建缓存：当前 Go 环境并未使用这两个目录（go env 指向默认 ~/go/pkg/mod），属历史遗留
  rm -rf "$ROOT/.gocache" "$ROOT/.gomodcache"
  log "--all: done（.dockerconfig 保留：docker 认证目录）"
fi

# ---------- 4. 结果核对：生成物应无残留 ----------
log "核对残留（generated 目录应已不存在）..."
for d in "${REPOS[@]}"; do
  repo_dir="$ROOT/$d"
  [ -d "$repo_dir" ] || continue
  left=""
  for g in output dist .vite .run coverage bin; do
    [ -e "$repo_dir/$g" ] && left="$left $g"
  done
  if [ -n "$left" ]; then
    log "  $d: ⚠ 仍存在生成物目录:$left"
  else
    log "  $d: ✓ 无生成物目录残留"
  fi
done

# ---------- 5. 工作区级日志（deploy-local.sh 的构建日志） ----------
if [ -e "$ROOT/.logs" ]; then
  log "清理工作区级构建日志 .logs/ ..."
  rm -rf "$ROOT/.logs"
fi

# ---------- 6. 提示：不予自动清理的两类 ----------
log "提示: kind 集群 / registry 容器未动。仅卸载 helm: ./undeploy-local.sh；连集群带 docker 彻底清空: ./teardown-local.sh。"
log "提示: 证书 secret 在集群内（console-tls / console-ingress-tls），本脚本不触碰；"
log "      本地自签产物在 console/output/certs，已随 console 清理回收。"

if [ "$fail" -ne 0 ]; then
  log "有仓库清理失败，见上方 ERROR。"
  exit 1
fi
log "done."
