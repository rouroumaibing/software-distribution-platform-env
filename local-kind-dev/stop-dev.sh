#!/usr/bin/env bash
# stop-dev.sh —— 结束本工作区本地联调产生的进程（devops 根目录）。
# 覆盖: go run hub/runner、编译出的三组件二进制、console vite dev server、
#       kubectl port-forward、air 热重载。
# 注意: 各代码仓库已自带 stop 命令（console: pnpm stop:dev；hub/runner: make stop-dev，
#       基于 pid 文件 + 进程组）。本脚本为工作区级兜底清扫（按进程路径模式），
#       pid 文件丢失或跨仓库残留时使用。
# 用法:
#   ./stop-dev.sh            # 默认只列出匹配进程，不杀
#   ./stop-dev.sh kill       # 结束全部匹配进程（先 TERM，5s 后残留再 KILL）
#   ./stop-dev.sh kill <pid> # 只结束指定 pid（必须是本工作区进程）
# 安全约定: 只按「工作区路径 + 明确模式」匹配，绝不按裸名（如 node/go）杀，
#           避免误伤系统或其他项目的进程。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本已迁至 software-distribution-platform-env/local-kind-dev/；工作区根（含 hub/runner/console/env/deploy 同级）在 SCRIPT_DIR 上两级。
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 匹配模式：完整命令行需同时命中（正则，egrep 方言）
PATTERNS=(
  "software-distribution-platform-hub"
  "software-distribution-platform-console"
  "software-distribution-platform-runner"
  "devops.*cmd/hub|cmd/hub.*devops"
  "vite.*console|console.*vite"
  "kubectl.*port-forward.*sdp-system"
)

match_lines() {
  local ps_out
  ps_out=$(/bin/ps -axo pid=,command= 2>/dev/null) || return 2
  local joined
  joined=$(printf '%s|' "${PATTERNS[@]}")
  joined="${joined%|}"
  echo "$ps_out" | grep -vE '^\s*PID' | grep -iE "$joined" | grep -vE "stop-dev.sh|clean-local.sh"
  # grep 无匹配返回 1 属正常（无进程），仅 ps 不可用返回 2
}

main() {
  local action="${1:-list}" arg="${2:-}"
  local lines
  lines=$(match_lines)
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "错误: ps 不可用，无法枚举进程。" >&2
    exit 1
  fi

  case "$action" in
    list)
      if [ -z "$lines" ]; then
        echo "没有匹配的本地联调进程。"
      else
        echo "以下为本工作区相关进程（未做任何操作）:"
        echo "$lines"
      fi
      ;;
    kill)
      if [ -n "$arg" ]; then
        # 指定 pid：校验确属本工作区进程
        if echo "$lines" | awk '{print $1}' | grep -qx "$arg"; then
          echo "TERM pid=$arg"
          kill -TERM "$arg" 2>/dev/null || true
        else
          echo "pid=$arg 不在本工作区进程列表中，拒绝结束。" >&2
          exit 1
        fi
        exit 0
      fi
      if [ -z "$lines" ]; then
        echo "没有匹配的本地联调进程，无需结束。"
        exit 0
      fi
      echo "将结束以下进程:"
      echo "$lines"
      local pids
      pids=$(echo "$lines" | awk '{print $1}')
      echo "$pids" | xargs kill -TERM 2>/dev/null || true
      sleep 5
      local left
      left=$(match_lines || true)
      if [ -n "$left" ]; then
        echo "以下进程 5s 后仍在，升级为 KILL:"
        echo "$left"
        echo "$left" | awk '{print $1}' | xargs kill -KILL 2>/dev/null || true
      fi
      echo "done."
      ;;
    *)
      echo "用法: $0 [list|kill [pid]]" >&2
      exit 1
      ;;
  esac
}

main "$@"
