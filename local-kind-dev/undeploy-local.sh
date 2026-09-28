#!/bin/bash
# undeploy-local.sh —— 本地全量部署卸载（与 deploy-local.sh 配对）
# 卸载 helm releases (hub/runner/console) 并删除命名空间；保留 kind 集群与 registry 容器。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本已迁至 software-distribution-platform-env/local-kind-dev/；工作区根（含 hub/runner/console/env/deploy 同级）在 SCRIPT_DIR 上两级。
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBECONFIG="$ROOT/.kubeconfig"; export KUBECONFIG
NS="sdp-workflow"
HELM="${HELM:-helm}"; command -v "$HELM" >/dev/null 2>&1 || HELM="$ROOT/.bin/helm"

log() { echo "[undeploy] $*"; }

if [ ! -f "$KUBECONFIG" ]; then
  log "未找到 ${KUBECONFIG}（可能从未部署），跳过 helm 卸载。"
  exit 0
fi

log "卸载 helm releases: hub / runner / console (ns $NS)"
"$HELM" uninstall hub runner console -n "$NS" 2>/dev/null || true
kubectl delete ns "$NS" 2>/dev/null || true
log "已卸载。"
log "kind 集群 'sdp-dev' 保留（删除：kind delete cluster --name sdp-dev）。"
log "registry 容器 'kind-registry' 与 docker 网络 'kind' 保留（如需清理：docker rm -f kind-registry; docker network rm kind）。"
