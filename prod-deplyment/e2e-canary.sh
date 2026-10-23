#!/usr/bin/env bash
# e2e-canary.sh — 云上 canary 真流量验收（STATUS #10 / FIDELITY §5 gate ②③）。
# 前提：nginx-canary stable(v0.0.1) 已 helm 部署在 $NS；v0.0.1/v0.0.2 镜像已在镜像仓库
#       （harbor 本地 / SWR 云上，由 STABLE_IMG/CANARY_IMG 覆盖）；
#       runner online（target 自动选取 GET /targets 第一项）。
# 云端运行（镜像在 SWR，默认 harbor 地址在云上不可解析）：
#   STABLE_IMG=swr.cn-north-4.myhuaweicloud.com/<project>/nginx-canary:v0.0.1 \
#   CANARY_IMG=swr.cn-north-4.myhuaweicloud.com/<project>/nginx-canary:v0.0.2 \
#   bash e2e-canary.sh
# 流程：API 建 org/svc/comp/env(ns=$NS)/release 流水线（Release 任务带 rolloutConfig）
#       → 触发 run → 轮询 Rollout CR 步进 → currentWeight=50 暂停窗口做流量采样
#       （svc 有 NodePort 走 localhost 直采——kind 基线；无 NodePort 走集群内一次性
#        curl pod 采 ClusterIP 流量面 <workload>-sdp——云端；断言 v0.0.1/v0.0.2 都有真实流量）
#       → /releases 权重快照回流（已知开放项，informational 不计 FAIL）
#       → run 终态 Succeeded + currentWeight=100（canary 副本占满）。
set -u
BASE="${BASE:-https://www.sdpworkflow.com/api/v1}"
CURL="${CURL:-curl -sk}"
NS="${NS:-sdp-workflow}"
# Rollout/TaskRun CR 与被灰度 workload 都在 runner 的 run 命名空间（sdp-run）
ROLLOUT_NS="${ROLLOUT_NS:-sdp-run}"
WORKLOAD="${WORKLOAD:-nginx-canary}"
STABLE_IMG="${STABLE_IMG:-harbor.sdpworkflow.com/sdp/nginx-canary:v0.0.1}"
CANARY_IMG="${CANARY_IMG:-harbor.sdpworkflow.com/sdp/nginx-canary:v0.0.2}"
REPLICAS="${REPLICAS:-4}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

