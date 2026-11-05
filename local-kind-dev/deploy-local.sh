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
#   网关数据面 svc 为 NodePort（固定值由本脚本在 svc 创建后幂等 patch；EG 实测接受 type: NodePort
#   且不回改 patch 的 nodePort）；宿主访问统一走 kind extraPortMappings（docker-proxy 常驻、随集群
#   存活，不依赖任何 port-forward 进程），端口号不进任何域名/镜像引用：
#   - sdp-gateway：host 8443 -> 节点 31843 -> svc 8443（https listener 8443，与 issuer/浏览器端口三方一致，
#     2026-09-23 裁定）、host 8082 -> 节点 31800 -> svc 80（http）；curl 用 --resolve www.sdpworkflow.com:8443:127.0.0.1。
#   - harbor-gateway：host 443 -> 节点 30443 -> svc 443（仅供宿主 docker push / 浏览器）；
#     节点拉镜像不经宿主——节点在集群内经 CoreDNS 把 harbor.sdpworkflow.com 解析到 harbor 网关 ClusterIP
#     直达 harbor（与生产「节点经 Gateway 域名拉镜像」一致），不写任何 IP、不依赖宿主进程。
#
# 阶段化：五段边界 = 部署依赖的自然切面；每段幂等可重入，
#   跨段状态（ENVOY_IP 等）经 $STATE_FILE 传递；单段模式面向断点续跑（某段超时/失败，
#   修复后单独重跑该段即可，无需从头全量）。默认（无 --stage）= 全量部署。
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
# 本地/集群内通信禁用外部代理：本 agent 沙箱会向 kind 节点容器注入 HTTP_PROXY，宿主 shell 亦可能
# 带代理；curl 命中代理会把 ClusterIP / 127.0.0.1 请求转给不存在的代理端口（127.0.0.1:54320）导致
# HTTP 000。本地与集群域名走直连，外部下载（helm）仍走代理。
export no_proxy="127.0.0.1,localhost,${HARBOR_REGISTRY},${SDP_GATEWAY_DOMAIN},.svc,.svc.cluster.local,.cluster.local"
export NO_PROXY="$no_proxy"
HARBOR_PROJECT="${HARBOR_PROJECT:-sdp}"
HARBOR_USER="${HARBOR_USER:-admin}"
# harbor 口令由 chart 随机生成存 core envvars Secret（harbor/values.yaml 不写死
# adminPassword）；默认留空，由 ensure_harbor_pass 在 harbor / images 阶段从 Secret 取回。
HARBOR_PASS="${HARBOR_PASS:-}"

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
            echo "网关经宿主端口映射直达（kind extraPortMappings：8443/8082/443 随集群常驻），无需 port-forward"
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
    if sdp_inspect "$img" >/dev/null 2>&1; then
        log "image exists, skip pull: $img"
    else
        log "pulling $img ..."
        sdp_pull -q "$img" >/dev/null || { log "WARN: pull $img failed"; return 1; }
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
#   ① patch kube-system/coredns，注入 rewrite name <域名> -> 网关 svc 集群 DNS 名并重启 coredns
#     （harbor 与 sdp 平台入口两个域名都走这里：hub pod 需经 ${SDP_GATEWAY_DOMAIN} 访问
#      Keycloak issuer/JWKS，不注入则 hub 对外 401）；
#   ② 节点 /etc/resolv.conf 前置 CoreDNS（kube-dns 默认 10.96.0.10）；
#   ③ 节点 /etc/hosts 清除任何 harbor 行（避免陈旧 IP 覆盖 DNS）；④ 重启 containerd 生效。
patch_coredns_rewrite() {
    local domain="$1" dns="$2" cm newcm
    [ -n "$domain" ] && [ -n "$dns" ] || { log "WARN: patch_coredns_rewrite 需要 <域名> <网关svc集群DNS名> 两个参数"; return 1; }
    cm=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null)
    [ -n "$cm" ] || { log "WARN: 读取 coredns Corefile 失败，跳过 rewrite 注入"; return 1; }
    if echo "$cm" | grep -q "rewrite name ${domain} $dns"; then
        log "coredns rewrite 已存在 ($dns)"
        return 0
    fi
    # 在 '    ready' 行后插入 rewrite（4 空格缩进，与 Corefile 一致）；通过 stdin 注入新 Corefile。
    newcm=$(printf '%s\n' "$cm" | awk -v domain="$domain" -v dns="$dns" '{print} /^    ready$/ {print "    rewrite name " domain " " dns}')
    printf '%s\n' "$newcm" \
        | kubectl -n kube-system create cm coredns --from-file=Corefile=/dev/stdin --dry-run=client -o yaml 2>/dev/null \
        | kubectl apply -f - 2>/dev/null \
        || { log "WARN: 注入 coredns rewrite 失败（节点可能无法经 DNS 解析 harbor，将影响镜像拉取）"; return 1; }
    kubectl -n kube-system rollout restart deployment/coredns 2>/dev/null
    kubectl -n kube-system rollout status deployment/coredns --timeout=120s 2>/dev/null || true
    log "coredns rewrite 注入 -> ${dns}，coredns 已重启"
}
ensure_node_dns_harbor() {
    local dns="$1"
    [ -n "$dns" ] || { log "WARN: ensure_node_dns_harbor 未收到网关 svc 集群 DNS 名，跳过节点 DNS 更新"; return 1; }
    patch_coredns_rewrite "${HARBOR_REGISTRY}" "$dns"
    # ② 节点 /etc/resolv.conf 前置 CoreDNS（已前置则跳过，避免重复）
    docker exec "$NODE" sh -c "grep -q '^nameserver 10.96.0.10' /etc/resolv.conf || { printf 'nameserver 10.96.0.10\n' | cat - /etc/resolv.conf > /tmp/resolv.sdp && cat /tmp/resolv.sdp > /etc/resolv.conf; }" 2>/dev/null || true
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
                log "WARN: 未能写入 host /etc/hosts（${entry}）—— 请手工添加，否则 docker push / 浏览器访问 ${HARBOR_REGISTRY} 失败"
            fi
        fi
    done
}

