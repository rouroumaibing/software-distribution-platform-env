#!/bin/bash
# run-bg.sh — 后台进程统一启动入口：setsid 脱离 + 日志 + pidfile。
#
# 背景：`nohup ... &` 裸启动没有 pid 记录，后续只能 `pkill -f <模式>` 停止——
# 而模式会命中执行 pkill 的会话自身 cmdline（实测多次把执行会话一起杀掉）。
# 本脚本把「脱离 + 日志 + pid 记录」固化，配套 stop-bg.sh 按 pidfile 停止，
# 全程不使用 cmdline 模式匹配。
#
# 用法：
#   ./run-bg.sh <日志文件> <命令> [参数...]
# 例：
#   ./run-bg.sh /var/sdp/e2e-smoke-run.log bash /var/sdp/e2e-smoke.sh
# 产物：
#   <日志文件>.pid  — 主进程 pid（stop-bg.sh 按它停止）
#
# 注意：同名日志重复启动会覆盖 pidfile（旧进程不受影响，需先 stop-bg.sh 再启动）。

set -euo pipefail

usage() {
    cat <<USAGE
用法: ./run-bg.sh <日志文件> <命令> [参数...]

说明:
  - 以 setsid 新会话启动命令（脱离终端与父会话）
  - stdout/stderr 追加重定向到 <日志文件>，stdin 接 /dev/null
  - 主进程 pid 写入 <日志文件>.pid，供 stop-bg.sh 停止使用
USAGE
}

[[ $# -ge 2 ]] || { echo "错误: 需要 <日志文件> 和 <命令>"; usage; exit 1; }
LOGFILE="$1"; shift
LOGDIR="$(dirname "${LOGFILE}")"
[[ -d "${LOGDIR}" ]] || { echo "错误: 日志目录不存在: ${LOGDIR}"; exit 1; }
command -v "$1" >/dev/null 2>&1 || echo "[run-bg][WARN] 命令不在 PATH: $1（脚本路径类命令属正常）"

PIDFILE="${LOGFILE}.pid"
if [[ -f "${PIDFILE}" ]] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    echo "错误: 疑似已有实例在运行（pid=$(cat "${PIDFILE}")，pidfile=${PIDFILE}）；先 ./stop-bg.sh ${PIDFILE}"
    exit 1
fi

setsid nohup "$@" >> "${LOGFILE}" 2>&1 < /dev/null &
pid=$!
echo "${pid}" > "${PIDFILE}"
echo "[run-bg] pid=${pid} log=${LOGFILE} pidfile=${PIDFILE}"
