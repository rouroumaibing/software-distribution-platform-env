#!/bin/bash
# stop-bg.sh — 按 pidfile 停止 run-bg.sh 启动的后台进程（整进程组）。
#
# 与 `pkill -f <模式>` 的本质差异：按 pid 精确停止，不做任何 cmdline 模式匹配，
# 因此不存在「模式命中执行会话自身」的自匹配误杀问题。
#
# 用法：
#   ./stop-bg.sh <pidfile>          # SIGTERM 整进程组，宽限 10s 后仍存活则 SIGKILL
#   ./stop-bg.sh <pidfile> --check  # 只查状态不停止
#
# pidfile 约定：由 run-bg.sh 生成（<日志文件>.pid）。

set -euo pipefail

usage() {
    cat <<USAGE
用法: ./stop-bg.sh <pidfile> [--check]

  --check   只显示进程状态，不停止
USAGE
}

[[ $# -ge 1 ]] || { echo "错误: 需要 <pidfile>"; usage; exit 1; }
PIDFILE="$1"; MODE="${2:-}"
[[ -f "${PIDFILE}" ]] || { echo "错误: pidfile 不存在: ${PIDFILE}"; exit 1; }
pid="$(cat "${PIDFILE}")"
[[ "${pid}" =~ ^[0-9]+$ ]] || { echo "错误: pidfile 内容非法: ${pid}"; exit 1; }

if ! kill -0 "${pid}" 2>/dev/null; then
    echo "[stop-bg] 进程 ${pid} 不存在（已退出或已停止）；清理 pidfile"
    rm -f "${PIDFILE}"
    exit 0
fi

# 进程组 id：setsid 启动时 pgid == pid；取不到（非 run-bg 启动）则只杀主进程。
pgid="$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
target="-${pgid:-${pid}}"
[[ "${pgid}" == "${pid}" ]] || echo "[stop-bg][WARN] pgid(${pgid:-?}) != pid(${pid})，非 setsid 启动；仅按进程组尽力停止"

if [[ "${MODE}" == "--check" ]]; then
    echo "[stop-bg] pid=${pid} pgid=${pgid:-?} 存活：$(ps -o etime=,cmd= -p "${pid}" 2>/dev/null | head -1)"
    exit 0
fi

echo "[stop-bg] SIGTERM 进程组 ${target}"
kill -TERM "${target}" 2>/dev/null || true
for _ in $(seq 1 10); do
    kill -0 "${pid}" 2>/dev/null || { echo "[stop-bg] 已停止（TERM 生效）"; rm -f "${PIDFILE}"; exit 0; }
    sleep 1
done
echo "[stop-bg] 10s 未退出，SIGKILL 进程组 ${target}"
kill -KILL "${target}" 2>/dev/null || true
sleep 1
kill -0 "${pid}" 2>/dev/null && { echo "[stop-bg][ERROR] SIGKILL 后仍存活，需人工介入"; exit 1; }
echo "[stop-bg] 已停止（KILL 生效）"
rm -f "${PIDFILE}"