# harbor HTTP API（经集群节点访问：节点经 CoreDNS 把 harbor.sdpworkflow.com 解析到网关 ClusterIP
# 直达 harbor，不依赖宿主端口转发 / sudo，与生产「节点经 Gateway 域名访问」一致；harbor_status 仅取 HTTP 状态码）。
harbor_api() { docker exec "$NODE" curl -s -k --noproxy '*' -u "${HARBOR_USER}:${HARBOR_PASS}" "$@"; }
harbor_status() { docker exec "$NODE" curl -s -k --noproxy '*' -o /dev/null -u "${HARBOR_USER}:${HARBOR_PASS}" -w '%{http_code}' "$@"; }
# harbor 口令随机生成（不写死）：未显式传 HARBOR_PASS 时从 core envvars Secret 取回，
# 保证 harbor API 与镜像推送凭据一致；取回失败显式 FATAL，不静默回落空凭据
#（空凭据的 401 会在下游报成更难定位的推送失败）。
ensure_harbor_pass() {
    if [ -z "$HARBOR_PASS" ]; then
        HARBOR_PASS=$(kubectl -n harbor get secret harbor-core-envvars \
            -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -z "$HARBOR_PASS" ]; then
            log "FATAL: 未能从 harbor core Secret 取回 admin 口令（口令由 chart 随机生成、不写死）——检查 harbor 安装状态，或显式传 HARBOR_PASS"
            exit 1
        fi
        log "harbor admin password retrieved from core secret"
    fi
}
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
#   - 镜像入节点主路径：宿主 docker push -> 本地 kind-registry(localhost:5000)，节点 ctr pull
#     --plain-http（containerd 正确协商 amd64 平台，规避 docker save 多架构 index 缺 blob 的导入陷阱）；
#   - 节点 ctr tag -> harbor 内部仓库路径，ctr push --platform linux/amd64 --plain-http --skip-verify。
#   参数 $1 = 宿主镜像引用（postgres:16-alpine / quay.io/keycloak/keycloak:26.7.4 /
#         software-distribution-platform-hub:v0.0.1）；目标 = harbor.sdpworkflow.com/${HARBOR_PROJECT}/<basename>。
node_push_to_harbor() {
    local src="$1" srcnode name tag harborgw
    [ -n "$src" ] || { log "WARN: node_push_to_harbor 空参数"; return 1; }
    ensure_harbor_pass
    # 派生 harbor 仓库名 / tag（取最后一个 / 之后的 basename，再按 : 拆 tag）
    local b="${src##*/}"; tag="${b##*:}"; name="${b%:*}"
    harborgw="harbor.harbor.svc.cluster.local/${HARBOR_PROJECT}/${name}:${tag}"
    log "node-push: $src -> $harborgw (经节点 containerd)"

    # 入节点主路径：宿主推 kind-registry(localhost:5000) -> 节点 ctr pull（平台协商，多架构安全）。
    # 仅当 kind-registry 不可用时兜底退回 docker save|ctr import（单平台镜像可用，多架构可能缺 blob）。
    if docker inspect kind-registry >/dev/null 2>&1; then
        local dst="localhost:5000/${name}:${tag}"
        sdp_inspect "$dst" >/dev/null 2>&1 || sdp_tag "$src" "$dst"
        if sdp_push -q "$dst" >/dev/null 2>&1; then
            local rgip
            rgip=$(docker inspect kind-registry --format \
                '{{range $k,$v := .NetworkSettings.Networks}}{{if ne $k "bridge"}}{{$v.IPAddress}}{{end}}{{end}}' 2>/dev/null | tr -d ' ')
            if [ -n "$rgip" ]; then
                srcnode="${rgip}:5000/${name}:${tag}"
                if ! docker exec "$NODE" ctr -n k8s.io images pull --plain-http "$srcnode" >/dev/null 2>&1; then
                    log "WARN: 节点从 kind-registry 拉取失败: $srcnode"
                    srcnode=""
                fi
            fi
        else
            log "WARN: 宿主推 kind-registry 失败: $dst"
        fi
    fi
    if [ -z "$srcnode" ]; then
        # 兜底：docker save | ctr import（单平台镜像可用；多架构 index 可能报 missing blob，忽略非零）
        sdp_save "$src" 2>/dev/null | docker exec -i "$NODE" ctr -n k8s.io images import - >/dev/null 2>&1 || true
        # 节点侧按 basename:tag 定位真实 ref（docker save/ctr import 会给无 registry 的本地镜像补 docker.io/library/ 前缀）。
        # 注意：awk 不得用 exit 提前退出——ctr images ls 输出超过管道缓冲(64KB)后，exit 会令上游 ctr
        # 收到 SIGPIPE(141)，pipefail+set -e 直接杀脚本，故读完整个输入再处理（以 found 旗标读完整个输入）。
        srcnode=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null | awk -v b="${name}:${tag}" '$1 ~ b && !found {print $1; found=1}')
    fi
    [ -n "$srcnode" ] || { log "WARN: 源镜像未在节点找到: ${name}:${tag}"; return 1; }

    # 幂等快道：harbor 已有同 digest 镜像则跳过推送（节省时间；组件镜像重建后 digest 变化不命中会自动重推）。
    # 注意：awk 不得用 exit 提前退出（SIGPIPE 141 陷阱，见下方兜底分支注释），以 found 旗标读完整个输入。
    local src_digest remote_digest
    src_digest=$(docker exec "$NODE" ctr -n k8s.io images ls 2>/dev/null \
        | awk -v r="$srcnode" '$1==r && $2 ~ /manifest/ && $2 !~ /index/ && $2 !~ /list/ && $0 ~ /linux\/amd64/ && !found {print $3; found=1}')
    remote_digest=$(docker exec "$NODE" curl -s --noproxy '*' -D - -o /dev/null \
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
        log "WARN: 节点推 harbor 失败: ${harborgw}（可能 harbor 未就绪 / 凭据错）"
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
    if ! sdp_inspect "$dst" >/dev/null 2>&1; then
        sdp_inspect "$src" >/dev/null 2>&1 || sdp_pull -q "$src" >/dev/null \
            || { log "WARN: pull $src failed"; return 1; }
        sdp_tag "$src" "$dst"
    fi
    sdp_push -q "$dst" >/dev/null || { log "WARN: push $dst failed"; return 1; }
    log "bootstrap image ready: $dst"
}

