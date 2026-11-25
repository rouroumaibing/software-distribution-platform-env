#!/bin/bash
# e2e-example-release.sh — example 软件经 SDP API 发布验收（构建产物已在 SWR）。
# 复用 e2e-canary.sh 已验证的 API 编排（认证 / org-svc-comp-env / pipeline-stage-task / runs /
# Rollout CR 在 sdp-run），差异：单 stable 镜像直发（setWeight 100），无 canary 步进。
#
# 镜像来源：
#   - 默认 IMG=nginx-canary:v0.0.1（SWR 已有，example 同仓 canary 变体，可拉取）；
#   - 若已把 example 平铺版 nginx 推上 SWR，可用 IMG=.../nginx:v0.0.1 覆盖。
# 用法：
#   bash e2e-example-release.sh
set -u
BASE="${BASE:-https://www.sdpworkflow.com/api/v1}"
CURL="${CURL:-curl -sk}"
NS="${NS:-sdp-workflow}"
REPLICAS="${REPLICAS:-4}"   # rollout 副本基线（复位段/rolloutConfig/终态断言单一来源）
ROLLOUT_NS="${ROLLOUT_NS:-sdp-run}"
STABLE_IMG="${STABLE_IMG:-swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx-canary:v0.0.1}"
CANARY_IMG="${CANARY_IMG:-swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx-canary:v0.0.2}"
WORKLOAD="${WORKLOAD:-example-nginx}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

# ---------- 0. 环境复位：清理上一轮 gate 遗留的 rollout 并复位基线（同 e2e-canary.sh） ----------
# 遗留 rollout 的 controller 会与新 rollout 互踩副本数，导致步进/终态抖动。
for PAIR in $(kubectl -n "$ROLLOUT_NS" get rollouts -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.workloadRef} {end}' 2>/dev/null); do
  RONAME="${PAIR%%:*}"; ROWL="${PAIR##*:}"
  if [ "$ROWL" = "$WORKLOAD" ]; then
    kubectl -n "$ROLLOUT_NS" delete rollout "$RONAME" --ignore-not-found >/dev/null 2>&1
    echo "  [复位] 清理遗留 rollout ${RONAME}（workload=${WORKLOAD}）"
  fi
done
if kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD" >/dev/null 2>&1; then
  kubectl -n "$ROLLOUT_NS" scale deploy "$WORKLOAD" --replicas="$REPLICAS" >/dev/null 2>&1
  kubectl -n "$ROLLOUT_NS" scale deploy "$WORKLOAD-canary" --replicas=0 >/dev/null 2>&1
  for i in $(seq 1 18); do
    R=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [ "${R:-0}" -ge 2 ] 2>/dev/null && break
    sleep 5
  done
  echo "  [复位] stable 基线副本就绪=${R:-0}/$REPLICAS"
fi

# ---------- 认证与断言骨架（单一真源 e2e-common.sh） ----------
. "$(dirname "${BASH_SOURCE[0]}")/e2e-common.sh"

TS=$(date +%s)
# ---------- 1. 资源准备 ----------
ORG=$(req POST "/orgs" "{\"name\":\"Example发布$TS\",\"slug\":\"ex-rel-$TS\"}" | jqf "d['data']['id']")
TREE=$(req GET "/orgs/$ORG/service-tree" | jqf "d['data']['id']")
SVC=$(req POST "/services" "{\"serviceTreeId\":\"$TREE\",\"key\":\"ex-svc-$TS\",\"name\":\"Example服务\"}" | jqf "d['data']['id']")
COMP=$(req POST "/components" "{\"serviceId\":\"$SVC\",\"key\":\"ex-comp-$TS\",\"name\":\"Example组件\",\"repoUrl\":\"https://example.com/nginx.git\",\"defaultBranch\":\"main\"}" | jqf "d['data']['id']")
TGT=$(req GET "/targets?page=1&pageSize=50" | jget "[x['id'] for x in d['data']['items'] if x.get('status')=='online'][0]")
ENV=$(req POST "/environments" "{\"componentId\":\"$COMP\",\"key\":\"ex-env-$TS\",\"name\":\"Example环境\",\"envType\":\"dev\",\"targetId\":\"$TGT\",\"namespace\":\"$NS\"}" | jqf "d['data']['id']")
[ -n "$ORG" ] && [ -n "$COMP" ] && [ -n "$TGT" ] && [ -n "$ENV" ] && ok "资源准备 org=$ORG comp=$COMP tgt=$TGT env=$ENV" || { bad "资源准备"; exit 1; }