# ---------- 认证（与 e2e-smoke.sh 同款：脚本内动态换取 token） ----------
export no_proxy="${no_proxy:-*}" NO_PROXY="${NO_PROXY:-*}"
KC_ISSUER="${KC_ISSUER:-https://www.sdpworkflow.com/keycloak/realms/sdp}"
KC_CLIENT="${KC_CLIENT:-sdp-console}"; KC_USER="${KC_USER:-admin}"; KC_PASS="${KC_PASS:-sdp@12345}"
if [ -z "${TOKEN:-}" ]; then
  TOKEN=$(curl -sk -s "$KC_ISSUER/protocol/openid-connect/token" \
    -d grant_type=password -d client_id="$KC_CLIENT" \
    -d username="$KC_USER" -d password="$KC_PASS" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
  [ -n "$TOKEN" ] || { echo "错误: token 获取失败" >&2; exit 1; }
fi
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $*"; }
req() { # method path body -> body；2xx 打 PASS 到 stderr 的职责移交给调用方断言
  local m="$1" p="$2" b="${3:-}" out code
  if [ -n "$b" ]; then
    out=$($CURL -w "\n%{http_code}" -X "$m" "$BASE$p" -H 'Content-Type: application/json' ${AUTH[@]+"${AUTH[@]}"} -d "$b")
  else
    out=$($CURL -w "\n%{http_code}" -X "$m" "$BASE$p" ${AUTH[@]+"${AUTH[@]}"})
  fi
  code="${out##*$'\n'}"; echo "${out%$'\n'*}"
  [[ "$code" =~ ^2 ]] || echo "  [http $code] $m $p" >&2
}
jqf() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
jget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1" 2>/dev/null; }

TS=$(date +%s)
# ---------- 1. 资源准备 ----------
ORG=$(req POST "/orgs" "{\"name\":\"Canary验收$TS\",\"slug\":\"canary-$TS\"}" | jqf "d['data']['id']")
TREE=$(req GET "/orgs/$ORG/service-tree" | jqf "d['data']['id']")
SVC=$(req POST "/services" "{\"serviceTreeId\":\"$TREE\",\"key\":\"canary-svc-$TS\",\"name\":\"Canary服务\"}" | jqf "d['data']['id']")
COMP=$(req POST "/components" "{\"serviceId\":\"$SVC\",\"key\":\"canary-comp-$TS\",\"name\":\"Canary组件\",\"repoUrl\":\"https://example.com/canary.git\",\"defaultBranch\":\"main\"}" | jqf "d['data']['id']")
TGT=$(req GET "/targets?page=1&pageSize=50" | jget "[x['id'] for x in d['data']['items'] if x.get('status')=='online'][0]")
ENV=$(req POST "/environments" "{\"componentId\":\"$COMP\",\"key\":\"canary-env-$TS\",\"name\":\"Canary环境\",\"envType\":\"dev\",\"targetId\":\"$TGT\",\"namespace\":\"$NS\"}" | jqf "d['data']['id']")
[ -n "$ORG" ] && [ -n "$COMP" ] && [ -n "$TGT" ] && [ -n "$ENV" ] && ok "资源准备 org=$ORG comp=$COMP tgt=$TGT env=$ENV" || { bad "资源准备"; exit 1; }

# ---------- 2. release 流水线 + Canary 任务 ----------
PIPE=$(req POST "/pipelines" "{\"componentId\":\"$COMP\",\"name\":\"Canary流水线$TS\",\"kind\":\"release\"}" | jqf "d['data']['id']")
STAGE=$(req POST "/pipelines/$PIPE/stages" "{\"name\":\"release-stage\",\"sortOrder\":1}" | jqf "d['data']['id']")
ROLLOUT="{\"workloadRef\":\"$WORKLOAD\",\"replicas\":$REPLICAS,\"stableImage\":\"$STABLE_IMG\",\"canaryImage\":\"$CANARY_IMG\",\"steps\":[{\"setWeight\":50},{\"pause\":{\"duration\":\"30s\"}},{\"setWeight\":100}],\"healthCheck\":{\"type\":\"HTTPProbe\",\"intervalSeconds\":10,\"failureThreshold\":3,\"httpPath\":\"/\"},\"trafficRouting\":{\"type\":\"DeploymentWeight\"},\"autoRollback\":true}"
TASK=$(req POST "/stages/$STAGE/tasks" "{\"name\":\"canary-task\",\"type\":\"Release\",\"displayOrder\":1,\"rolloutConfig\":$ROLLOUT}" | jqf "d['data']['id']")
[ -n "$PIPE" ] && [ -n "$STAGE" ] && [ -n "$TASK" ] && ok "release 流水线 pipe=$PIPE stage=$STAGE task=$TASK" || { bad "流水线创建"; exit 1; }

# ---------- 3. 触发 run ----------
RUN=$(req POST "/pipelines/$PIPE/runs" "{}" | jget "d['data'][0]['id']")
[ -n "$RUN" ] && ok "run 触发 run=$RUN" || { bad "run 触发"; exit 1; }
# Rollout CR 的 task-run 标签值 = crName（短名 pr-<hex>-<task>，非 run UUID），动态取
CRNAME=""
for i in $(seq 1 10); do
  CRNAME=$(curl -sk -s "$BASE/runs/$RUN/tasks" ${AUTH[@]+"${AUTH[@]}"} | jget "d['data'][0]['crName']")
  [ -n "$CRNAME" ] && break; sleep 1
done
[ -n "$CRNAME" ] || { bad "crName 获取"; exit 1; }

# ---------- 4. Rollout 步进轮询 + 50% 窗口流量采样 ----------
SAMPLED=""; WEIGHT50=""
for i in $(seq 1 60); do
  RO=$(kubectl -n "$ROLLOUT_NS" get rollouts -l "sdp.io/task-run=$CRNAME" -o json 2>/dev/null)
  W=$(echo "$RO" | jget "d['items'][0]['status']['currentWeight'] if d.get('items') else 0")
  PH=$(echo "$RO" | jget "d['items'][0]['status']['phase'] if d.get('items') else ''")
  if [ "$W" = "50" ] && [ -z "$WEIGHT50" ]; then
    WEIGHT50=1
    # 等双版本副本都 ready 再采样：weight=50 刚落状态时 stable 还在滚动更新，
    # 立即采样会全打到 canary（endpoints 里没有 stable pod），比例失真。
    for r in $(seq 1 24); do
      SR=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      CR=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD-canary" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
      [ "${SR:-0}" -ge 2 ] 2>/dev/null && [ "${CR:-0}" -ge 2 ] 2>/dev/null && break
      sleep 5
    done
    # 流量采样双分支：NodePort（kind 基线）→ localhost 直采；
    # 无 NodePort（云端 ClusterIP 流量面）→ 集群内一次性 curl pod 采 <workload>-sdp。
    TRAFFIC_SVC="${TRAFFIC_SVC:-$WORKLOAD-sdp}"
    NPORT=$(kubectl -n "$ROLLOUT_NS" get svc "$WORKLOAD" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    V1=0; V2=0
    if [ -n "$NPORT" ]; then
      for s in $(seq 1 40); do
        case $(curl -s --max-time 3 "http://localhost:$NPORT/" | grep -o 'v0\.0\.[12]') in
          v0.0.1) V1=$((V1+1));; v0.0.2) V2=$((V2+1));;
        esac
      done
    else
      SPORT=$(kubectl -n "$ROLLOUT_NS" get svc "$TRAFFIC_SVC" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
      if [ -n "$SPORT" ]; then
        kubectl -n "$ROLLOUT_NS" delete pod canary-sample --force --grace-period=0 --ignore-not-found >/dev/null 2>&1
        kubectl -n "$ROLLOUT_NS" run canary-sample --image=curlimages/curl:8.8.0 --restart=Never --command -- sleep 600 >/dev/null 2>&1
        if kubectl -n "$ROLLOUT_NS" wait --for=condition=Ready pod/canary-sample --timeout=90s >/dev/null 2>&1; then
          OUT=$(kubectl -n "$ROLLOUT_NS" exec canary-sample -- sh -c "for i in $(seq 1 40); do curl -s --max-time 3 http://$TRAFFIC_SVC:$SPORT/; echo; done" 2>/dev/null)
          V1=$(echo "$OUT" | grep -c 'v0\.0\.1'); V2=$(echo "$OUT" | grep -c 'v0\.0\.2')
        fi
        kubectl -n "$ROLLOUT_NS" delete pod canary-sample --force --grace-period=0 --ignore-not-found >/dev/null 2>&1
      fi
    fi
    echo "  [采样@50%] stable=$SR canary=$CR nodePort=${NPORT:-none} trafficSvc=$TRAFFIC_SVC 流量 v0.0.1=$V1 v0.0.2=$V2"
    if [ -n "$SR" ] && [ -n "$CR" ] && [ "$SR" -gt 0 ] 2>/dev/null && [ "$CR" -gt 0 ] 2>/dev/null \
       && [ "$V1" -ge 10 ] 2>/dev/null && [ "$V2" -ge 10 ] 2>/dev/null; then
      SAMPLED=1; ok "50% 暂停窗口：双版本副本并存($SR/$CR)且双版本真实流量($V1/$V2)"
    fi
  fi
  RP=$(curl -sk -s "$BASE/runs/$RUN" ${AUTH[@]+"${AUTH[@]}"} | jget "d['data']['phase']")
  case "$RP" in Succeeded|Failed|Cancelled) break;; esac
  [ "$PH" = "Failed" ] && break
  sleep 5