# ---------- 容器运行时自感知分派（docker / containerd-nerdctl 双支持）----------
# k8s 1.24+ 默认 containerd、节点无 docker：镜像操作按本地可用运行时分派。
# 默认 nerdctl（containerd 工具）；若环境存在 docker 命令则重赋为 docker；
# 否则保持 nerdctl；nerdctl 须已在环境中就绪，缺失直接报失败（不做自动安装）。
# 注：kind 节点管理（docker network/run/inspect）与节点侧 ctr 桥接保持 docker/ctr 不变——
#     本脚本主要跑在 Win/Mac Docker Desktop，且节点永远是 containerd，ctr 通用。
SDP_RUNTIME="${SDP_RUNTIME:-nerdctl}"

ensure_nerdctl() {
    # nerdctl 硬判断：环境中必须已安装 nerdctl + buildkitd，否则直接报失败。
    command -v nerdctl >/dev/null 2>&1 || {
        echo "ERROR: 当前环境无 docker，且未检测到 nerdctl，无法构建镜像。请先安装 nerdctl + buildkitd。" >&2
        exit 1
    }
    command -v buildkitd >/dev/null 2>&1 || {
        echo "ERROR: 检测到 nerdctl 但缺少 buildkitd（nerdctl build 必需），请先安装 buildkitd。" >&2
        exit 1
    }
    pgrep -x buildkitd >/dev/null 2>&1 || nohup buildkitd --containerd-worker --addr tcp://127.0.0.1:1234 >/var/log/buildkitd.log 2>&1 &
    export BUILDKIT_HOST=tcp://127.0.0.1:1234
}

resolve_runtime() {
    case "${SDP_RUNTIME}" in docker|nerdctl) ;; *) echo "ERROR: SDP_RUNTIME 仅支持 docker|nerdctl" >&2; exit 1 ;; esac
    if command -v docker >/dev/null 2>&1; then SDP_RUNTIME=docker; return 0; fi
    ensure_nerdctl
    nerdctl info >/dev/null 2>&1 || { echo "ERROR: containerd/nerdctl 不可达" >&2; exit 1; }
}

sdp_build() { local ctx="$1" img="$2"; shift 2
    case "${SDP_RUNTIME}" in
        docker)  docker  build  "$@" -t "$img" "$ctx" ;;
        nerdctl) nerdctl build  "$@" -t "$img" "$ctx" ;;
    esac; }
