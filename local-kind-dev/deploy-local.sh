#!/bin/bash
# deploy-local.sh —— 本地一键部署（local-kind-dev 脚手架）。
#
# 任务逻辑（与 kind 生产形态对齐：先周边服务，后组件）：
#   1) 本地 registry（localhost:5000）—— 仅作 harbor 自身镜像 + envoy 数据面镜像的 bootstrap 中转；
#      任何平台 pod 都不从它拉镜像（平台镜像统一走 harbor）。
#   2) kind 集群（sdp-dev）。
#   3) 周边服务先行：先装 harbor（集群内镜像仓库，经 Envoy 网关暴露为 https://harbor.sdpworkflow.com 标准 443），
#      再装 envoy-gateway 控制面 + 平台网关 sdp-gateway。
#   4) 构建三组件镜像（build.sh 只负责构建镜像 + docker save），推送统一由本脚本经集群节点 containerd 推到 harbor（见 #4 段 node_push_to_harbor 循环）。
#   5) postgres / keycloak / hub / runner / console 全部从 harbor 拉镜像部署。
#
# 端口约定：所有「域名访问」走标准 443（https://harbor.sdpworkflow.com、https://www.sdpworkflow.com:8443）。
#   网关数据面均为 ClusterIP（不写死端口）；宿主访问统一由本脚本起 kubectl port-forward 暴露，
#   端口号不进任何域名/镜像引用：
#   - sdp-gateway：port-forward 本地 8443 -> svc 8443（https listener 8443，与 issuer/浏览器端口三方一致，
#     2026-09-23 裁定）、8082 -> svc 80（http）；curl 用 --resolve www.sdpworkflow.com:8443:127.0.0.1。
#   - harbor-gateway：sudo port-forward 宿主 443 -> svc 443（仅供宿主 docker push / 浏览器）；
#     节点拉镜像不经此转发——节点在集群内经 CoreDNS 把 harbor.sdpworkflow.com 解析到 harbor 网关 ClusterIP
#     直达 harbor（与生产「节点经 Gateway 域名拉镜像」一致），不写任何 IP、不依赖宿主进程。
#
# 阶段化（2026-10-09）：五段边界 = 部署依赖的自然切面；每段幂等可重入，
#   跨段状态（ENVOY_IP 等）经 $STATE_FILE 传递；单段模式面向断点续跑（某段超时/失败，
#   修复后单独重跑该段即可，无需从头全量）。默认（无 --stage）= 全量部署，行为与阶段化之前一致。
#
# 用法: ./deploy-local.sh [version] [--stage infra|harbor|images|platform|components]
#       ./deploy-local.sh --help     阶段说明
#       ./deploy-local.sh stop       历史兼容空操作
# 前置约束见同目录 README.md（宿主机 /etc/hosts、docker insecure-registries、kind 重建等）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KUBECONFIG="$ROOT/.kubeconfig"; export KUBECONFIG
DOCKER_CONFIG="$ROOT/.dockerconfig"; export DOCKER_CONFIG
export PATH="/usr/local/bin:$PATH"
KIND="${KIND:-kind}"
command -v "$KIND" >/dev/null || KIND="$HOME/.workbuddy/binaries/bin/kind"
HUB_DIR="$ROOT/software-distribution-platform-hub"
RUNNER_DIR="$ROOT/software-distribution-platform-runner"
CONSOLE_DIR="$ROOT/software-distribution-platform-console"
ENV_DIR="$ROOT/software-distribution-platform-env"
HARBOR_DIR="$ENV_DIR/harbor"
NS="sdp-workflow"

# 域名（基础域名单一真源；均可被环境变量覆盖，默认 sdpworkflow.com）
#   SDP_BASE_DOMAIN 派生 harbor.<base> 与 www.<base> 两个子域名；
#   证书 SAN=*.<base> 由 cert-build 据 DOMAINNAME 生成，须与二者保持一致。
SDP_BASE_DOMAIN="${SDP_BASE_DOMAIN:-sdpworkflow.com}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.${SDP_BASE_DOMAIN}}"
SDP_GATEWAY_DOMAIN="${SDP_GATEWAY_DOMAIN:-www.${SDP_BASE_DOMAIN}}"
HARBOR_PROJECT="${HARBOR_PROJECT:-sdp}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Admin@123}"

TOKEN="sdp-dev-token-2026"
log() { echo "[deploy] $*"; }

# ---------- 参数解析（version + --stage；stop 为历史兼容空操作） ----------
usage() {
    cat <<'USAGE'
deploy-local.sh —— 本地一键部署（local-kind-dev 脚手架）

用法:
  ./deploy-local.sh [version]                    全量部署（默认 version=v0.0.1，行为与阶段化前一致）
  ./deploy-local.sh [version] --stage <name>     单跑一段（幂等可重入；段间状态经 .deploy-state.env 传递）
  ./deploy-local.sh --help                       本说明
  ./deploy-local.sh stop                         历史兼容空操作（停转发请运行 stop-dev.sh kill）

阶段（依赖顺序，每段开头自动补齐幂等轻量前置）:
  infra        helm / registry(localhost:5000) / kind 集群 / 宿主 hosts / 自签证书 / bootstrap 镜像预推
  harbor       envoy-gateway 控制面 + harbor 安装/网关/CoreDNS rewrite/project + postgres/keycloak 镜像入 harbor
  images       三组件构建（build.sh）+ 经节点 containerd 推 harbor
  platform     命名空间/postgres/清理 P0/TLS secrets/sdp-ca/sdp-gateway（产出 ENVOY_IP 落 state）
  components   hub/runner/console 部署 + target 注册 + 握手验证（需要 state 里的 ENVOY_IP）

说明:
  - 单段模式面向断点续跑：harbor 段内含 harbor pods ready 等待（最长 600s），
    沙箱/CI 有执行时限的环境里超时后直接重跑同一段即可续上。
  - 跨段状态写入 local-kind-dev/.deploy-state.env（不入库）；缺失时脚本报错并指向应先跑的段。
USAGE
}

VERSION="v0.0.1"
STAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        stop)
            echo "网关经 kubectl port-forward 暴露（sdp 8443 + harbor sudo 443），停止转发请运行: ./stop-dev.sh kill"
            exit 0
            ;;
        --stage)
            [ -n "${2:-}" ] || { echo "ERROR: --stage 需要参数"; usage; exit 1; }
            STAGE="$2"; shift 2
            ;;
        --stage=*)
            STAGE="${1#--stage=}"; shift
            ;;
        -h|--help)
            usage; exit 0
            ;;
        *)
            VERSION="$1"; shift
            ;;
    esac
done

