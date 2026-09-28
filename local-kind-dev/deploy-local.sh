#!/bin/bash
# deploy-local.sh —— 本地一键部署三组件（临时脚本，本地联调用）。
# 完整走交付形态：镜像(localhost:5000) + chart(helm) —— 与目标环境部署路径一致。
# 流程: registry -> kind 集群 -> 镜像(缺才构建) -> postgres -> envoy-gateway -> helm hub/runner/console
# 用法: ./deploy-local.sh [version]    默认 v0.0.1（需与 build.sh 构建出的版本一致）
#       ./deploy-local.sh stop         历史兼容空操作（console 已改 ingress 访问）
# 说明:
#   - postgres 沿用 P0 manifests（charts 不含 postgres，属于外部依赖，同 old 的 mysql 定位）。
#   - console 走 ClusterIP + ingress（不再 NodePort），访问 https://localhost:8443（curl -k）。
#   - 现有 P0 的 hub/runner（裸 manifests 装的）会被删除换成 helm 管理；PVC 一并重建
#     （本地测试无制品数据，损失可忽略）。
#   - 幂等：helm upgrade --install，可重复执行。
#   - 构建日志落工作区根 .logs/build-<comp>.log（失败时打印日志尾部并中止，见步骤 4）；
#     该目录由 ./clean-local.sh 回收。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 脚本位于 software-distribution-platform-env/local-kind-dev/；工作区根（hub/runner/console 同级）在 SCRIPT_DIR 上两级（ROOT）。
# 本地测试基础设施（gateway-sdp.yaml / kind.yaml / envoy-gateway-helm tgz）与本脚本同在 local-kind-dev/deploy/，用 $SCRIPT_DIR 引用。
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION="${1:-v0.0.1}"
KUBECONFIG="$ROOT/.kubeconfig"; export KUBECONFIG
DOCKER_CONFIG="$ROOT/.dockerconfig"; export DOCKER_CONFIG
export PATH="/usr/local/bin:$PATH"
KIND="${KIND:-kind}"
command -v "$KIND" >/dev/null || KIND="$HOME/.workbuddy/binaries/bin/kind"
HUB_DIR="$ROOT/software-distribution-platform-hub"
RUNNER_DIR="$ROOT/software-distribution-platform-runner"
CONSOLE_DIR="$ROOT/software-distribution-platform-console"
TOKEN="sdp-dev-token-2026"
NS="sdp-workflow"

log() { echo "[deploy] $*"; }

# 0. stop 子命令（历史兼容：console 已改 ingress 访问，无需停 port-forward）
if [ "${1:-}" = "stop" ]; then
    echo "console 已改为 ingress 访问（https://localhost:8443），无需 stop。"
    exit 0
fi

# 1. helm（单文件二进制，缺失则下载到 workspace .bin/）
ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] && HARCH="arm64" || HARCH="amd64"
if command -v helm >/dev/null; then
    HELM="helm"
else
    HELM="$ROOT/.bin/helm"
    if [ ! -x "$HELM" ]; then
        log "downloading helm v3.14.4..."
        mkdir -p "$ROOT/.bin"
        curl -fsSL "https://get.helm.sh/helm-v3.14.4-darwin-${HARCH}.tar.gz" \
            | tar -xz -C "$ROOT/.bin" --strip-components=1 "darwin-${HARCH}/helm"
    fi
fi
log "helm ready: $("$HELM" version --short 2>/dev/null || echo 'downloaded')"

# 2. registry（跑在 kind docker 网络里，节点经 mirror 访问，主机经 127.0.0.1:5000 push）
docker network create kind 2>/dev/null || true
docker inspect kind-registry >/dev/null 2>&1 || \
    docker run -d --restart=always --name kind-registry --network kind \
        -p 127.0.0.1:5000:5000 registry:2
log "registry ready (127.0.0.1:5000)"