sdp_save() {
    if [ -n "${2:-}" ]; then
        case "${SDP_RUNTIME}" in
            docker)  docker  save -o "$2" "$1" ;;
            nerdctl) nerdctl save --format docker -o "$2" "$1" ;;
        esac
    else
        case "${SDP_RUNTIME}" in
            docker)  docker  save "$1" ;;
            nerdctl) nerdctl save --format docker "$1" ;;
        esac
    fi; }
sdp_inspect() { case "${SDP_RUNTIME}" in docker) docker image inspect "$1" ;; nerdctl) nerdctl image inspect "$1" ;; esac; }
sdp_pull() { case "${SDP_RUNTIME}" in docker) docker pull "$@" ;; nerdctl) nerdctl pull "$@" ;; esac; }
sdp_tag() { case "${SDP_RUNTIME}" in docker) docker tag "$1" "$2" ;; nerdctl) nerdctl tag "$1" "$2" ;; esac; }
sdp_push() { case "${SDP_RUNTIME}" in docker) docker push "$@" ;; nerdctl) nerdctl push "$@" ;; esac; }
sdp_login() { case "${SDP_RUNTIME}" in docker) docker login "$@" ;; nerdctl) nerdctl login "$@" ;; esac; }

resolve_runtime; echo "== container runtime: ${SDP_RUNTIME} =="

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
    # harbor 网关（独立 EnvoyProxy harbor-eg，type: NodePort）。
    # 宿主侧经 kind extraPortMappings host 443 -> 节点 30443 直达，仅供宿主 docker push / 浏览器访问；
    # 节点拉镜像不经宿主——节点在集群内经 CoreDNS 把 harbor.sdpworkflow.com 解析到网关 ClusterIP 直达 harbor。
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
    # 固定 nodePort：EG 从 CRD 无法声明固定 nodePort 值，svc 由 EG 创建时落随机端口，须 patch 成
    # kind.yaml extraPortMappings 对应的 30443/31810（实测 EG 不回改）。幂等：重复 patch 同值无副作用。
    # 注意 kube-proxy 同步有秒级延迟，patch 后下方健康检查循环自带重试窗口。
    kubectl -n "$HARBOR_ENVOY_NS" patch "svc/$HARBOR_ENVOY_SVC" --type=merge \
        -p '{"spec":{"ports":[{"name":"http-80","port":80,"protocol":"TCP","nodePort":31810},{"name":"https-443","port":443,"protocol":"TCP","nodePort":30443}]}}' >/dev/null
    # 等待宿主 443 可用（extraPortMappings -> 节点 30443 -> svc；harbor 健康端点可达）
    for i in $(seq 1 30); do
        if curl -s -k --resolve "${HARBOR_REGISTRY}:443:127.0.0.1" "https://${HARBOR_REGISTRY}/api/v2.0/health" \
            >/dev/null 2>&1; then
            break
        fi
        sleep 3
    done
    log "harbor-gateway: 宿主经 extraPortMappings 443 -> nodePort 30443 直达（无 port-forward）; 节点经 CoreDNS 解析在集群内直达"
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
    ensure_harbor_pass
    ensure_harbor_project
    sdp_login "${HARBOR_REGISTRY}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" >/dev/null 2>&1 || true
    # 平台依赖镜像先推 harbor（postgres / keycloak），三个组件镜像稍后由本脚本经节点推（build.sh 只构建不推送）
    push_image_to_harbor "postgres:16-alpine"
    push_image_to_harbor "quay.io/keycloak/keycloak:26.7.4"
    log "harbor ready: https://${HARBOR_REGISTRY} (admin)"
}

