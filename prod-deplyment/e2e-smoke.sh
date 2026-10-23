#!/usr/bin/env bash
# e2e-smoke.sh — 按页面真实操作顺序冒烟测试全部前端 API（经 console ingress = 浏览器同路径）。
# console 走 ClusterIP + ingress（kind 8443->443），自签证书用 curl -k。
set -u
# BASE 解析优先级：显式 BASE > 云端网关探测（www.sdpworkflow.com 可达即采用）> kind 本地默认。
# 启动预检探活 $BASE/targets，探不通 fail-fast 并打印两种环境用法——防止 15 项全 FAIL 的静默假跑。
BASE_CLOUD="https://www.sdpworkflow.com/api/v1"
BASE_KIND="https://localhost:8443/api/v1"
if [[ -z "${BASE:-}" ]]; then
    if curl -sk -o /dev/null --max-time 3 "${BASE_CLOUD}/targets"; then
        BASE="${BASE_CLOUD}"
    else
        BASE="${BASE_KIND}"
    fi
fi
if ! curl -sk -o /dev/null --max-time 5 "${BASE}/targets"; then
    echo "错误: BASE=${BASE} 不可达。云端: BASE=${BASE_CLOUD}；kind 本地: BASE=${BASE_KIND}（或 BASE=http://localhost:8080/api/v1 直连 hub）" >&2
    exit 1
fi
CURL="${CURL:-curl -sk}"
PASS=0; FAIL=0
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
req() { # method path body
  local m="$1" p="$2" b="${3:-}"
  local out code
  if [ -n "$b" ]; then
    out=$($CURL -w "\n%{http_code}" -X "$m" "$BASE$p" -H 'Content-Type: application/json' ${AUTH[@]+"${AUTH[@]}"} -d "$b")
  else
    out=$($CURL -w "\n%{http_code}" -X "$m" "$BASE$p" ${AUTH[@]+"${AUTH[@]}"})
  fi
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  if [[ "$code" =~ ^2 ]]; then PASS=$((PASS+1)); echo "PASS $code $m $p" >&2
  else FAIL=$((FAIL+1)); echo "FAIL $code $m $p  << ${body:0:200}" >&2; fi
  echo "$body"
}
jqf() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

TS=$(date +%s)
echo "===== 1) 组织 / 服务树 ====="
R=$(req POST "/orgs" "{\"name\":\"E2E冒烟$TS\",\"slug\":\"e2e-smoke-$TS\"}")
ORG=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/orgs?page=1&pageSize=100");            echo "$R" | jqf "len(d['data']['items'])" >/dev/null
R=$(req GET  "/orgs/$ORG")
R=$(req GET  "/orgs/$ORG/service-tree")
TREE=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/service-trees/$TREE/services?page=1&pageSize=100")

echo "===== 2) 服务 / 组件 ====="
R=$(req POST "/services" "{\"serviceTreeId\":\"$TREE\",\"key\":\"e2e-svc\",\"name\":\"E2E服务\"}")
SVC=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/services/$SVC")
R=$(req GET  "/services/$SVC/components?page=1&pageSize=100")
R=$(req POST "/components" "{\"serviceId\":\"$SVC\",\"key\":\"e2e-comp\",\"name\":\"E2E组件\",\"repoUrl\":\"https://example.com/e2e.git\",\"defaultBranch\":\"main\"}")
COMP=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/components/$COMP")

echo "===== 3) 环境 ====="
R=$(req GET  "/targets?page=1&pageSize=100")
TGT=$(echo "$R" | jqf "(d['data']['items'] or [{}])[0].get('id','')")
R=$(req GET  "/components/$COMP/environments?page=1&pageSize=100")
R=$(req POST "/environments" "{\"componentId\":\"$COMP\",\"key\":\"e2e-env\",\"name\":\"E2E环境\",\"envType\":\"dev\",\"targetId\":\"$TGT\",\"namespace\":\"e2e\"}")