# 3. kind 集群（幂等）+ 清节点代理 + IP 防漂移
#    背景：apiserver 证书 SAN、kubelet.conf、etcd 监听地址都是 kubeadm 在创建时
#    写死的节点 IP，Docker Desktop 重启后若给节点容器重新分配 IP，集群即瘫痪。
#    对策双保险：
#    a) 预防 —— 集群就绪后把节点/registry 容器的当前 IP 固化为静态
#       （docker 端点记录静态 IP，守护进程重启后不会漂移）。
#    b) 自愈 —— 节点 NotReady 时先尝试把 IP 修回证书期望值（读
#       /etc/kubernetes/kubelet.conf 里的 server 地址）并重启节点内组件；
#       修不好再重建集群（本地 dev 数据可弃，helm 会全量重装）。
#    注意：新建集群 control-plane 需 ~30s 才 Ready，先宽限 90s 再判死，避免误重建。
"$KIND" get clusters 2>/dev/null | grep -qx sdp-dev || "$KIND" create cluster --config "$SCRIPT_DIR/deploy/kind.yaml"
"$KIND" export kubeconfig --name sdp-dev
NODE="sdp-dev-control-plane"

wait_node_ready() {   # $1 = 轮询次数（5s/次）
    for _ in $(seq 1 "${1:-18}"); do
        [ "$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && return 0
        sleep 5
    done
    return 1
}

pin_static_ip() {     # 把容器当前 IP 固化为静态，防 Docker 重启后漂移（幂等）
    local c="$1" ip
    ip=$(docker inspect "$c" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    [ -n "$ip" ] || return 0
    docker network disconnect kind "$c" >/dev/null 2>&1
    docker network connect --ip "$ip" kind "$c" >/dev/null 2>&1
}

repair_node_ip() {    # 尝试把节点 IP 修回证书写死的期望值
    local want now
    want=$(docker exec "$NODE" bash -c \
        "grep -oE 'https://[0-9.]+:6443' /etc/kubernetes/kubelet.conf | head -1 | sed -E 's|https://||;s|:6443||'" 2>/dev/null || true)
    [ -n "$want" ] || return 1
    now=$(docker inspect "$NODE" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    if [ "$now" = "$want" ]; then
        return 1   # IP 本来就对，问题在别处，交给重建兜底
    fi
    log "node IP drifted: $now -> expect $want, re-pinning..."
    docker network disconnect kind "$NODE" >/dev/null 2>&1
    docker network connect --ip "$want" kind "$NODE" >/dev/null 2>&1
    sleep 5
    docker exec "$NODE" bash -c "systemctl restart containerd && sleep 3 && systemctl restart kubelet" 2>/dev/null || true
    wait_node_ready 24 && { log "node repaired (IP re-pinned to $want)"; return 0; }
    return 1
}

if ! wait_node_ready 18; then
    if ! repair_node_ip; then
        log "node NotReady, recreating cluster..."
        "$KIND" delete cluster --name sdp-dev
        "$KIND" create cluster --config "$SCRIPT_DIR/deploy/kind.yaml"
        "$KIND" export kubeconfig --name sdp-dev
        wait_node_ready 18 || { log "FATAL: cluster still not ready after recreate"; exit 1; }
    fi
fi
pin_static_ip "$NODE"; pin_static_ip "kind-registry"
docker exec "$NODE" bash -c "systemctl set-environment HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY='*' no_proxy='*' && systemctl restart containerd" || true
sleep 3
log "kind cluster sdp-dev ready"

# 4. 镜像：本地有就直接推，没有才调 build.sh 构建（build.sh 自带 push）
#    构建日志落工作区根 .logs/（随 ./clean-local.sh 回收）。**失败必须可见**：只把输出重定向
#    到文件会让 set -e 静默退出、屏幕上没有任何线索（旧行为写 /tmp 且无提示）。
BUILD_LOG_DIR="$ROOT/.logs"
mkdir -p "$BUILD_LOG_DIR"
for comp in hub runner console; do
    mod_dir="$ROOT/software-distribution-platform-${comp}"
    img="localhost:5000/software-distribution-platform-${comp}:${VERSION}"
    if docker image inspect "$img" >/dev/null 2>&1; then
        docker push -q "$img" >/dev/null && log "image pushed: $img"
    else
        log "image missing, building: $comp (this may take a few minutes)"
        blog="$BUILD_LOG_DIR/build-${comp}.log"
        if ! "$mod_dir/build/${comp}/build.sh" "$VERSION" >"$blog" 2>&1; then
            log "FATAL: ${comp} 构建失败，日志尾部如下（完整日志: ${blog}）:"
            tail -n 30 "$blog" | sed 's/^/    | /' >&2
            exit 1
        fi
        log "${comp} built ok (log: $blog)"
    fi
done
# postgres 走本地 registry（节点拉不了 docker.io）
docker inspect "localhost:5000/postgres:16-alpine" >/dev/null 2>&1 || {
    docker pull -q postgres:16-alpine >/dev/null
    docker tag postgres:16-alpine "localhost:5000/postgres:16-alpine"
}
docker push -q "localhost:5000/postgres:16-alpine" >/dev/null
# Envoy Gateway 走本地 registry（控制面 + 数据面镜像，kind 节点拉不了 docker.io；
# 版本见 hub chart values frontGateway.envoyImage 注释：EG v1.6.1 ↔ Envoy distroless-v1.36.x）
for img in "docker.io/envoyproxy/gateway:v1.6.1 localhost:5000/envoyproxy/gateway:v1.6.1" \
           "docker.io/envoyproxy/envoy:distroless-v1.36.4 localhost:5000/envoyproxy/envoy:distroless-v1.36.4"; do
    src=${img%% *}; dst=${img##* }
    if ! docker image inspect "$dst" >/dev/null 2>&1; then
        docker pull -q "$src" >/dev/null || { log "WARN: pull $src failed, envoy-gateway may not work"; continue; }
        docker tag "$src" "$dst"
    fi
    docker push -q "$dst" >/dev/null
done
# keycloak 也走本地 registry（kind 节点直拉 quay.io 实测 6 分钟不完成；版本与 hub chart values 成对）
if ! docker image inspect "localhost:5000/keycloak/keycloak:26.7.4" >/dev/null 2>&1; then
    docker pull -q quay.io/keycloak/keycloak:26.7.4 >/dev/null || log "WARN: pull keycloak image failed"
    docker tag quay.io/keycloak/keycloak:26.7.4 "localhost:5000/keycloak/keycloak:26.7.4"
fi
docker push -q "localhost:5000/keycloak/keycloak:26.7.4" >/dev/null
log "images ready"

# 5. 命名空间 + postgres（外部依赖，沿用 P0 manifests）
kubectl apply -f "$HUB_DIR/deploy/manifests/00-namespace.yaml"
kubectl apply -f "$HUB_DIR/deploy/manifests/10-postgres.yaml"
kubectl -n "$NS" rollout status deploy/postgres --timeout=180s
log "postgres ready"

# 5.5. Envoy Gateway controller（平台统一入口的网关控制面；ingress-nginx 已废弃）。
#      chart tgz 在 local-kind-dev/deploy/（本地脚手架，不随仓分发），crds/ 内含 Gateway API + EG CRDs，
#      先于项目 chart 安装，hub/console chart 的 Gateway API 资源才能 apply。
#      数据面（envoy proxy pod）镜像已在 #4 预推本地 registry；具体引用见 local-kind-dev/deploy/gateway-sdp.yaml。
if ! kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
    log "installing envoy-gateway controller..."
    "$HELM" install eg "$SCRIPT_DIR/deploy/envoy-gateway-helm-v1.6.1.tgz" \
        -n envoy-gateway-system --create-namespace \
        --set config.envoyGateway.gateway.controllerName=gateway.envoyproxy.io/gatewayclass-controller
fi
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=300s
log "envoy-gateway controller ready (gatewayapi CRDs + EG CRDs installed)"

# 6. 清理 P0 裸 manifests 装的旧资源（换成 helm 管理；同名资源未被 helm 管理会冲突）
kubectl -n "$NS" delete deploy/hub deploy/runner svc/hub pvc/hub-artifacts --ignore-not-found
kubectl -n "$NS" delete sa/sdp-runner --ignore-not-found
kubectl delete clusterrole/sdp-runner clusterrolebinding/sdp-runner --ignore-not-found
log "legacy P0 resources removed"

# 6.5 TLS secret 必须先于任何网关路由就位：Gateway https listener
#     （证书 console-ingress-tls）与 keycloak HTTPRoute 都引用该 secret。
#     若 secret 尚不存在，Gateway 的 https listener 不会进入 Programmed 状态；
#     显式前置可去掉这个窗口，也让"证书是共享前置"这件事写在流程里。
#     TLS secret 的语义（与参考工程 old/go-devops 一致）：
#       - 生产：由运维**手工**创建 console-tls / console-ingress-tls，chart 只在容器内引用
#               （console values: cert.secretName / gatewayRoute.caSecretName；gateway 引用见 local-kind-dev/deploy/gateway-sdp.yaml），
#               部署流程不生成任何私钥；
#       - 本地：secret 已存在则直接复用；缺失才用统一证书生成器自签兜底
#               （源在 software-distribution-platform-env/cert-build/cert-create.sh，部署时直接运行源脚本；
#                临时测试，产物在 env/cert-build/certs），可用 SKIP_GEN_CERTS=1 强制要求已存在。
#       生成器定位：商用 CA 证书申请前的替代证书（dev/staging 占位），详见 docs/shared/CERTIFICATES.md。
ENV_DIR="$ROOT/software-distribution-platform-env"
CERT_SCRIPT_SRC="$ENV_DIR/cert-build/cert-create.sh"
if kubectl -n "$NS" get secret console-tls >/dev/null 2>&1 \
   && kubectl -n "$NS" get secret console-ingress-tls >/dev/null 2>&1; then
    log "TLS secrets present (console-tls / console-ingress-tls), reused"
elif [ -n "${SKIP_GEN_CERTS:-}" ]; then
    log "FATAL: 缺少 TLS secret 且 SKIP_GEN_CERTS=1 —— 请先手工创建 console-tls / console-ingress-tls"
    exit 1
else
    log "TLS secrets missing -> local self-signed fallback (源 cert-create.sh 直接运行；生产请手工创建)"
    if [ ! -f "$CERT_SCRIPT_SRC" ]; then
        log "FATAL: 证书生成器缺失（$CERT_SCRIPT_SRC），无法自签兜底"
        exit 1
    fi
    bash "$CERT_SCRIPT_SRC" "$NS"
fi

# 6.6 平台统一入口 Gateway（网关级资源在 local-kind-dev/deploy/gateway-sdp.yaml，不随仓分发）：
#     GatewayClass + EnvoyProxy（数据面镜像/NodePort 语义）+ Gateway（http/https listener，
#     https 引 console-ingress-tls）。三个项目 chart 的 HTTPRoute 按名字（sdp-gateway）挂接。
kubectl apply -f "$SCRIPT_DIR/deploy/gateway-sdp.yaml"
log "gateway sdp-gateway applied (class sdp-eg, http 30081 / https 30443)"

# 6.7 等 envoy 数据面 svc 就绪 + 固定 NodePort + 抓 ClusterIP —— 必须先于 hub：
#     hub 的 hostAliases 要用它把 issuer 域名解析到网关。⚠️ EG v1.6 把 proxy svc 建在
#     **envoy-gateway-system** ns（即使 EnvoyProxy CR 在 sdp-workflow），跨 ns 按标签找；
#     listener 变更会换 svc 名（hash 后缀）与 ClusterIP，故每次部署都重查。
ENVOY_SVC_NS=""
ENVOY_SVC=""
for i in 1 2 3 4 5 6; do
    ENVOY_SVC_NS=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=sdp-gateway \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
    ENVOY_SVC=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=sdp-gateway \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [ -n "$ENVOY_SVC" ] && break
    sleep 5
done
if [ -z "$ENVOY_SVC" ]; then
    log "FATAL: envoy proxy svc 未创建（Gateway 编程失败？）—— 用 egctl x status all -A 排查"
    exit 1
fi
#     NodePort 与 local-kind-dev/deploy/kind.yaml extraPortMappings 成对：http 30081 / https 30443
#     （EnvoyProxy CRD 无 nodePorts 字段，只能事后 patch；https listener 端口 = 8443，
#      与浏览器访问端口/issuer 端口三方一致）。
for idx in 0 1 2; do
    port=$(kubectl -n "$ENVOY_SVC_NS" get "svc/$ENVOY_SVC" -o jsonpath="{.spec.ports[$idx].port}" 2>/dev/null) || break
    case "$port" in
        80)   kubectl -n "$ENVOY_SVC_NS" patch "svc/$ENVOY_SVC" --type json \
                  -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/$idx/nodePort\",\"value\":30081}]" >/dev/null ;;
        8443) kubectl -n "$ENVOY_SVC_NS" patch "svc/$ENVOY_SVC" --type json \
                  -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/$idx/nodePort\",\"value\":30443}]" >/dev/null ;;
    esac
done
ENVOY_IP=$(kubectl -n "$ENVOY_SVC_NS" get "svc/$ENVOY_SVC" -o jsonpath='{.spec.clusterIP}')
log "envoy svc ready ($ENVOY_SVC_NS/$ENVOY_SVC clusterIP=$ENVOY_IP, nodePorts http->30081 https->30443)"

# 7. hub（chart 内含 Deployment/PVC/NodePort svc + keycloak 子 chart + keycloak HTTPRoute；
#    网关级资源在 #6.6 已由根脚手架 apply；console 的 HTTPRoute 在 console chart）
#
#    真对接 Keycloak（2026-09-23 起 deploy 默认开启；SKIP_AUTH=1 退回 dev 姿态）：
#    issuer 三方一致（KC_HOSTNAME / console VITE_KEYCLOAK_ISSUER_URL / hub KEYCLOAK_ISSUER）
#    钉死为公网 URL，端口 8443 与网关 https listener / 浏览器访问端口对齐。
#    hub 侧两个 dev-only 脚手架：hostAliases（= envoy svc ClusterIP，pod 内解析对外域名
#    直达网关；不能指节点 IP——pod 只能达 nodePort 30k 段，URL 的 :8443 会对不上）
#    + SSL_CERT_FILE（自签 CA）。CREDENTIAL_ENCRYPTION_KEY 用固定 dev 字面量（32 字节），
#    由 chart 持久化 —— 之前 kubectl set env 的手动注入会被 helm upgrade 抹掉（真踩过）。
ISSUER="https://www.sdpworkflow.com:8443/keycloak/realms/sdp"
AUTH_SETS=()
if [ -z "${SKIP_AUTH:-}" ]; then
    AUTH_SETS=(
        --set auth.keycloakIssuerUrl="$ISSUER"
        --set auth.adminClientSecret='**********'
        --set auth.trustedCASecret=console-tls
        --set auth.resolveHostIp="$ENVOY_IP"
        --set keycloak.hostname="https://www.sdpworkflow.com:8443/keycloak"
        --set credentialEncryptionKey='sdp-dev-credential-key-000000000'
    )
    log "auth ON: issuer=$ISSUER hostAlias=$ENVOY_IP"
fi
HUB_HELM_ARGS=(--set image.imageAddr="localhost:5000/software-distribution-platform-hub:${VERSION}")
if [ ${#AUTH_SETS[@]} -gt 0 ]; then HUB_HELM_ARGS+=("${AUTH_SETS[@]}"); fi
"$HELM" upgrade --install hub "$HUB_DIR/build/hub/charts/software-distribution-platform-hub" \
    -n "$NS" "${HUB_HELM_ARGS[@]}"
if [ -n "${SKIP_AUTH:-}" ]; then
    kubectl -n "$NS" rollout status deploy/hub --timeout=180s
else
    #    KC_HOSTNAME 变更需 KC pod 重建（keycloakx OnDelete 策略不会自动滚动）；hub 启动时
    #    要拉 discovery 且校验 issuer 严格一致 —— 必须先让 KC 按新 hostname 起来，再看 hub。
    kubectl -n "$NS" delete pod hub-keycloak-0 --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
    kubectl -n "$NS" wait --for=condition=ready pod/hub-keycloak-0 --timeout=240s \
        || log "WARN: keycloak pod not ready in 240s (hub discovery 可能失败,稍后自愈)"
    kubectl -n "$NS" rollout status deploy/hub --timeout=240s
fi
log "hub ready: http://localhost:8080/api/v1"

# 8. 注册接入目标（runner 握手前提，幂等：已存在则重复插入被忽略）
#    路径是 /targets —— 2026-09-21 的「Cluster→Target」改名把 API 从 /clusters 改成
#    /targets，但本行当时漏改，于是注册**一直静默失败**（旧的 `|| true` 连错误也吞了，
#    屏幕上没有任何线索）。现在显式回显 HTTP 码，失败必须可见。
#    真对接后 API 全部要求 Bearer token，本步改为 401 可见跳过（target 由既有库数据承载）。
REG_CODE=$(curl -s -o /tmp/sdp-register-target.json -w '%{http_code}' \
    -X POST http://localhost:8080/api/v1/targets \
    -H "Content-Type: application/json" \
    -d '{"name":"local-dev","vendor":"kind","region":"local"}' 2>/dev/null || echo "000")
case "$REG_CODE" in
    200|201) log "target registered: local-dev (HTTP $REG_CODE)" ;;
    409)     log "target local-dev already exists (HTTP 409) - ok" ;;
    401)     log "auth ON - skip auto register (HTTP 401, use console with token to manage targets)" ;;
    *)       log "WARN: register target failed (HTTP $REG_CODE): $(head -c 300 /tmp/sdp-register-target.json 2>/dev/null)" ;;