# ---- 阶段 3/5: images（三组件构建 + 推 harbor） ----
stage_images() {
    # 4. 构建三组件镜像（build.sh 只构建 + docker save，不推送；镜像推送统一见下方 node_push_to_harbor 循环）
    BUILD_LOG_DIR="$ROOT/.logs"; mkdir -p "$BUILD_LOG_DIR"
    for comp in hub runner console; do
        mod_dir="$ROOT/software-distribution-platform-${comp}"
        local_img="software-distribution-platform-${comp}:${VERSION}"
        # 重建前清理同版本号旧镜像：否则 build.sh 不会重新打包最新源码，推送/部署后节点
        # （imagePullPolicy: Always）仍拉到旧 digest，改码不生效。
        if sdp_inspect "$local_img" >/dev/null 2>&1; then
            log "cleaning stale local image ${local_img} before rebuild"
            case "${SDP_RUNTIME}" in
                docker)  docker rmi "$local_img" >/dev/null 2>&1 \
                    || log "WARN: 移除旧镜像 ${local_img} 失败（build 将覆盖该 tag，继续）" ;;
                nerdctl) nerdctl rmi "$local_img" >/dev/null 2>&1 \
                    || log "WARN: 移除旧镜像 ${local_img} 失败（build 将覆盖该 tag，继续）" ;;
            esac
        fi
        log "building ${comp} (this may take a few minutes)"
        blog="$BUILD_LOG_DIR/build-${comp}.log"
        if ! ( cd "$mod_dir" && "$mod_dir/build/${comp}/build.sh" "$VERSION" ) >"$blog" 2>&1; then
            log "FATAL: ${comp} 构建失败，日志尾部如下（完整: ${blog}）:"
            tail -n 30 "$blog" | sed 's/^/    | /' >&2; exit 1
        fi
        log "${comp} built ok (log: $blog)"
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
       && kubectl -n "$NS" get secret console-ingress-tls >/dev/null 2>&1 \
       && kubectl -n "$NS" get secret hub-tls >/dev/null 2>&1 \
       && kubectl -n "$NS" get secret hub-keycloak-tls >/dev/null 2>&1; then
        log "TLS secrets present (console-tls / console-ingress-tls / hub-tls / hub-keycloak-tls), reused"
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
        # hub-tls：hub 容器挂 /etc/hub-tls + BackendTLSPolicy CA 校验用，与 console-tls 同构（generic 三 key）。
        kubectl -n "$NS" create secret generic hub-tls \
            --from-file=ca.crt="$ENV_DIR/cert-build/certs/ca.crt" \
            --from-file=server.crt="$ENV_DIR/cert-build/certs/hub.crt" \
            --from-file=server.key="$ENV_DIR/cert-build/certs/hub.key" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        # hub-keycloak-tls：keycloak 容器挂 /etc/keycloak-tls + BackendTLSPolicy CA 校验用；
        # keycloakx 约定用 tls.crt/tls.key 文件名（见 hub values.yaml 的 keycloak.extraEnv）。
        kubectl -n "$NS" create secret generic hub-keycloak-tls \
            --from-file=ca.crt="$ENV_DIR/cert-build/certs/ca.crt" \
            --from-file=tls.crt="$ENV_DIR/cert-build/certs/hub-keycloak-http.crt" \
            --from-file=tls.key="$ENV_DIR/cert-build/certs/hub-keycloak-http.key" \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        log "TLS secrets created (console-ingress-tls / console-tls / hub-tls / hub-keycloak-tls) from self-signed certs"
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
    # 固定 nodePort：EG 从 CRD 无法声明固定 nodePort 值，svc 由 EG 创建时落随机端口，须 patch 成
    # kind.yaml extraPortMappings 对应的 31800/31843（实测 EG 不回改）。幂等：重复 patch 同值无副作用。
    # 注意 kube-proxy 同步有秒级延迟，patch 后下方健康检查循环自带重试窗口。
    kubectl -n "$ENVOY_SVC_NS" patch "svc/$ENVOY_SVC" --type=merge \
        -p '{"spec":{"ports":[{"name":"http-80","port":80,"protocol":"TCP","nodePort":31800},{"name":"https-8443","port":8443,"protocol":"TCP","nodePort":31843}]}}' >/dev/null
    # 等待宿主 8443 可用（extraPortMappings -> 节点 31843 -> svc）
    for i in $(seq 1 30); do
        if curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 "https://${SDP_GATEWAY_DOMAIN}:8443/" \
            >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    ENVOY_IP=$(kubectl -n "$ENVOY_SVC_NS" get "svc/$ENVOY_SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    log "envoy svc ready ($ENVOY_SVC_NS/$ENVOY_SVC clusterIP=${ENVOY_IP:-<unset>}); host exposed via extraPortMappings 8443->31843 8082->31800"
    # 集群内 pod（hub 校验 JWKS / runner 回连）也要能解析平台入口域名：
    # CoreDNS rewrite ${SDP_GATEWAY_DOMAIN} -> sdp-gateway envoy svc 集群 DNS 名。
    patch_coredns_rewrite "${SDP_GATEWAY_DOMAIN}" "${ENVOY_SVC}.${ENVOY_SVC_NS}.svc.cluster.local"
    save_state
}