# ---------- 2. release 流水线 + Release 任务（单 stable 直发） ----------
PIPE=$(req POST "/pipelines" "{\"componentId\":\"$COMP\",\"name\":\"Example发布流水线$TS\",\"kind\":\"release\"}" | jqf "d['data']['id']")
STAGE=$(req POST "/pipelines/$PIPE/stages" "{\"name\":\"rel-stage\",\"sortOrder\":1}" | jqf "d['data']['id']")
ROLLOUT="{\"workloadRef\":\"$WORKLOAD\",\"replicas\":$REPLICAS,\"stableImage\":\"$STABLE_IMG\",\"canaryImage\":\"$CANARY_IMG\",\"steps\":[{\"setWeight\":50},{\"pause\":{\"duration\":\"30s\"}},{\"setWeight\":100}],\"healthCheck\":{\"type\":\"HTTPProbe\",\"intervalSeconds\":10,\"failureThreshold\":3,\"httpPath\":\"/\"},\"trafficRouting\":{\"type\":\"DeploymentWeight\"},\"autoRollback\":true}"
TASK=$(req POST "/stages/$STAGE/tasks" "{\"name\":\"rel-task\",\"type\":\"Release\",\"displayOrder\":1,\"rolloutConfig\":$ROLLOUT}" | jqf "d['data']['id']")
[ -n "$PIPE" ] && [ -n "$STAGE" ] && [ -n "$TASK" ] && ok "release 流水线 pipe=$PIPE stage=$STAGE task=$TASK" || { bad "流水线创建"; exit 1; }

# ---------- 3. 触发 run ----------
RUN=$(req POST "/pipelines/$PIPE/runs" "{}" | jget "d['data'][0]['id']")
[ -n "$RUN" ] && ok "run 触发 run=$RUN" || { bad "run 触发"; exit 1; }
CRNAME=""
for i in $(seq 1 10); do
  CRNAME=$(curl -sk -s "$BASE/runs/$RUN/tasks" ${AUTH[@]+"${AUTH[@]}"} | jget "d['data'][0]['crName']")
  [ -n "$CRNAME" ] && break; sleep 1
done
[ -n "$CRNAME" ] || { bad "crName 获取"; exit 1; }
echo "  [crName] $CRNAME"

# ---------- 4. Rollout 步进轮询 ----------
for i in $(seq 1 60); do
  RP=$(curl -sk -s "$BASE/runs/$RUN" ${AUTH[@]+"${AUTH[@]}"} | jget "d['data']['phase']")
  case "$RP" in Succeeded|Failed|Cancelled) break;; esac
  sleep 5
done

# ---------- 5. 终态断言 ----------
RUNPH=$(curl -sk -s "$BASE/runs/$RUN" ${AUTH[@]+"${AUTH[@]}"} | jget "d['data']['phase']")
FW=$(kubectl -n "$ROLLOUT_NS" get rollouts -l "sdp.io/task-run=$CRNAME" -o json 2>/dev/null | jget "d['items'][0]['status']['currentWeight'] if d.get('items') else -1")
RD=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
RC=$(kubectl -n "$ROLLOUT_NS" get deploy "$WORKLOAD-canary" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
echo "  [终态] run=$RUNPH weight=$FW stableReady=$RD canaryReady=$RC"
[ "$RUNPH" = "Succeeded" ] && ok "run 终态 Succeeded" || bad "run 终态=$RUNPH"
[ "$FW" = "100" ] && ok "最终权重 100%" || bad "最终权重=$FW"
# weight=100 终态语义（与 rollout controller 一致）：canary 副本占满，stable 收缩归零
if [ "${RC:-0}" -eq "$REPLICAS" ] 2>/dev/null; then ok "canary $WORKLOAD-canary 副本占满($RC/$REPLICAS)"; else bad "canary 副本=${RC:-0}，期望占满 $REPLICAS"; fi
if [ "${RD:-0}" = "0" ] 2>/dev/null; then ok "stable $WORKLOAD 已收缩归零（weight=100 语义）"; else bad "stable 未归零（ready=${RD:-0}）"; fi

echo "RESULT: PASS=$PASS FAIL=$FAIL  run=$RUN"
[ "$FAIL" -eq 0 ]