echo "===== 4) 流水线 / 阶段 / 任务 ====="
R=$(req GET  "/components/$COMP/pipelines?page=1&pageSize=100")
R=$(req POST "/pipelines" "{\"componentId\":\"$COMP\",\"name\":\"E2E流水线$TS\",\"kind\":\"build\"}")
PIPE=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/pipelines/$PIPE")
R=$(req POST "/pipelines/$PIPE/stages" "{\"name\":\"build-stage\",\"sortOrder\":1}")
STAGE=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/pipelines/$PIPE/stages")
R=$(req POST "/stages/$STAGE/tasks" "{\"name\":\"echo-task\",\"type\":\"Build\",\"image\":\"busybox\",\"command\":[\"echo\"],\"args\":[\"e2e\"],\"displayOrder\":1}")
TASK=$(echo "$R" | jqf "d['data']['id']")
R=$(req GET  "/stages/$STAGE/tasks")
R=$(req PUT  "/tasks/$TASK" "{\"name\":\"echo-task\",\"type\":\"Build\",\"image\":\"busybox\",\"command\":[\"echo\"],\"args\":[\"e2e-v2\"],\"displayOrder\":1}")

echo "===== 5) 运行 ====="
R=$(req POST "/pipelines/$PIPE/runs" "{}")
# Trigger 返回的是 run 列表（common.Created(c, runs)）→ data 是数组，取 [0].id。
RUN=$(echo "$R" | jqf "(d['data'] or [{}])[0].get('id','')")
if [ -n "$RUN" ] && [ "$RUN" != "None" ]; then
  req GET "/runs/$RUN"
  req GET "/runs/$RUN/tasks"
  # 轮询 run 到终态（phase：Pending/Running/Succeeded/Failed/Cancelled）——
  # 这是验证 runner 真的把 run 派发并执行完成的关键。用原始 curl 避免污染 PASS 计数。
  echo "  ... 轮询 run 终态（验证 runner 执行）" >&2
  ST=""
  for _i in $(seq 1 24); do
    ST=$($CURL -s "$BASE/runs/$RUN" | jqf "d['data']['phase']")
    case "$ST" in
      Succeeded|Failed|Cancelled) break ;;
      *) sleep 5 ;;
    esac
  done
  echo "  [info] run final phase=$ST" >&2
fi

echo "===== 5.5) 发布 (releases, P0-1) ====="
req GET "/releases"
# 创建 Release 需要真实的 TaskRun（FK → task_runs）；从刚触发的运行里取，取不到则跳过创建/详情（路由仍已验证）。
if [ -n "${RUN:-}" ] && [ "$RUN" != "None" ]; then
  TRID=$(req GET "/runs/$RUN/tasks" | jqf "(d.get('data',{}).get('items',[]) or [{}])[0].get('id','')")
  if [ -n "${TRID:-}" ] && [ "$TRID" != "None" ]; then
    R=$(req POST "/releases" "{\"taskRunId\":\"$TRID\",\"workloadRef\":\"e2e-workload\",\"phase\":\"Progressing\"}")
    REL=$(echo "$R" | jqf "d['data']['id']")
    [ -n "$REL" ] && [ "$REL" != "None" ] && {
      req GET "/releases/$REL"
      req PUT "/releases/$REL" "{\"phase\":\"Succeeded\"}"
      req DELETE "/releases/$REL"
    }
  fi
fi

echo "===== 5.6) 全局流水线列表 (P0-2) ====="
req GET "/pipelines?page=1&pageSize=100"
req GET "/pipelines?componentId=$COMP"
req GET "/pipelines?kind=build"
req GET "/pipelines?name=E2E流水线"

echo "===== 6) 权限 ====="
# hub 不提供 /users（用户主体来自 Keycloak，hub 不建用户表）——信息性探针，不计 PASS/FAIL。
echo "  [info] GET /users -> $($CURL -o /dev/null -w '%{http_code}' "$BASE/users?page=1&pageSize=100")（预期 404）" >&2
req GET "/roles"
req GET "/components/$COMP/role-bindings"

echo "===== 7) 清理（非计数：删父资源的结果取决于 run 是否终态，属环境性） ====="
[ -n "${TASK:-}" ] && req DELETE "/tasks/$TASK" >/dev/null 2>&1
[ -n "${PIPE:-}" ] && req DELETE "/pipelines/$PIPE" >/dev/null 2>&1
ENV_ID=$(req GET "/components/$COMP/environments?page=1&pageSize=100" | jqf "d['data']['items'][0]['id']")
[ -n "${ENV_ID:-}" ] && [ "$ENV_ID" != "None" ] && req DELETE "/environments/$ENV_ID" >/dev/null 2>&1
[ -n "${COMP:-}" ] && req DELETE "/components/$COMP" >/dev/null 2>&1
[ -n "${SVC:-}" ] && req DELETE "/services/$SVC" >/dev/null 2>&1
[ -n "${ORG:-}" ] && req DELETE "/orgs/$ORG" >/dev/null 2>&1

echo "=============================="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