case "$STAGE" in
    ""|infra|harbor|images|platform|components) ;;
    *) echo "ERROR: 未知阶段 '$STAGE'"; usage; exit 1 ;;
esac

# ---------- 工具函数 ----------
# 确保 helm（单文件二进制，缺失则下载到 workspace .bin/）
ensure_helm() {
    ARCH="$(uname -m)"; [ "$ARCH" = "arm64" ] && HARCH="arm64" || HARCH="amd64"
    if command -v helm >/dev/null; then HELM="helm"
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
}

# 确保本地已有某镜像：存在则跳过，不存在才拉取（避免盲目重拉 / 网络失败时尽早暴露）
ensure_image() {
    local img="$1"
    if docker image inspect "$img" >/dev/null 2>&1; then
        log "image exists, skip pull: $img"
    else
        log "pulling $img ..."
        docker pull -q "$img" >/dev/null || { log "WARN: pull $img failed"; return 1; }
    fi
}

# 本地 registry（跑在 kind docker 网络里，仅作 harbor/envoy bootstrap 中转；节点经 mirror 访问）
ensure_registry() {
    docker network create kind 2>/dev/null || true
    ensure_image "registry:2" || log "WARN: 未能预拉 registry:2，docker run 将尝试自行拉取"
    docker inspect kind-registry >/dev/null 2>&1 || \
        docker run -d --restart=always --name kind-registry --network kind \
            -p 127.0.0.1:5000:5000 registry:2
    log "registry ready (127.0.0.1:5000, bootstrap-only)"
}