esac

# 9. runner（chart 内含 CRDs[helm crds/ 目录，install-only] + RBAC + Deployment）
"$HELM" upgrade --install runner "$RUNNER_DIR/build/runner/charts/software-distribution-platform-runner" \
    -n "$NS" --set image.imageAddr="localhost:5000/software-distribution-platform-runner:${VERSION}"
kubectl -n "$NS" rollout status deploy/runner --timeout=180s
log "runner ready, waiting for gateway handshake..."

# 10. console（纯静态镜像 + chart ConfigMap 注入 nginx 配置/证书，ClusterIP + ingress 443）
#      注：console-tls / console-ingress-tls 已在 #6.5 确保就位。
#      真对接：authDisabled=false + issuer/clientId/redirectUri 与 hub 侧同源（AUTH_SETS 同一开关）。
AUTH_SETS_CONSOLE=()
if [ -z "${SKIP_AUTH:-}" ]; then
    AUTH_SETS_CONSOLE=(
        --set auth.authDisabled=false
        --set auth.keycloakIssuerUrl="$ISSUER"
        --set auth.keycloakClientId=sdp-console
        --set auth.keycloakRedirectUri="https://www.sdpworkflow.com:8443/auth/callback"
    )
fi
CONSOLE_HELM_ARGS=(--set image.imageAddr="localhost:5000/software-distribution-platform-console:${VERSION}")
if [ ${#AUTH_SETS_CONSOLE[@]} -gt 0 ]; then CONSOLE_HELM_ARGS+=("${AUTH_SETS_CONSOLE[@]}"); fi
"$HELM" upgrade --install console "$CONSOLE_DIR/build/console/charts/software-distribution-platform-console" \
    -n "$NS" "${CONSOLE_HELM_ARGS[@]}"
#     显式重启：helm upgrade 模板未变不会重启 pod，而重跑时 ConfigMap(config.js/nginx.conf) 可能已更新、
#     hub svc 也可能被重建(ClusterIP 变更)——nginx 启动时一次性解析 upstream，不重启会拿过期 IP 导致 /api 502。
kubectl -n "$NS" rollout restart deploy/console
kubectl -n "$NS" rollout status deploy/console --timeout=180s
log "console ready"

# 11. gateway 握手验证（runner 重连退避最长 32s，轮询 45s 上限）
OK=""
for i in $(seq 1 15); do
    if kubectl -n "$NS" logs deploy/hub --tail=50 2>/dev/null | grep -qi "connected"; then OK=1; break; fi
    sleep 3
done
if [ -n "$OK" ]; then
    log "gateway handshake OK"
else
    log "WARN: handshake not seen in 45s, runner logs:"
    kubectl -n "$NS" logs deploy/runner --tail=10 || true
fi

# 12. console 访问入口：Envoy Gateway https（kind extraPortMappings 8443->30443，curl -k 直访；
#     不依赖 port-forward——沙箱/终端会话结束会杀掉 port-forward 进程，不可靠）。
#     本地自签证书：浏览器访问需 -k，或把 console/output/certs/ca.crt 加入系统信任
#     （生产用手工创建的 secret，相应改用你自己的 CA）。

log "=========================================="
log "hub:     http://localhost:8080/api/v1"
log "console: https://localhost:8443  (ingress, 自签证书用 curl -k / 浏览器信任 ca.crt)"
log "集群:    kind sdp-dev | namespace: $NS | 版本: $VERSION"
log "=========================================="
