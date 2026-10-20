#!/usr/bin/env bash
# 定向验证：取消运行（POST /runs/:id/cancel）与单任务重跑（POST /runs/:id/tasks/:name/rerun）。
# 用真实 Runner 执行：长任务(sleep) 造 Running 态 -> 取消 -> 断言 Cancelled；
# 失败任务 -> 重跑 -> 断言出现新一次尝试。
# 注意：字符串里变量后跟中文一律写 ${VAR}——bash 会把多字节字符并入变量名（set -u 直接崩）。
set -u
B="${BASE:-http://localhost:8080/api/v1}"
# ---------- 认证（auth ON 环境由脚本动态换取 token，无需人工解析中间输出） ----------
# 优先级：外部 TOKEN > password grant 动态获取；KC_* 可覆盖，默认值与 hub chart realm JSON 一致
export no_proxy="${no_proxy:-*}" NO_PROXY="${NO_PROXY:-*}"
KC_ISSUER="${KC_ISSUER:-https://www.sdpworkflow.com/keycloak/realms/sdp}"
KC_CLIENT="${KC_CLIENT:-sdp-console}"
KC_USER="${KC_USER:-admin}"
KC_PASS="${KC_PASS:-sdp@12345}"
if [ -z "${TOKEN:-}" ]; then
  TOKEN=$(curl -sk -s "$KC_ISSUER/protocol/openid-connect/token" \
    -d grant_type=password -d client_id="$KC_CLIENT" \
    -d username="$KC_USER" -d password="$KC_PASS" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
  [ -n "$TOKEN" ] || { echo "错误: token 获取失败（$KC_ISSUER client=$KC_CLIENT user=$KC_USER）" >&2; exit 1; }
  echo "  [info] token 获取成功（$KC_ISSUER）" >&2
fi
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
CT='Content-Type: application/json'
C() { curl -sk --noproxy '*' ${AUTH[@]+"${AUTH[@]}"} "$@"; }
jqf() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }

PASS=0; FAIL=0
ok()   { echo "PASS $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAIL=$((FAIL+1)); }
code() { C -s -o /dev/null -w '%{http_code}' "$@"; }

TS=$(date +%s)
mk_pipeline() { # mk_pipeline <name> <taskName> <cmdJson> <argsJson> -> echoes "PIPE STAGE"
  local pname="$1" tname="$2" cmd="$3" args="$4"
  local pipe stage
  pipe=$(C -X POST "$B/pipelines" -H "$CT" \
    -d "{\"componentId\":\"$COMP\",\"name\":\"$pname\",\"kind\":\"build\"}" | jqf "d['data']['id']")
  stage=$(C -X POST "$B/pipelines/$pipe/stages" -H "$CT" \
    -d "{\"name\":\"s1\",\"sortOrder\":1}" | jqf "d['data']['id']")
  C -X POST "$B/stages/$stage/tasks" -H "$CT" \
    -d "{\"name\":\"$tname\",\"type\":\"Build\",\"image\":\"busybox\",\"command\":$cmd,\"args\":$args,\"displayOrder\":1}" >/dev/null
  echo "$pipe $stage"
}

echo "===== setup ====="
ORG=$(C -X POST "$B/orgs" -H "$CT" -d "{\"name\":\"CX$TS\",\"slug\":\"cx-$TS\"}" | jqf "d['data']['id']")
TREE=$(C "$B/orgs/$ORG/service-tree" | jqf "d['data']['id']")
SVC=$(C -X POST "$B/services" -H "$CT" \
  -d "{\"serviceTreeId\":\"$TREE\",\"key\":\"cx-svc-$TS\",\"name\":\"CX服务$TS\"}" | jqf "d['data']['id']")
COMP=$(C -X POST "$B/components" -H "$CT" \
  -d "{\"serviceId\":\"$SVC\",\"key\":\"cx-comp-$TS\",\"name\":\"CX组件$TS\",\"repoUrl\":\"https://example.com/cx.git\",\"defaultBranch\":\"main\"}" | jqf "d['data']['id']")
TGT=$(C "$B/targets?page=1&pageSize=100" | jqf "(d['data']['items'] or [{}])[0].get('id','')")
# 环境绑定 target —— run 才会派发到在线的 Runner。
C -X POST "$B/environments" -H "$CT" \
  -d "{\"componentId\":\"$COMP\",\"key\":\"cx-env-$TS\",\"name\":\"CX环境$TS\",\"envType\":\"dev\",\"targetId\":\"$TGT\",\"namespace\":\"cx-$TS\"}" >/dev/null
echo "org=$ORG tree=$TREE svc=$SVC comp=$COMP target=$TGT"

phase_of() { C "$B/runs/$1" | jqf "d['data']['phase']"; }
wait_phase() { # wait_phase <runId> <want> <secs>
  local rid="$1" want="$2" secs="$3" i=0
  while [ "$i" -lt "$secs" ]; do
    [ "$(phase_of "$rid")" = "$want" ] && return 0
    sleep 2; i=$((i+2))
  done
  return 1
}

echo "===== A) 取消运行 ====="
read -r PIPE STAGE < <(mk_pipeline "cancel-$TS" "long" '["sleep"]' '["600"]')
RUN=$(C -X POST "$B/pipelines/$PIPE/runs" -H "$CT" -d '{}' | jqf "(d['data'] or [{}])[0].get('id','')")
if [ -z "$RUN" ] || [ "$RUN" = "None" ]; then
  bad "触发运行（未拿到 runId）"
else
  ok "触发运行 run=$RUN"
  wait_phase "$RUN" "Running" 90 && ok "run 进入 Running" || bad "run 未进入 Running（phase=$(phase_of "$RUN")）"

  SC=$(code -X POST "$B/runs/$RUN/cancel")
  [ "$SC" = "200" ] && ok "POST /runs/:id/cancel -> 200" || bad "cancel 状态码=${SC}（want 200）"

  wait_phase "$RUN" "Cancelled" 90 && ok "run 相位 -> Cancelled" || bad "run 未到 Cancelled（phase=$(phase_of "$RUN")）"

  SC=$(code -X POST "$B/runs/$RUN/cancel")
  [ "$SC" = "409" ] && ok "终态重复取消 -> 409" || bad "终态取消状态码=${SC}（want 409）"

  # 取消后任务不应仍显示 Running（在途 TaskRun 被清 + 汇总标记为终态）。
  tp=$(C "$B/runs/$RUN/tasks" | jqf "((d['data'] or [{}])[0] or {}).get('phase','')")
  [ "$tp" != "Running" ] && ok "在途任务已终止（task phase=${tp}）" || bad "任务仍显示 Running"
fi

echo "===== B) 单任务重跑 ====="
read -r PIPE2 STAGE2 < <(mk_pipeline "rerun-$TS" "flaky" '["sh","-c"]' '["sleep 4; exit 1"]')
RUN2=$(C -X POST "$B/pipelines/$PIPE2/runs" -H "$CT" -d '{}' | jqf "(d['data'] or [{}])[0].get('id','')")
if [ -z "$RUN2" ] || [ "$RUN2" = "None" ]; then
  bad "触发运行（重跑用例）"
else
  ok "触发运行 run=$RUN2"
  wait_phase "$RUN2" "Failed" 120 && ok "run 失败到 Failed" || bad "run 未到 Failed（phase=$(phase_of "$RUN2")）"

  before=$(C "$B/runs/$RUN2/tasks" | jqf "((d['data'] or [{}])[0] or {}).get('completionTime','')")
  SC=$(code -X POST "$B/runs/$RUN2/tasks/flaky/rerun")
  [ "$SC" = "200" ] && ok "POST /runs/:id/tasks/:name/rerun -> 200" || bad "rerun 状态码=${SC}（want 200）"

  # 轮询：出现新一次尝试（run 离开 Failed，或任务的完成时间被清空/变化）。
  newrun=0; i=0; p=""; after="$before"
  while [ "$i" -lt 90 ]; do
    p=$(phase_of "$RUN2")
    after=$(C "$B/runs/$RUN2/tasks" | jqf "((d['data'] or [{}])[0] or {}).get('completionTime','')")
    if [ "$p" != "Failed" ] || [ -z "$after" ] || [ "$after" != "$before" ]; then newrun=1; break; fi
    sleep 2; i=$((i+2))
  done
  [ "$newrun" = "1" ] && ok "重跑后出现新一次尝试（phase=${p}，任务完成时间由 [${before}] 变为 [${after}]）" || bad "重跑后未见新尝试（phase=$(phase_of "$RUN2")）"

  SC=$(code -X POST "$B/runs/$RUN2/tasks/ghost/rerun")
  [ "$SC" != "200" ] && ok "未知任务重跑被拒（${SC}）" || bad "未知任务重跑竟然 200"
fi

echo "===== 清理 ====="
C -X DELETE "$B/orgs/$ORG" >/dev/null 2>&1

echo "RESULT: PASS=$PASS FAIL=$FAIL"