# ---- 阶段 5/5: components（hub/runner/console 部署 + target 注册 + 握手验证） ----
# ---------- KC26 内置缺陷补丁（幂等）：account client 补 aud=account audience mapper ----------
# 自动创建的 `account` client 没有 aud=account 的 audience mapper（roles scope 的
# audience-resolve 会排除 token 自身 client），account 控制台自身 token aud=null →
# 其全部 REST API 401，浏览器症状为控制台顶部 "Server responded with an invalid
# status" 红条。经 master admin API 查重后补；已存在则跳过（mapper 落 DB，KC 重启不丢）。
patch_account_audience() {
    local base="https://${SDP_GATEWAY_DOMAIN}:8443/keycloak"
    local mt auuid code mlist
    mt=$(curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 --max-time 10 \
        "$base/realms/master/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=admin-cli \
        -d username=admin -d password='sdp@12345' 2>/dev/null \
        | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p') || true
    if [ -z "$mt" ]; then
        log "WARN: master admin token 获取失败，跳过 account audience 补丁（account 控制台将不可用）"
        return 0
    fi
    auuid=$(curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 --max-time 10 \
        -H "Authorization: Bearer $mt" \
        "$base/admin/realms/sdp/clients?clientId=account" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d[0]["id"] if d else "")
except Exception:
    pass') || true
    if [ -z "${auuid:-}" ]; then
        log "WARN: account client 未找到，跳过 audience 补丁"
        return 0
    fi
    local exists="n"
    exists=$(curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 --max-time 10 \
        -H "Authorization: Bearer $mt" \
        "$base/admin/realms/sdp/clients/$auuid/protocol-mappers/models" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    ms=json.load(sys.stdin)
    print("y" if any(m.get("name")=="account audience" for m in ms) else "n")
except Exception:
    print("n")') || true
    if [ "$exists" = "y" ]; then
        log "account audience mapper 已存在（幂等跳过）"
        return 0
    fi
    code=$(curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 --max-time 10 \
        -o /dev/null -w '%{http_code}' \
        -X POST -H "Authorization: Bearer $mt" -H "Content-Type: application/json" \
        -d '{"name":"account audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","consentRequired":false,"config":{"included.client.audience":"account","access.token.claim":"true"}}' \
        "$base/admin/realms/sdp/clients/$auuid/protocol-mappers/models" 2>/dev/null) || code="000"
    if [ "$code" = "201" ]; then
        log "account audience mapper 已补（KC26.7.4 内置缺陷，缺它 account 控制台 API 全 401）"
    else
        log "WARN: account audience mapper 创建失败 (HTTP $code) —— account 控制台将不可用，重跑本段可补"
    fi
}

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
    HUB_HELM_ARGS=(--set image.imageAddr="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/software-distribution-platform-hub:${VERSION}" --set image.imagePullPolicy=Always)
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

    # 8.5 account 控制台可用性补丁（幂等，见函数头注释）
    if [ -z "${SKIP_AUTH:-}" ]; then
        patch_account_audience
    fi

    # 9. 注册接入目标（幂等）。auth ON：先经 sdp-console password grant（admin 用户）换 token，
    #    再带 Bearer 注册 —— hub 侧 POST /targets 无 RBAC 门槛（main.go M1 wiring），
    #    部署后 target 即就位，runner 握手无需人工登录 console 建目标。
    #    访问面：宿主 8443 由 kind extraPortMappings 常驻（docker-proxy 随集群存活），注册窗口无需自建转发。
    #    循环内条件一律显式 if：`[ ... ] && break` 空值时整行非零会被 set -e 秒杀。
    gw_probe() {
        curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 -o /dev/null --max-time 3 \
            "https://${SDP_GATEWAY_DOMAIN}:8443/api/v1/targets" 2>/dev/null
    }
    REG_PAYLOAD='{"name":"local-dev","vendor":"kind","region":"local"}'
    REG_CODE=""
    for i in 1 2 3 4 5; do
        if gw_probe; then break; fi
        if [ "$i" = "5" ]; then REG_CODE="no-access"; fi
        sleep 1
    done
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
                # admin 挂了 UPDATE_PASSWORD requiredAction（首登强制改密，设计内）时，
                # password grant 恒 400 "Account is not fully set up"——区分提示，避免误判成
                # keycloak/secret 故障去白排查。
                if printf '%s' "$(cat "$KC_RESP_FILE" 2>/dev/null)" | grep -q 'Account is not fully set up'; then
                    log "WARN: admin 未完成首登改密（UPDATE_PASSWORD 生效中，设计内）——bootstrap 无法用 admin password grant"
                    log "       target 未注册；runner 握手前须先在 console 完成 admin 首登改密并建 target，或完成改密后重跑本段"
                fi
            fi
        fi
    fi
    case "$REG_CODE" in
        200|201)   log "target registered: local-dev (HTTP $REG_CODE)" ;;
        409)       log "target local-dev already exists (HTTP 409) - ok" ;;
        no-access) log "WARN: 宿主 8443 不可达（kind extraPortMappings 链路不通）—— 检查集群/envoy 状态后重跑本段" ;;
        no-token)  log "WARN: keycloak token 获取失败 (HTTP ${KC_CODE:-?})，响应见 ${KC_RESP_FILE}；检查 keycloak 是否 ready、sdp-backend secret 是否与 realm 预置一致" ;;
        000)       log "WARN: 注册请求连不通 (HTTP 000) —— 访问面在注册窗口内断连，重跑本段即可" ;;
        401|403)   log "WARN: target 注册被拒 (HTTP $REG_CODE) —— token 无效或 hub 侧拒绝" ;;
        *)         log "WARN: register target failed (HTTP $REG_CODE)" ;;
    esac

    # 8.5 (§8c) 尽力而为：开放 sdp-backend 的 token-exchange 权限给 sdp-console，
    # 使 Flow B 的 LoginClientImpersonate（RFC 8693 二次签发资源客户端令牌）可换到
    # sdp-backend 令牌。失败仅 WARN 不阻断部署（handler 侧 impersonate 已是尽力而为回退）。
    if [ -z "${SKIP_AUTH:-}" ]; then
      KC_TE_RESP=/tmp/sdp-te.json
      TE_TOKEN=""
      for attempt in 1 2 3; do
        TE_CODE=$(curl -s -k --resolve ${SDP_GATEWAY_DOMAIN}:8443:127.0.0.1 -o "$KC_TE_RESP" -w '%{http_code}' \
          -X POST "https://${SDP_GATEWAY_DOMAIN}:8443/keycloak/realms/sdp/protocol/openid-connect/token" \
          -H "Content-Type: application/x-www-form-urlencoded" \
          -d 'grant_type=password&client_id=sdp-console&username=admin&password=sdp@12345' 2>/dev/null) || TE_CODE="000"
        if [ "$TE_CODE" != "000" ]; then
          TE_TOKEN=$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' "$KC_TE_RESP" 2>/dev/null || true)
        fi
        [ -n "$TE_TOKEN" ] && break
        [ "$attempt" != "3" ] && sleep 3
      done
      if [ -z "$TE_TOKEN" ]; then
        log "WARN: §8c token-exchange 补丁跳过（admin token 获取失败；完成 admin 首登改密后重跑本段即可）"
      else
        KC_ADM="https://${SDP_GATEWAY_DOMAIN}:8443/keycloak/admin/realms/sdp"
        BE=$(curl -s -k -H "Authorization: Bearer $TE_TOKEN" "$KC_ADM/clients?clientId=sdp-backend" 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
        CO=$(curl -s -k -H "Authorization: Bearer $TE_TOKEN" "$KC_ADM/clients?clientId=sdp-console" 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
        if [ -n "$BE" ] && [ -n "$CO" ]; then
          curl -s -k -o /dev/null -X PUT "$KC_ADM/clients/$BE/management/permissions" -H "Authorization: Bearer $TE_TOKEN" -H "Content-Type: application/json" -d '{"enabled":true}' 2>/dev/null || true
          SCOPE_PERM=$(curl -s -k -H "Authorization: Bearer $TE_TOKEN" "$KC_ADM/clients/$BE/management/permissions" 2>/dev/null | sed -n 's/.*"token-exchange":"\([^"]*\)".*/\1/p' | head -1)
          if [ -n "$SCOPE_PERM" ]; then
            POLICY_ID=$(curl -s -k -X POST "$KC_ADM/clients/$BE/authz/resource-server/policy/client-scope" -H "Authorization: Bearer $TE_TOKEN" -H "Content-Type: application/json" -d "{\"name\":\"sdp-console-token-exchange\",\"clients\":[\"$CO\"]}" 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
            if [ -n "$POLICY_ID" ]; then
              curl -s -k -o /dev/null -X PUT "$KC_ADM/clients/$BE/authz/resource-server/scope/$SCOPE_PERM" -H "Authorization: Bearer $TE_TOKEN" -H "Content-Type: application/json" -d "{\"id\":\"$SCOPE_PERM\",\"policies\":[{\"id\":\"$POLICY_ID\"}]}" 2>/dev/null || true
              log "§8c token-exchange 权限已开放（sdp-console -> sdp-backend）"
            else
              log "WARN: §8c token-exchange 补丁部分完成（client policy 创建失败，可重跑本段）"
            fi
          else
            log "WARN: §8c token-exchange 补丁跳过（token-exchange scope permission 未就绪，可重跑本段）"
          fi
        else
          log "WARN: §8c token-exchange 补丁跳过（无法解析 sdp-backend/sdp-console client id）"
        fi
      fi
    fi

    # 10. runner（image 从 harbor）
    "$HELM" upgrade --install runner "$RUNNER_DIR/build/runner/charts/software-distribution-platform-runner" \
        -n "$NS" --set image.imageAddr="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/software-distribution-platform-runner:${VERSION}" --set image.imagePullPolicy=Always
    # 同版本号重建后强制重启触发 re-pull：脚本注入 imagePullPolicy=Always 强拉同 tag 新 digest
    # （chart 默认 IfNotPresent 生产友好；此处覆盖为 Always 仅服务本地同号迭代，image 字符串未变时 helm
    # upgrade 不触发滚动更新，否则旧镜像继续运行）。
    kubectl -n "$NS" rollout restart deploy/runner
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
    CONSOLE_HELM_ARGS=(--set image.imageAddr="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/software-distribution-platform-console:${VERSION}" --set image.imagePullPolicy=Always)
    if [ ${#AUTH_SETS_CONSOLE[@]} -gt 0 ]; then CONSOLE_HELM_ARGS+=("${AUTH_SETS_CONSOLE[@]}"); fi
    "$HELM" upgrade --install console "$CONSOLE_DIR/build/console/charts/software-distribution-platform-console" \
        -n "$NS" "${CONSOLE_HELM_ARGS[@]}"
    kubectl -n "$NS" rollout restart deploy/console
    kubectl -n "$NS" rollout status deploy/console --timeout=180s
    log "console ready"

    # hub 同版本号重建后也需重启触发 re-pull：本地覆盖 imagePullPolicy=Always 强拉同 tag 新 digest
    # （chart 默认 IfNotPresent；helm upgrade 因 image 字符串未变不触发滚动更新）。
    kubectl -n "$NS" rollout restart deploy/hub
    kubectl -n "$NS" rollout status deploy/hub --timeout=240s
    log "hub re-pulled (local override: imagePullPolicy=Always)"

    # 12. 网关握手验证
    OK=""
    for i in $(seq 1 15); do
        if kubectl -n "$NS" logs deploy/hub --tail=50 2>/dev/null | grep -qi "connected"; then OK=1; break; fi
        sleep 3
    done
    [ -n "$OK" ] && log "gateway handshake OK" || log "WARN: handshake not seen in 45s"

    log "=========================================="
    log "console: https://${SDP_GATEWAY_DOMAIN}:8443  (自签证书 curl -k / 浏览器信任 ca.crt)"
    log "harbor:  https://${HARBOR_REGISTRY}    (admin)"
    log "hub:     https://${SDP_GATEWAY_DOMAIN}:8443/api/v1"
    log "集群:    kind sdp-dev | namespace: $NS | 版本: $VERSION"
    log "=========================================="
}

# ---------- preflight（部署前静态自检：秒级拦住环境类失败；只查可静态判定项，不预测运行态） ----------
preflight() {
    # 1) docker daemon 探活：Mac 睡眠恢复后 VM 可能 soft lockup（症状会伪装成 pod/网络问题）。
    #    macOS 无 timeout(1)，用系统自带 perl alarm 兜底；只提示+终止，不自动重启 Docker。
    if ! perl -e 'alarm 8; exec @ARGV' docker ps -q >/dev/null 2>&1; then
        log "FATAL: docker daemon 无响应（8s）—— Mac 睡眠后 VM 僵死的典型症状；请重启 Docker Desktop 后重跑"
        exit 1
    fi
    # 2) kind 二进制：PATH 与 ~/.workbuddy 下可能各有一个（版本不同、schema 行为有差），打印实际用的那个。
    command -v "$KIND" >/dev/null 2>&1 || { log "FATAL: 未找到 kind: $KIND"; exit 1; }
    log "kind: $("$KIND" version 2>/dev/null | head -1) ($(command -v "$KIND"))"
    # 3) 离线镜像缓存齐全性（关键路径子集）：缺了提示先跑 load-images.sh，不自动 load。
    local img miss=""
    for img in kindest/node:v1.27.3 registry:2 \
        envoyproxy/gateway:v1.6.1 envoyproxy/envoy:distroless-v1.36.4 \
        quay.io/keycloak/keycloak:26.7.4 postgres:16-alpine \
        bitnamilegacy/harbor-core:2.13.2-debian-12-r3 bitnamilegacy/nginx:1.29.1-debian-12-r0; do
        docker image inspect "$img" >/dev/null 2>&1 || miss="$miss $img"
    done
    if [ -n "$miss" ]; then
        log "FATAL: 宿主 docker 缺少镜像:${miss}"
        log "       先执行 ./load-images.sh 回灌离线缓存（images/），再重跑"
        exit 1
    fi
    # 4) 宿主端口 8443/8082/443 须空闲或仅由 docker-proxy 持有（extraPortMappings 发布口）；
    #    lsof 受权限限制看不到时 fail-open（持有者列空则放行）。
    local port holder
    for port in 8443 8082 443; do
        # lsof 退出码 1 = 端口空闲（健康态）；set -o pipefail 下该管道非零会触发 set -e 误杀，须 || true 兜底。
        # lsof 的 COMMAND 列截断到 9 字符：com.docker.backend 显示为 com.docke，排除须按前缀匹配。
        holder=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1 !~ /^com\.dock/ && $1 !~ /^docker/ {print $1; found=1}' | head -1) || true
        if [ -n "$holder" ]; then
            log "FATAL: 宿主端口 $port 已被 ${holder} 占用（须空闲或仅 docker-proxy 持有）；先停掉占用进程再重跑"
            exit 1
        fi
    done
    log "preflight OK"
}

# ---------- 阶段计时包装 ----------
T0_TOTAL=$SECONDS
run_stage() {
    local s="$1" t0=$SECONDS
    shift
    "$@"
    log "[stage $s] $((SECONDS - t0))s"
}

# ---------- 分发 ----------
preflight
if [ -n "$STAGE" ]; then
    # 单段模式：自动补齐幂等轻量前置（ensure_kind 导出 kubeconfig 供 kubectl 使用）
    ensure_helm
    ensure_kind
    case "$STAGE" in
        infra|harbor) ensure_registry ;;   # 两段依赖 localhost:5000 bootstrap registry
    esac
    case "$STAGE" in
        infra)      run_stage infra stage_infra ;;
        harbor)     run_stage harbor stage_harbor ;;
        images)     run_stage images stage_images ;;
        platform)   run_stage platform stage_platform ;;
        components) run_stage components stage_components ;;
    esac
    exit 0
fi

# 全量部署（人类默认路径；顺序 = 依赖顺序，与阶段化之前行为一致）
run_stage infra stage_infra
run_stage harbor stage_harbor
run_stage images stage_images
run_stage platform stage_platform
run_stage components stage_components
log "[stage all] 总耗时 $((SECONDS - T0_TOTAL))s"