done
[ -n "$WEIGHT50" ] && ok "Rollout 步进到达 50%" || bad "Rollout 未到达 50%"
[ -n "$SAMPLED" ] || bad "50% 窗口流量采样未通过（快照/时序问题，见上方采样行）"

# ---------- 5. 权重快照回流（已知开放项：runner→hub canary 回流未接线，informational） ----------
REL=$(req GET "/releases?pipelineRunId=$RUN")
RN=$(echo "$REL" | jget "len(d['data']['items']) if isinstance(d.get('data'),dict) else len(d.get('data',[]))")
if [ "${RN:-0}" -gt 0 ] 2>/dev/null; then
  ok "权重快照回流 /releases?pipelineRunId 条目=$RN"
else
  echo "INFO 权重快照回流缺失（已知开放项：runner→hub canary CurrentWeight 回流未接线；接线后本断言自动恢复为硬断言）"
fi

# ---------- 6. 终态断言 ----------
RUNPH=$(curl -sk -s "$BASE/runs/$RUN" ${AUTH[@]+"${AUTH[@]}"} | jget "d['data']['phase']")
FW=$(kubectl -n "$ROLLOUT_NS" get rollouts -l "sdp.io/task-run=$CRNAME" -o json 2>/dev/null | jget "d['items'][0]['status']['currentWeight'] if d.get('items') else -1")
FR=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
FC=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD-canary" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
echo "  [终态] run=$RUNPH weight=$FW stable=$FR canary=$FC"
[ "$RUNPH" = "Succeeded" ] && ok "run 终态 Succeeded" || bad "run 终态=$RUNPH"
[ "$FW" = "100" ] && ok "最终权重 100%" || bad "最终权重=$FW"
if [ "${FC:-0}" -gt "${FR:-0}" ] 2>/dev/null; then ok "canary 副本占满($FR/$FC)"; else bad "canary 未占满(stable=$FR canary=$FC)"; fi

echo "RESULT: PASS=$PASS FAIL=$FAIL  run=$RUN"
[ "$FAIL" -eq 0 ]