# kind 集群（幂等）+ 清节点代理 + IP 防漂移
NODE="sdp-dev-control-plane"
wait_node_ready() {   # $1 = 轮询次数（5s/次）
    for _ in $(seq 1 "${1:-18}"); do
        [ "$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] && return 0
        sleep 5
    done
    return 1
}
pin_static_ip() {
    local c="$1" ip
    ip=$(docker inspect "$c" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    [ -n "$ip" ] || return 0
    docker network disconnect kind "$c" >/dev/null 2>&1
    docker network connect --ip "$ip" kind "$c" >/dev/null 2>&1
}
repair_node_ip() {
    local want now
    want=$(docker exec "$NODE" bash -c \
        "grep -oE 'https://[0-9.]+:6443' /etc/kubernetes/kubelet.conf | head -1 | sed -E 's|https://||;s|:6443||'" 2>/dev/null || true)
    [ -n "$want" ] || return 1
    now=$(docker inspect "$NODE" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    if [ "$now" = "$want" ]; then return 1; fi
    log "node IP drifted: $now -> expect $want, re-pinning..."
    docker network disconnect kind "$NODE" >/dev/null 2>&1
    docker network connect --ip "$want" kind "$NODE" >/dev/null 2>&1
    sleep 5
    docker exec "$NODE" bash -c "systemctl restart containerd && sleep 3 && systemctl restart kubelet" 2>/dev/null || true
    wait_node_ready 24 && { log "node repaired (IP re-pinned to $want)"; return 0; }
    return 1
}
ensure_kind() {
    "$KIND" get clusters 2>/dev/null | grep -qx sdp-dev || "$KIND" create cluster --config "$SCRIPT_DIR/deploy/kind.yaml"
    "$KIND" export kubeconfig --name sdp-dev
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
    # 节点侧：清代理 + 重启 containerd，使 harbor mirror + /etc/hosts 生效
    docker exec "$NODE" bash -c "systemctl set-environment HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy= NO_PROXY='*' no_proxy='*' && systemctl restart containerd" || true
    sleep 3
    log "kind cluster sdp-dev ready"
}

# 节点经集群 DNS（CoreDNS）把 ${HARBOR_REGISTRY} 解析到 harbor 网关 ClusterIP，
# 与生产「节点经 Gateway 域名拉镜像」完全一致：不写任何 IP、不依赖宿主进程。
# 实现（须在 harbor 网关 EnvoyProxy/数据面 svc 已存在、可取其集群 DNS 名之后调用）：
#   ① patch kube-system/coredns，注入 rewrite name ${HARBOR_REGISTRY} -> 网关 svc 集群 DNS 名并重启 coredns；
#   ② 节点 /etc/resolv.conf 前置 CoreDNS（kube-dns 默认 10.96.0.10）；
#   ③ 节点 /etc/hosts 清除任何 harbor 行（避免陈旧 IP 覆盖 DNS）；④ 重启 containerd 生效。
patch_coredns_rewrite() {
    local dns="$1" cm newcm
    cm=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null)
    [ -n "$cm" ] || { log "WARN: 读取 coredns Corefile 失败，跳过 rewrite 注入"; return 1; }
    if echo "$cm" | grep -q "rewrite name ${HARBOR_REGISTRY} $dns"; then
        log "coredns rewrite 已存在 ($dns)"
        return 0
    fi
    # 在 '    ready' 行后插入 rewrite（4 空格缩进，与 Corefile 一致）；通过 stdin 注入新 Corefile。
    newcm=$(printf '%s\n' "$cm" | awk -v dns="$dns" '{print} /^    ready$/ {print "    rewrite name ${HARBOR_REGISTRY} " dns}')
    printf '%s\n' "$newcm" \
        | kubectl -n kube-system create cm coredns --from-file=Corefile=/dev/stdin --dry-run=client -o yaml 2>/dev/null \
        | kubectl apply -f - 2>/dev/null \
        || { log "WARN: 注入 coredns rewrite 失败（节点可能无法经 DNS 解析 harbor，将影响镜像拉取）"; return 1; }
    kubectl -n kube-system rollout restart deployment/coredns 2>/dev/null
    kubectl -n kube-system rollout status deployment/coredns --timeout=120s 2>/dev/null || true
    log "coredns rewrite 注入 -> $dns，coredns 已重启"
}
ensure_node_dns_harbor() {
    local dns="$1"
    [ -n "$dns" ] || { log "WARN: ensure_node_dns_harbor 未收到网关 svc 集群 DNS 名，跳过节点 DNS 更新"; return 1; }
    patch_coredns_rewrite "$dns"
    # ② 节点 /etc/resolv.conf 前置 CoreDNS（已前置则跳过，避免重复）
    docker exec "$NODE" bash -c "grep -q '^nameserver 10.96.0.10' /etc/resolv.conf || sed -i '1i nameserver 10.96.0.10' /etc/resolv.conf" 2>/dev/null || true
    # ③ 节点 /etc/hosts 清除 harbor 行（grep -v 写临时文件再覆盖，规避 overlay rename 限制）
    docker exec "$NODE" sh -c "grep -v '${HARBOR_REGISTRY}' /etc/hosts > /tmp/hosts.sdp 2>/dev/null && cat /tmp/hosts.sdp > /etc/hosts" 2>/dev/null || true
    # ④ 重启 containerd 使 mirror + DNS 生效
    docker exec "$NODE" bash -c "systemctl restart containerd" 2>/dev/null || true
    log "node DNS: ${HARBOR_REGISTRY} -> $dns (via CoreDNS rewrite)，containerd 已重启"
}

# 宿主机 /etc/hosts（docker push / 浏览器访问用；需要 sudo，失败仅告警）
ensure_host_hosts() {
    local entry
    for entry in "127.0.0.1 ${HARBOR_REGISTRY}" "127.0.0.1 ${SDP_GATEWAY_DOMAIN}"; do
        if ! grep -q "$entry" /etc/hosts 2>/dev/null; then
            if sudo sh -c "echo '$entry' >> /etc/hosts" 2>/dev/null; then
                log "host /etc/hosts appended: $entry"
            else
                log "WARN: 未能写入 host /etc/hosts（$entry）—— 请手工添加，否则 docker push / 浏览器访问 ${HARBOR_REGISTRY} 失败"
            fi
        fi
    done
}

# harbor HTTP API（经集群节点访问：节点经 CoreDNS 把 harbor.sdpworkflow.com 解析到网关 ClusterIP
# 直达 harbor，不依赖宿主端口转发 / sudo，与生产「节点经 Gateway 域名访问」一致；harbor_status 仅取 HTTP 状态码）。
harbor_api() { docker exec "$NODE" curl -s -k -u "${HARBOR_USER}:${HARBOR_PASS}" "$@"; }
harbor_status() { docker exec "$NODE" curl -s -k -o /dev/null -u "${HARBOR_USER}:${HARBOR_PASS}" -w '%{http_code}' "$@"; }
ensure_harbor_project() {
    local code body exists
    body=$(harbor_api "https://${HARBOR_REGISTRY}/api/v2.0/projects?name=${HARBOR_PROJECT}" 2>/dev/null || true)
    code=$(harbor_status "https://${HARBOR_REGISTRY}/api/v2.0/projects?name=${HARBOR_PROJECT}" 2>/dev/null || echo 000)
    exists=$(printf '%s' "$body" | grep -c "\"name\":\"${HARBOR_PROJECT}\"" || true)
    if [ "${exists:-0}" -gt 0 ]; then
        log "harbor project '$HARBOR_PROJECT' exists"
        return 0
    fi
    if [ "$code" != "200" ] && [ "$code" != "201" ]; then
        log "FATAL: 查询 harbor project 失败 (HTTP $code) —— harbor 不可达或非 admin 凭据，终止部署"
        exit 1
    fi
    # 未找到 -> 创建
    log "creating harbor project '$HARBOR_PROJECT' ..."
    code=$(harbor_status -X POST "https://${HARBOR_REGISTRY}/api/v2.0/projects" \
        -H "Content-Type: application/json" \
        -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"public\":true}" 2>/dev/null || echo 000)
    if [ "$code" = "201" ] || [ "$code" = "200" ]; then
        log "harbor project '$HARBOR_PROJECT' created (HTTP $code)"
    else
        log "FATAL: 创建 harbor project '$HARBOR_PROJECT' 失败 (HTTP $code) —— 镜像推送将全部失败，终止部署"
        exit 1
    fi
}
# 把「宿主已有的镜像」经集群节点 containerd 推到 harbor（与生产访问逻辑一致：节点在集群内经
# 网关域名 / 内部服务直达 harbor，不依赖宿主进程、不写死端口）。
#   背景：宿主 docker push harbor.sdpworkflow.com 在 macOS Docker Desktop 下因 daemon 跑在独立 VM、
#   无法访问宿主 loopback 的 port-forward 443 而失败；因此把镜像灌入节点 containerd，由节点经
#   harbor 内部服务（harbor.harbor.svc.cluster.local:80，无 TLS）推送。
#   - 宿主 docker save | 节点 ctr import 注入节点（自定义构建镜像 / 已拉取到宿主的上游镜像均适用）；
#   - 节点 ctr tag -> harbor 内部仓库路径，ctr push --platform linux/amd64 --plain-http --skip-verify。
#   参数 $1 = 宿主镜像引用（postgres:16-alpine / quay.io/keycloak/keycloak:26.7.4 /
#         software-distribution-platform-hub:v0.0.1）；目标 = harbor.sdpworkflow.com/${HARBOR_PROJECT}/<basename>。
node_push_to_harbor() {
    local src="$1" srcnode name tag harborgw
    [ -n "$src" ] || { log "WARN: node_push_to_harbor 空参数"; return 1; }
    # 派生 harbor 仓库名 / tag（取最后一个 / 之后的 basename，再按 : 拆 tag）
    local b="${src##*/}"; tag="${b##*:}"; name="${b%:*}"
    harborgw="harbor.harbor.svc.cluster.local/${HARBOR_PROJECT}/${name}:${tag}"
    log "node-push: $src -> $harborgw (经节点 containerd)"
    # 宿主 save | 节点 import（多架构 index 可能报 missing blob，但 amd64 manifest 已就绪，忽略非零）
    docker save "$src" 2>/dev/null | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null 2>&1 || true
    # 节点侧按 basename:tag 定位真实 ref（docker save/ctr import 会给无 registry 的本地镜像补 docker.io/library/ 前缀）。
    # 注意：awk 不得用 exit 提前退出——ctr images ls 输出超过管道缓冲(64KB)后，exit 会令上游 ctr
    # 收到 SIGPIPE(141)，pipefail+set -e 直接杀脚本（2026-10-09 实测三连死因），改用 found 旗标读完整个输入。
    srcnode=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null | awk -v b="${name}:${tag}" '$1 ~ b && !found {print $1; found=1}')
    [ -n "$srcnode" ] || { log "WARN: 源镜像未在节点找到: ${name}:${tag}"; return 1; }
    # 幂等快道：本函数恒先 docker save|ctr import，故比较对象恒反映宿主当前镜像。注意
    # ctr push --platform amd64 之后 harbor tag 存的是 amd64 子 manifest 的 digest（非 index），
    # 故优先从节点侧 <ref>@sha256:* 平台子引用取 amd64 manifest digest 与之比较（取不到或
    # 不一致则回退全量推送，安全兜底）。组件镜像重建后 digest 变化不命中，不会误跳过。
    local src_digest remote_digest
    src_digest=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null \
        | awk -v p="$srcnode@" 'index($1, p)==1 && $2 ~ /manifest/ && $2 !~ /index/ && $2 !~ /list/ && $0 ~ /linux\/amd64/ && !found {sub(/.*@/,"",$1); print $1; found=1}')
    remote_digest=$(docker exec "$NODE" curl -s -D - -o /dev/null \
        -u "${HARBOR_USER}:${HARBOR_PASS}" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "http://harbor.harbor.svc.cluster.local/v2/${HARBOR_PROJECT}/${name}/manifests/${tag}" 2>/dev/null \
        | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" && !f {print $2; f=1}')
    if [ -n "$src_digest" ] && [ -n "$remote_digest" ] && [ "$src_digest" = "$remote_digest" ]; then
        log "skip push (digest match): ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${name}:${tag}"
        return 0
    fi
    docker exec "$NODE" ctr -n k8s.io images tag --force "$srcnode" "$harborgw" >/dev/null 2>&1 \
        || { log "WARN: 节点 tag 失败: $harborgw"; return 1; }
    # 推 amd64（单架构镜像直接选唯一 manifest；多架构 index 选 amd64，避免缺 blob）；
    # 失败回退一次不带 --platform（个别单架构镜像对 --platform 报错时兜底）。
    if docker exec "$NODE" ctr -n k8s.io images push --platform linux/amd64 --skip-verify --plain-http \
            --user "${HARBOR_USER}:${HARBOR_PASS}" "$harborgw" >/dev/null 2>&1; then
        log "pushed ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${name}:${tag} (via node, amd64)"
    elif docker exec "$NODE" ctr -n k8s.io images push --skip-verify --plain-http \
            --user "${HARBOR_USER}:${HARBOR_PASS}" "$harborgw" >/dev/null 2>&1; then
        log "pushed ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${name}:${tag} (via node)"
    else
        log "WARN: 节点推 harbor 失败: $harborgw（可能 harbor 未就绪 / 凭据错）"
        return 1
    fi
}

# 把源镜像推到 harbor 的 $HARBOR_PROJECT 项目（tag=basename）。
#   宿主缺失则先拉取（存在则跳过），避免盲目重拉 / 网络失败时尽早暴露；统一经节点推送（见 node_push_to_harbor）。
push_image_to_harbor() {
    local src="$1"
    ensure_image "$src" || { log "WARN: 源镜像 $src 缺失且拉取失败，skip push"; return 1; }
    node_push_to_harbor "$src"
}

# 把镜像推到本地 registry（仅 bootstrap：envoy + harbor 自身镜像；节点直拉 docker.io 被代理挡死）
push_to_local_registry() {
    local src="$1" dst="$2"
    if ! docker image inspect "$dst" >/dev/null 2>&1; then
        docker image inspect "$src" >/dev/null 2>&1 || docker pull -q "$src" >/dev/null \
            || { log "WARN: pull $src failed"; return 1; }
        docker tag "$src" "$dst"
    fi
    docker push -q "$dst" >/dev/null || { log "WARN: push $dst failed"; return 1; }
    log "bootstrap image ready: $dst"
}

# ---------- 阶段接口 ----------
CERT_SCRIPT_SRC="$ENV_DIR/cert-build/cert-create.sh"
STATE_FILE="$SCRIPT_DIR/.deploy-state.env"

load_state() { [ -f "$STATE_FILE" ] && . "$STATE_FILE" || true; }

# 跨段状态落盘（platform 段产出 ENVOY_IP 等，components 段消费）；全量模式亦写，便于断点续跑。
save_state() {
    {
        echo "ENVOY_SVC=${ENVOY_SVC:-}"
        echo "ENVOY_SVC_NS=${ENVOY_SVC_NS:-}"
        echo "ENVOY_IP=${ENVOY_IP:-}"
    } > "$STATE_FILE"
    log "state saved: $STATE_FILE (ENVOY_IP=${ENVOY_IP:-<unset>})"
}

# 单段模式的前置状态断言：$1=当前值（调用方写 "${VAR:-}"，勿用 ${!var} 间接展开——bash 3.2 不支持
# 间接展开与 :- 默认值组合，set -u 下报 unbound variable）  $2=变量名  $3=产出该变量的阶段名
require_state() {
    if [ -z "${1:-}" ]; then
        log "FATAL: 缺少跨段状态 $2（由 $3 段产出）。请先运行: $0 --stage $3"
        exit 1
    fi
}

# ---- 阶段 1/5: infra（helm/registry/kind/宿主 hosts/自签证书/bootstrap 镜像） ----
stage_infra() {
    ensure_helm
    ensure_registry
    ensure_kind
    ensure_host_hosts

    # 证书（自签兜底，SAN *.${SDP_BASE_DOMAIN} 覆盖 harbor/console/hub）：先确保 harbor 证书文件存在，
    # 供 harbor-tls secret 使用；console/hub 的 TLS secret 沿用下方 #6.5 既有逻辑。
    if [ ! -f "$ENV_DIR/cert-build/certs/harbor.crt" ] || [ ! -f "$ENV_DIR/cert-build/certs/harbor.key" ]; then
        log "生成自签证书（SAN *.${SDP_BASE_DOMAIN} 覆盖 harbor/console/hub）..."
        DOMAINNAME="${SDP_BASE_DOMAIN}" NAMESPACE="$NS" bash "$CERT_SCRIPT_SRC"
    fi

    # 1. 预推 bootstrap 镜像到本地 registry（envoy 控制面/数据面 + harbor 自身 bitnamilegacy）。
    #    这些镜像不能依赖 harbor（harbor 自身 / harbor 网关的 envoy 数据面都还没起来），必须走 localhost:5000。
    log "预推 bootstrap 镜像到 localhost:5000 ..."
    push_to_local_registry "docker.io/envoyproxy/gateway:v1.6.1" "localhost:5000/envoyproxy/gateway:v1.6.1" || true
    push_to_local_registry "docker.io/envoyproxy/envoy:distroless-v1.36.4" "localhost:5000/envoyproxy/envoy:distroless-v1.36.4" || true
    if [ -f "$HARBOR_DIR/harbor-27.0.3.tgz" ]; then
        # 用 pipe->while read 逐行处理（避免 $HARBOR_IMGS 裸展开做字段切分，镜像名若含括号等
        # shell 元字符会触发 "unexpected token ')'" 语法错误）。
        "$HELM" template harbor "$HARBOR_DIR/harbor-27.0.3.tgz" -f "$HARBOR_DIR/values.yaml" \
            | sed -nE 's/^[[:space:]]*image:[[:space:]]*"?([^"[:space:]]+)"?$/\1/p' \
            | sort -u \
            | while IFS= read -r img; do
                  [ -n "$img" ] || continue
                  push_to_local_registry "docker.io/${img#localhost:5000/}" "$img" || true
              done
    else
        log "WARN: 缺少 $HARBOR_DIR/harbor-27.0.3.tgz，harbor 安装将失败"
    fi
    log "bootstrap images ready"
}

# ---- 阶段 2/5: harbor（envoy 控制面 + harbor 安装/网关/DNS/project + postgres/keycloak 入 harbor） ----
stage_harbor() {
    [ -f "$ENV_DIR/cert-build/certs/harbor.crt" ] || { log "FATAL: 缺少 harbor 证书（由 infra 段生成）。请先运行: $0 --stage infra"; exit 1; }

    # 2. Envoy Gateway 控制面（先于任何 Gateway/EnvoyProxy 资源）
    if ! kubectl get ns envoy-gateway-system >/dev/null 2>&1; then
        log "installing envoy-gateway controller..."
        "$HELM" install eg "$SCRIPT_DIR/deploy/envoy-gateway-helm-v1.6.1.tgz" \
            -n envoy-gateway-system --create-namespace \
            --set config.envoyGateway.gateway.controllerName=gateway.envoyproxy.io/gatewayclass-controller
    fi
    kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=300s
    log "envoy-gateway controller ready"

    # 3. Harbor 先行（集群内镜像仓库；ns harbor）。
    #    幂等：已安装也走 upgrade --install，确保 values.yaml 变更（如镜像地址从 docker.io 前缀修正为
    #    localhost:5000）生效，便于重复运行自愈；首装/重装都走同一路径。
    kubectl create ns harbor --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    if ! kubectl -n harbor get secret harbor-tls >/dev/null 2>&1; then
        kubectl -n harbor create secret tls harbor-tls \
            --cert="$ENV_DIR/cert-build/certs/harbor.crt" \
            --key="$ENV_DIR/cert-build/certs/harbor.key"
    fi
    "$HELM" upgrade --install harbor "$HARBOR_DIR/harbor-27.0.3.tgz" -n harbor -f "$HARBOR_DIR/values.yaml"
    if ! kubectl -n harbor wait --for=condition=ready pod -l app.kubernetes.io/name=harbor --timeout=600s 2>/dev/null; then
        log "WARN: harbor pods 600s 未全部 ready，打印诊断（下一步请据此判断是镜像拉取还是内部依赖）："
        set +e
        echo "    | ---- pods 状态 ----"
        kubectl -n harbor get pods -o wide 2>/dev/null | sed 's/^/    | /'
        echo "    | ---- 各 pod 拉取/重启原因 ----"
        kubectl -n harbor get pods -o jsonpath='{range .items[*]}{.metadata.name}{"  phase="}{.status.phase}{"  state="}{.status.containerStatuses[0].state}{"\n"}{end}' 2>/dev/null | sed 's/^/    | /'
        echo "    | ---- bootstrap registry(localhost:5000) 已入库镜像 ----"
        curl -s localhost:5000/v2/_catalog 2>/dev/null | sed 's/^/    | /' || echo "    | (无法连接 localhost:5000，bootstrap registry 可能未起)"
        set -e
    fi
    # harbor 网关（独立 EnvoyProxy harbor-eg，type: ClusterIP：与生产形态一致、零写死端口）。
    # 宿主侧由 sudo kubectl port-forward 443:443 暴露，仅供宿主 docker push / 浏览器访问；
    # 节点拉镜像不经此转发——节点在集群内经 CoreDNS 把 harbor.sdpworkflow.com 解析到网关 ClusterIP 直达 harbor。
    kubectl apply -f "$HARBOR_DIR/harbor-gateway.yaml" --validate=false
    # 等待 harbor-gateway 的 envoy 数据面 svc 创建（harbor 未 Ready 时 Gateway 不会 Programmed，svc 不会及时出现）。
    # jsonpath 在 svc 集合为空时以非零退出，set -e 下会直接杀脚本 -> 必须挂 || true（2026-10-09 实测踩雷修复）。
    HARBOR_ENVOY_NS=""; HARBOR_ENVOY_SVC=""
    for i in $(seq 1 60); do
        HARBOR_ENVOY_SVC=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=harbor-gateway \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [ -n "$HARBOR_ENVOY_SVC" ] && break; sleep 5
    done
    HARBOR_ENVOY_NS=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=harbor-gateway \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    if [ -z "$HARBOR_ENVOY_SVC" ]; then
        log "FATAL: 未找到 harbor-gateway envoy svc（请检查 EG controller 与 Gateway 状态）"
        exit 1
    fi
    # 宿主 port-forward 暴露 harbor 443（sudo 绑标准 443，仅供宿主 docker push / 浏览器；
    # 节点侧不依赖此转发，节点经 CoreDNS 解析 harbor.sdpworkflow.com -> 网关 ClusterIP 在集群内直达）。
    sudo kubectl -n "$HARBOR_ENVOY_NS" port-forward --address 0.0.0.0 "svc/$HARBOR_ENVOY_SVC" 443:443 \
        >/dev/null 2>&1 &
    HARBOR_PF_PID=$!
    disown "$HARBOR_PF_PID" 2>/dev/null || true
    # 等待 port-forward 生效（harbor 健康端点可达）
    for i in $(seq 1 30); do
        if curl -s -k --resolve "${HARBOR_REGISTRY}:443:127.0.0.1" "https://${HARBOR_REGISTRY}/api/v2.0/health" \
            >/dev/null 2>&1; then
            break
        fi
        sleep 3
    done
    log "harbor-gateway: 宿主 port-forward 443:443 (pid=$HARBOR_PF_PID, 仅供 docker push/浏览器); 节点经 CoreDNS 解析在集群内直达"
    # 等 harbor 网关就绪（Envoy 数据面 Programmed）后再建项目 / 推镜像。
    # condition type 须为 Programmed（Gateway API 标准条件是 Accepted/Programmed，没有 Ready——
    # 2026-10-09 实测：写成 Ready 永不匹配，该循环每次固定烧满 30×5s=150s）。
    for i in $(seq 1 30); do
        [ "$(kubectl get gateway harbor-gateway -n harbor -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)" = "True" ] && break
        sleep 5
    done
    # 节点侧：CoreDNS rewrite harbor.sdpworkflow.com -> 网关 svc 集群 DNS 名（集群内直达，不写 IP）。
    HARBOR_GW_DNS="${HARBOR_ENVOY_SVC}.${HARBOR_ENVOY_NS}.svc.cluster.local"
    ensure_node_dns_harbor "$HARBOR_GW_DNS"
    ensure_harbor_project
    docker login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" >/dev/null 2>&1 || true
    # 平台依赖镜像先推 harbor（postgres / keycloak），三个组件镜像稍后由本脚本经节点推（build.sh 只构建不推送）
    push_image_to_harbor "postgres:16-alpine"
    push_image_to_harbor "quay.io/keycloak/keycloak:26.7.4"
    log "harbor ready: https://${HARBOR_REGISTRY} (admin/${HARBOR_PASS})"
}

# ---- 阶段 3/5: images（三组件构建 + 推 harbor） ----
stage_images() {
    # 4. 构建三组件镜像（build.sh 只构建 + docker save，不推送；镜像推送统一见下方 node_push_to_harbor 循环）
    BUILD_LOG_DIR="$ROOT/.logs"; mkdir -p "$BUILD_LOG_DIR"
    for comp in hub runner console; do
        mod_dir="$ROOT/software-distribution-platform-${comp}"
        if docker image inspect "software-distribution-platform-${comp}:${VERSION}" >/dev/null 2>&1; then
            # 镜像已存在（前次构建产物仍在宿主 docker），跳过重建，仅由下方 node_push 循环重新推送；
            # 若改了源码想强制重构建，先 docker rmi software-distribution-platform-${comp}:${VERSION} 或升版本号。
            log "image software-distribution-platform-${comp}:${VERSION} present, skip rebuild (re-push via node below)"
        else
            log "building ${comp} (this may take a few minutes)"
            blog="$BUILD_LOG_DIR/build-${comp}.log"
            if ! ( cd "$mod_dir" && "$mod_dir/build/${comp}/build.sh" "$VERSION" ) >"$blog" 2>&1; then
                log "FATAL: ${comp} 构建失败，日志尾部如下（完整: ${blog}）:"
                tail -n 30 "$blog" | sed 's/^/    | /' >&2; exit 1
            fi
            log "${comp} built ok (log: $blog)"
        fi
    done
    # 三组件镜像经节点推 harbor（build.sh 不推送；macOS Docker Desktop 下宿主 daemon 与节点网络隔离，
    # 直接 docker push 到 harbor.sdpworkflow.com:443 会失败，故统一走 node_push_to_harbor，
    # 与生产「节点经 Gateway 域名拉/推镜像」一致）。
    for comp in hub runner console; do
        node_push_to_harbor "software-distribution-platform-${comp}:${VERSION}" \
            || log "WARN: 节点推 ${comp} 失败（镜像未进 harbor，后续部署会 ImagePullBackOff）"
    done
    log "component images pushed to harbor (via node)"
}

# ---- 阶段 4/5: platform（postgres/清理 P0/TLS secrets/sdp-ca/sdp-gateway；产出 ENVOY_IP） ----
stage_platform() {
    # 5. 命名空间 + postgres（外部依赖，沿用 P0 manifests；镜像已推 harbor）
    kubectl apply -f "$HUB_DIR/deploy/manifests/00-namespace.yaml"
    kubectl apply -f "$HUB_DIR/deploy/manifests/10-postgres.yaml"
    kubectl -n "$NS" rollout status deploy/postgres --timeout=180s
    log "postgres ready (image from harbor)"

    # 6. 清理 P0 裸 manifests 装的旧资源（换成 helm 管理）
    kubectl -n "$NS" delete deploy/hub deploy/runner svc/hub pvc/hub-artifacts --ignore-not-found
    kubectl -n "$NS" delete sa/sdp-runner --ignore-not-found
    kubectl delete clusterrole/sdp-runner clusterrolebinding/sdp-runner --ignore-not-found
    log "legacy P0 resources removed"

    # 6.5 TLS secret（console-tls / console-ingress-tls）：沿用既有逻辑（console/hub 网关证书），
    #     缺失才用 cert-build 自签兜底；harbor 的 harbor-tls 已在 #3 建好。
    if kubectl -n "$NS" get secret console-tls >/dev/null 2>&1 \
       && kubectl -n "$NS" get secret console-ingress-tls >/dev/null 2>&1; then
        log "TLS secrets present (console-tls / console-ingress-tls), reused"
    elif [ -n "${SKIP_GEN_CERTS:-}" ]; then
        log "FATAL: 缺少 TLS secret 且 SKIP_GEN_CERTS=1"
        exit 1
    else
        log "TLS secrets missing -> local self-signed fallback"
        bash "$CERT_SCRIPT_SRC" "$NS"
        # cert-create.sh 产出的是 generic 类型的 ${component}-server-secret（命名不匹配、且不自动 apply）；
        # 故此处用 cert-build 生成的 console 证书显式建两个 secret（不改 cert-build 脚本）：
        # 两个 secret 类型/key 约定不同，见下方各自注记。
        # console-ingress-tls：网关 https listener 证书，须 kubernetes.io/tls 类型（tls.crt/tls.key）。
        kubectl -n "$NS" create secret tls console-ingress-tls \
            --cert="$ENV_DIR/cert-build/certs/console.crt" \
            --key="$ENV_DIR/cert-build/certs/console.key" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        # console-tls：console 容器挂 /etc/nginx/ssl + BackendTLSPolicy CA 校验用，chart 约定
        # generic 三 key（ca.crt/server.crt/server.key，见 console chart values.yaml cert 注记）。
        # 不能建 tls 类型（只有 tls.crt/tls.key），否则 console pod FailedMount 找不到 ca.crt。
        kubectl -n "$NS" create secret generic console-tls \
            --from-file=ca.crt="$ENV_DIR/cert-build/certs/ca.crt" \
            --from-file=server.crt="$ENV_DIR/cert-build/certs/console.crt" \
            --from-file=server.key="$ENV_DIR/cert-build/certs/console.key" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        log "TLS secrets created (console-ingress-tls tls-type / console-tls generic 3-key) from self-signed certs"
    fi

    # 6.6 sdp-ca：hub 挂载 /etc/sdp-ca/ca.crt 信任自签 harbor/keycloak 证书（cert-build 的 CA）。
    #     hub deployment 的 volume sdp-ca 引用 key ca.crt，缺失则 hub pod FailedMount 卡 ContainerCreating。
    if ! kubectl -n "$NS" get secret sdp-ca >/dev/null 2>&1; then
        kubectl -n "$NS" create secret generic sdp-ca \
            --from-file=ca.crt="$ENV_DIR/cert-build/certs/ca.crt"
        log "secret sdp-ca created (ca.crt from cert-build)"
    fi

    # 7. 平台统一入口 Gateway（sdp-gateway，https listener 8443 与 issuer/浏览器端口三方一致）
    #    注：harbor 网关使用独立 GatewayClass harbor-eg（不复用 sdp-eg），故此处无需提前 apply；
    #        此处幂等 apply，再等待其 envoy 数据面 svc 出现并固定 NodePort（与 harbor 段同理）。
    kubectl apply -f "$SCRIPT_DIR/deploy/gateway-sdp.yaml" --validate=false
    # 等待 sdp-gateway 的 envoy 数据面 svc 创建（与 harbor-gateway 同理：Gateway 未 Programmed 前 svc 不出现，
    # 故拉长等待窗口；否则落到随机 NodePort 会与 kind.yaml 的 hostPort 映射错位，导致平台入口不可达）。
    # EG v1.6.1 不支持在 EnvoyProxy 声明 NodePort，只能事后 patch svc。
    # jsonpath 空集合非零退出 + set -e -> 挂 || true（同 stage_harbor，2026-10-09 修复）。
    ENVOY_SVC_NS=""; ENVOY_SVC=""
    for i in $(seq 1 60); do
        ENVOY_SVC=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=sdp-gateway \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        [ -n "$ENVOY_SVC" ] && break; sleep 5
    done
    ENVOY_SVC_NS=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=sdp-gateway \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    if [ -z "$ENVOY_SVC" ]; then
        log "FATAL: sdp-gateway envoy proxy svc 未创建（请检查 EG controller 与 Gateway 状态）"
        exit 1
    fi
    # 宿主 port-forward 暴露 sdp-gateway（ClusterIP，不写死端口）：本地 8443->svc 8443（https）、8082->svc 80（http）。
    # 绑定 127.0.0.1（仅宿主/浏览器经 --resolve 访问；集群内 pod 走 ClusterIP DNS，不经此处）。
    kubectl -n "$ENVOY_SVC_NS" port-forward "svc/$ENVOY_SVC" 8443:8443 8082:80 \
        >/dev/null 2>&1 &
    disown $! 2>/dev/null || true
    # 等待本地 8443 可用
    for i in $(seq 1 30); do
        if curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 "https://${SDP_GATEWAY_DOMAIN}:8443/" \
            >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    ENVOY_IP=$(kubectl -n "$ENVOY_SVC_NS" get "svc/$ENVOY_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    log "envoy svc ready ($ENVOY_SVC_NS/$ENVOY_SVC clusterIP=${ENVOY_IP:-<unset>}); host exposed via port-forward 8443:8443 8082:80"
    save_state
}

# ---- 阶段 5/5: components（hub/runner/console 部署 + target 注册 + 握手验证） ----
stage_components() {
    if [ -z "${ENVOY_IP:-}" ]; then load_state; fi
    require_state "${ENVOY_IP:-}" ENVOY_IP platform

    # 8. hub（image + keycloak 子 chart 镜像均从 harbor 拉；经网关 8443 与 issuer 端口一致）
    ISSUER="https://${SDP_GATEWAY_DOMAIN}:8443/keycloak/realms/sdp"
    AUTH_SETS=()
    if [ -z "${SKIP_AUTH:-}" ]; then
        AUTH_SETS=(
            --set auth.keycloakIssuerUrl="$ISSUER"
            --set auth.adminClientSecret='**********'
            --set auth.trustedCASecret=sdp-ca
            --set auth.resolveHostIp="$ENVOY_IP"
            --set keycloak.hostname="https://${SDP_GATEWAY_DOMAIN}:8443/keycloak"
            --set credentialEncryptionKey='sdp-dev-credential-key-000000000'
        )
        log "auth ON: issuer=$ISSUER hostAlias=$ENVOY_IP"
    fi
    HUB_HELM_ARGS=(--set image.imageAddr="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/software-distribution-platform-hub:${VERSION}")
    if [ ${#AUTH_SETS[@]} -gt 0 ]; then HUB_HELM_ARGS+=("${AUTH_SETS[@]}"); fi
    "$HELM" upgrade --install hub "$HUB_DIR/build/hub/charts/software-distribution-platform-hub" -n "$NS" "${HUB_HELM_ARGS[@]}"
    if [ -n "${SKIP_AUTH:-}" ]; then
        kubectl -n "$NS" rollout status deploy/hub --timeout=180s
    else
        kubectl -n "$NS" delete pod hub-keycloak-0 --ignore-not-found --force --grace-period=0 >/dev/null 2>&1 || true
        kubectl -n "$NS" wait --for=condition=ready pod/hub-keycloak-0 --timeout=240s \
            || log "WARN: keycloak pod not ready in 240s"
        kubectl -n "$NS" rollout status deploy/hub --timeout=240s
    fi
    log "hub ready"

    # 9. 注册接入目标（幂等）。auth ON：先经 sdp-console password grant（admin 用户）换 token，
    #    再带 Bearer 注册 —— hub 侧 POST /targets 无 RBAC 门槛（main.go M1 wiring），
    #    部署后 target 即就位，runner 握手无需人工登录 console 建目标。
    #    访问面自管：宿主 8443 已有转发（platform 段 pf）则复用；否则本段自起一条短命 pf、
    #    注册后即杀 —— 不依赖段外长寿命进程（沙箱/CI 里长 pf 易 lost connection）。
    #    循环内条件一律显式 if：`[ ... ] && break` 空值时整行非零会被 set -e 秒杀。
    gw_probe() {
        curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 -o /dev/null --max-time 3 \
            "https://${SDP_GATEWAY_DOMAIN}:8443/api/v1/targets" 2>/dev/null
    }
    REG_PAYLOAD='{"name":"local-dev","vendor":"kind","region":"local"}'
    REG_PF_PID=""
    REG_CODE=""
    if ! gw_probe; then
        log "宿主 8443 访问面不在 —— 注册窗口内自起短命 port-forward"
        kubectl -n "$ENVOY_SVC_NS" port-forward "svc/$ENVOY_SVC" 8443:8443 >/dev/null 2>&1 &
        REG_PF_PID=$!
        for i in 1 2 3 4 5; do
            if gw_probe; then break; fi
            if [ "$i" = "5" ]; then REG_CODE="no-access"; fi
            sleep 1
        done
    fi
    if [ "$REG_CODE" != "no-access" ]; then
        if [ -n "${SKIP_AUTH:-}" ]; then
            REG_CODE=$(curl -s -k -o /tmp/sdp-register-target.json -w '%{http_code}' --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 \
                -X POST https://${SDP_GATEWAY_DOMAIN}:8443/api/v1/targets \
                -H "Content-Type: application/json" -d "$REG_PAYLOAD" 2>/dev/null || echo "000")
            else
                # pipefail/set -e 下 curl 失败必须兜底；keycloak 刚重启有 warm-up 窗口，3 次重试覆盖
                # 通道说明：hub 校验 azp 必须 = keycloakClientId(sdp-console)（middleware/auth.go），
                # sdp-backend 的 client_credentials token azp=sdp-backend 会被 401——必须走
                # sdp-console 的 password grant（public client，directAccessGrantsEnabled=true）。
                KC_RESP_FILE=/tmp/sdp-kc-token.json
                KC_TOKEN=""; KC_CODE=""
                for attempt in 1 2 3; do
                    KC_CODE=$(curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 \
                        -o "$KC_RESP_FILE" -w '%{http_code}' \
                        -X POST "https://${SDP_GATEWAY_DOMAIN}:8443/keycloak/realms/sdp/protocol/openid-connect/token" \
                        -H "Content-Type: application/x-www-form-urlencoded" \
                        -d 'grant_type=password&client_id=sdp-console&username=admin&password=sdp@12345' 2>/dev/null) || KC_CODE="000"
                KC_TOKEN=""
                if [ -n "$KC_CODE" ] && [ "$KC_CODE" != "000" ]; then
                    KC_TOKEN=$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' "$KC_RESP_FILE" 2>/dev/null || true)
                fi
                if [ -n "$KC_TOKEN" ]; then break; fi
                if [ "$attempt" != "3" ]; then sleep 3; fi
            done
            if [ -n "$KC_TOKEN" ]; then
                # 先查重：target 已存在时 hub Create 会撞唯一约束返回 500（未映射 409），
                # 预查列表把「已存在」归一到 409 幂等分支。
                LIST_CODE=$(curl -s -k -o /tmp/sdp-targets.json -w '%{http_code}' --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 \
                    -X GET "https://${SDP_GATEWAY_DOMAIN}:8443/api/v1/targets?pageSize=200" \
                    -H "Authorization: Bearer $KC_TOKEN" 2>/dev/null || echo "000")
                if [ "$LIST_CODE" = "200" ] && grep -q '"name":"local-dev"' /tmp/sdp-targets.json 2>/dev/null; then
                    REG_CODE="409"
                else
                    REG_CODE=$(curl -s -k -o /tmp/sdp-register-target.json -w '%{http_code}' --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 \
                        -X POST https://${SDP_GATEWAY_DOMAIN}:8443/api/v1/targets \
                        -H "Content-Type: application/json" -H "Authorization: Bearer $KC_TOKEN" \
                        -d "$REG_PAYLOAD" 2>/dev/null || echo "000")
                fi
            else
                REG_CODE="no-token"
            fi
        fi
    fi
    case "$REG_CODE" in
        200|201)   log "target registered: local-dev (HTTP $REG_CODE)" ;;
        409)       log "target local-dev already exists (HTTP 409) - ok" ;;
        no-access) log "WARN: 宿主 8443 访问面不可用（短命 pf 也未就绪）—— 检查集群/envoy 状态后重跑本段" ;;
        no-token)  log "WARN: keycloak token 获取失败 (HTTP ${KC_CODE:-?})，响应见 ${KC_RESP_FILE}；检查 keycloak 是否 ready、sdp-backend secret 是否与 realm 预置一致" ;;
        000)       log "WARN: 注册请求连不通 (HTTP 000) —— 访问面在注册窗口内断连，重跑本段即可" ;;
        401|403)   log "WARN: target 注册被拒 (HTTP $REG_CODE) —— token 无效或 hub 侧拒绝" ;;
        *)         log "WARN: register target failed (HTTP $REG_CODE)" ;;
    esac
    if [ -n "$REG_PF_PID" ]; then kill "$REG_PF_PID" 2>/dev/null || true; fi

    # 10. runner（image 从 harbor）
    "$HELM" upgrade --install runner "$RUNNER_DIR/build/runner/charts/software-distribution-platform-runner" \
        -n "$NS" --set image.imageAddr="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/software-distribution-platform-runner:${VERSION}"
    kubectl -n "$NS" rollout status deploy/runner --timeout=180s
    log "runner ready"

    # 11. console（image 从 harbor）
    AUTH_SETS_CONSOLE=()
    if [ -z "${SKIP_AUTH:-}" ]; then
        AUTH_SETS_CONSOLE=(
            --set auth.authDisabled=false
            --set auth.keycloakIssuerUrl="$ISSUER"
            --set auth.keycloakClientId=sdp-console
            --set auth.keycloakRedirectUri="https://${SDP_GATEWAY_DOMAIN}:8443/auth/callback"
        )
    fi
    CONSOLE_HELM_ARGS=(--set image.imageAddr="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/software-distribution-platform-console:${VERSION}")
    if [ ${#AUTH_SETS_CONSOLE[@]} -gt 0 ]; then CONSOLE_HELM_ARGS+=("${AUTH_SETS_CONSOLE[@]}"); fi
    "$HELM" upgrade --install console "$CONSOLE_DIR/build/console/charts/software-distribution-platform-console" \
        -n "$NS" "${CONSOLE_HELM_ARGS[@]}"
    kubectl -n "$NS" rollout restart deploy/console
    kubectl -n "$NS" rollout status deploy/console --timeout=180s
    log "console ready"

    # 12. 网关握手验证
    OK=""
    for i in $(seq 1 15); do
        if kubectl -n "$NS" logs deploy/hub --tail=50 2>/dev/null | grep -qi "connected"; then OK=1; break; fi
        sleep 3
    done
    [ -n "$OK" ] && log "gateway handshake OK" || log "WARN: handshake not seen in 45s"

    log "=========================================="
    log "console: https://${SDP_GATEWAY_DOMAIN}:8443  (自签证书 curl -k / 浏览器信任 ca.crt)"
    log "harbor:  https://${HARBOR_REGISTRY}    (admin/${HARBOR_PASS})"
    log "hub:     https://${SDP_GATEWAY_DOMAIN}:8443/api/v1"
    log "集群:    kind sdp-dev | namespace: $NS | 版本: $VERSION"
    log "=========================================="
}

# ---------- 分发 ----------
if [ -n "$STAGE" ]; then
    # 单段模式：自动补齐幂等轻量前置（ensure_kind 导出 kubeconfig 供 kubectl 使用）
    ensure_helm
    ensure_kind
    case "$STAGE" in
        infra|harbor) ensure_registry ;;   # 两段依赖 localhost:5000 bootstrap registry
    esac
    case "$STAGE" in
        infra)      stage_infra ;;
        harbor)     stage_harbor ;;
        images)     stage_images ;;
        platform)   stage_platform ;;
        components) stage_components ;;
    esac
    exit 0
fi

# 全量部署（人类默认路径；顺序 = 依赖顺序，与阶段化之前行为一致）
stage_infra
stage_harbor
stage_images
stage_platform
stage_components
