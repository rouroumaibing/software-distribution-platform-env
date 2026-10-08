# 本地 kind 部署脚手架（local-kind-dev）

本地一键部署三组件（hub / runner / console）到 kind 集群，**镜像统一走 harbor**；镜像与域名访问统一标准 443、不带显式端口（harbor 及镜像引用），sdp 业务网关例外走 8443（见第二节）。
脚本与本地测试基础设施（kind 定义、Envoy Gateway、harbor）都在此目录，**不随 hub/runner/console 三仓打包**。

---

## 一、任务逻辑（顺序：先周边服务，后组件）

```
1. 本地 registry（localhost:5000）        —— 仅作 bootstrap 中转（见第三节），不承载平台 pod 镜像
2. kind 集群（sdp-dev）                   —— 节点 containerd 配 harbor mirror + 集群 DNS 解析（CoreDNS）
3. 周边服务先行：
   a. envoy-gateway 控制面（eg controller）
   b. harbor（集群内镜像仓库，经 **独立** Envoy 网关暴露为 https://harbor.sdpworkflow.com 标准 443）
      —— harbor 的网关资源（GatewayClass `harbor-eg` + EnvoyProxy `harbor-eg` + Gateway
         `harbor-gateway` + HTTPRoute）**全部自带于 `harbor/harbor-gateway.yaml`**，
         **不复用 sdp 的网关基础设施**（`gateway-sdp.yaml` / `sdp-eg`），两者各自独立、互不耦合。
         脚本在 harbor 段直接 apply 该文件即可，无需先建 sdp 网关。
      → 建 sdp 项目、把 postgres / keycloak 镜像推到 harbor
   c. （后续第 7 步）平台入口 sdp-gateway（GatewayClass `sdp-eg`，用于 console / keycloak / hub API，
      端口 8443）—— 与 harbor 网关完全独立，各自一套 GatewayClass + EnvoyProxy。
4. 构建三组件镜像并推到 harbor（build.sh 构建产物统一经 node_push_to_harbor 节点侧兜底重推进 harbor.sdpworkflow.com）
5. postgres / keycloak / hub / runner / console 全部从 harbor 拉镜像部署
```

要点：

- **harbor 先于 postgres 等平台组件安装（但后于 envoy-gateway 控制面）**，实际顺序：registry → kind → envoy 控制面 → harbor → postgres/keycloak 镜像入 harbor → 三组件镜像 → postgres 部署 → sdp-gateway → hub/runner/console（见 `deploy-local.sh`）。因为所有平台镜像都从 harbor 拉取（对应生产"先有镜像仓库，再有服务"的顺序）。
- **镜像流转**：
  - `localhost:5000` **仅**承接 harbor 自身镜像（`bitnamilegacy/*`）与 envoy 控制面/数据面镜像——这些是 harbor 还没起来、节点又拉不动 `docker.io` 时的 bootstrap 源，**任何平台 pod 都不从它拉镜像**。
  - `harbor.sdpworkflow.com/sdp/*` 是 hub / runner / console / keycloak / postgres 的唯一仓库，全部经网关 443 拉取。
- **节点拉 harbor 的链路（与生产一致：节点经 Gateway 域名拉镜像）**：kind 节点 containerd 配 `harbor.sdpworkflow.com` mirror（insecure_skip_verify + basic auth）→ 节点 `/etc/resolv.conf` 前置 CoreDNS（10.96.0.10）→ CoreDNS 经 `rewrite name harbor.sdpworkflow.com` 把域名解析到 **harbor 网关 ClusterIP** → 节点在集群内直达 harbor 的 envoy 数据面 svc。`harbor.sdpworkflow.com` 不写任何 IP、不依赖宿主任何进程（宿主 port-forward 443 仅供宿主 `docker push` / 浏览器）。镜像拉取路径全程不带端口、零改动。

---

## 二、端口与域名约定（443 优先）

所有**域名访问 / 镜像引用都不带端口号**，走标准 HTTPS 443：

| 域名 | 用途 | 暴露方式 |
|------|------|----------|
| `https://harbor.sdpworkflow.com` | 镜像仓库（平台镜像唯一仓库） | 宿主 `sudo kubectl port-forward 443:443`（harbor envoy ClusterIP svc，仅供宿主 docker push / 浏览器）；**节点不经此转发**，节点经集群 DNS（CoreDNS rewrite）解析到网关 ClusterIP 在集群内直达 |
| `https://www.sdpworkflow.com:8443` | 平台入口（console / keycloak / hub API） | 宿主 `kubectl port-forward 8443:8443 8082:80`（sdp envoy ClusterIP svc） |

> sdp 网关仍用 `:8443`（2026-09-23 既定：与 Keycloak issuer / 浏览器访问端口三方一致）。
> 若要 sdp 也改 443，需把两个网关合并为一个 Envoy 并修正 TLS secret 命名（`console-ingress-tls` 当前由 gateway 引用、但 cert 脚本产出的是 `console-server-secret`），属于独立一轮改造，**本脚手架未做**。

网关数据面**均为 ClusterIP、不写死端口**（harbor / sdp 各一套独立 GatewayClass + EnvoyProxy）；**端口号不进任何域名/镜像引用**。宿主访问统一由 `deploy-local.sh` 起 `kubectl port-forward` 暴露（不使用 kind `extraPortMappings`，避免改端口就要 recreate 集群）。停转发用 `./stop-dev.sh kill`。

---

## 三、前置约束（运行前必须满足）

> ⚠️ **必须重建 kind 集群**：本脚手架改了 `deploy/kind.yaml`（节点 containerd mirror + 端口映射），旧集群不会生效。
> 先 `kind delete cluster --name sdp-dev`（或跑 `undeploy-local.sh`），再 `./deploy-local.sh <version>`。

1. **工具链**：`docker` / `kind`（缺省取 `~/.workbuddy/binaries/bin/kind`）/ `helm`（缺省自动下载到 `.bin/helm`）/ `kubectl` 可用。
   - ⚠️ **kubectl 版本**：本脚手架对 Gateway API 资源（`gateway-sdp.yaml` / `harbor-gateway.yaml`）的 apply 用
     `--validate=false` 绕开旧版 kubectl 客户端对 `v1 Gateway spec.parametersRef` 的内置 schema 校验
     （apiserver 本身支持该字段，已 `kubectl apply --dry-run=server` 验证）。若 kubectl 较新可去掉；
     若极旧导致 `--validate=false` 后仍报未知字段，请升级 kubectl 至支持 Gateway API v1。
2. **宿主机 `/etc/hosts`**（脚本会尝试 `sudo` 写入，失败需手工补）：
   ```
   127.0.0.1 harbor.sdpworkflow.com
   127.0.0.1 www.sdpworkflow.com
   ```
   —— 宿主机 `docker push` 与浏览器访问靠它把域名解析到本机 443。
3. **docker daemon 信任 harbor**（自签证书）：
   - 在 `daemon.json` 加 `"insecure-registries": ["harbor.sdpworkflow.com"]` 并重启 docker；或
   - 把 `cert-build/certs/ca.crt` 安装为系统信任根 CA。
   否则 `docker login / push harbor.sdpworkflow.com` 会因证书不信任失败。
4. **harbor 凭据**：`admin / Admin@123`（与 `harbor/values.yaml` 的 `adminPassword` 一致）。
5. **证书**：`harbor.sdpworkflow.com` 的 TLS 证书由 `cert-build/cert-create.sh` 自签生成（SAN `*.sdpworkflow.com`），脚本首次运行会自动生成；可用 `SKIP_GEN_CERTS=1` 强制要求已存在。
6. **重建集群后**：脚本会自动经 CoreDNS `rewrite` 把 `harbor.sdpworkflow.com` 解析到 harbor 网关 ClusterIP（并前置节点 `/etc/resolv.conf` 指向 CoreDNS、清节点 `/etc/hosts` 陈旧条目），重启 containerd 使 mirror 生效。

---

## 四、运行方式

```bash
cd software-distribution-platform-env/local-kind-dev
./deploy-local.sh v0.0.1        # 版本须与 build.sh 构建出的版本一致
./deploy-local.sh stop           # 兼容空操作（console 经 ingress 访问，无本地进程可停）
```

### 可覆盖的环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `VERSION` | `v0.0.1` | 镜像 tag（位置参数同效） |
| `HARBOR_REGISTRY` | `harbor.sdpworkflow.com` | 仓库域名（443，无端口） |
| `HARBOR_PROJECT` | `sdp` | harbor 项目名 |
| `HARBOR_USER` / `HARBOR_PASS` | `admin` / `Admin@123` | 仓库凭据 |
| `SKIP_AUTH` | 空 | 设任意值则 hub/console 退回 dev 姿态（不开 Keycloak） |
| `SKIP_GEN_CERTS` | 空 | 设任意值则要求 TLS secret 已存在，缺失即失败 |

---

## 五、已知风险与验证要点（已实跑，下列为实测坑与已修项）

- **harbor 镜像名非法（已修）**：harbor chart 的 `image.repository` 若写成 `localhost:5000/bitnamilegacy/...`，
  chart 会自动补 `docker.io` 默认前缀拼成 `docker.io/localhost:5000/bitnamilegacy/...`，冒号被当成 tag 分隔符
  → 镜像名非法（`InvalidImageName`），pod 永远起不来。已在 `harbor/values.yaml` 用
  `global.imageRegistry: localhost:5000` + repository 只写 `bitnamilegacy/<name>` 修正（渲染验证 16 处全部
  为 `localhost:5000/bitnamilegacy/...`）。bootstrap 推送逻辑从渲染结果剥 `localhost:5000/` 前缀补 `docker.io`
  当源，二者自洽。
- **harbor-gateway kubectl 客户端校验失败**：`v1 Gateway spec.parametersRef` 服务端支持，但旧版
  kubectl 客户端内置 schema 不认 → apply 报 `unknown field`。两个 Gateway apply 均带 `--validate=false` 绕开。
- **节点拉 harbor 失败**：检查节点 `docker exec sdp-dev-control-plane getent hosts harbor.sdpworkflow.com` 是否解析到 harbor 网关 ClusterIP（经 CoreDNS）；必要时 `kubectl -n kube-system rollout restart deployment/coredns` 并 `docker exec ... systemctl restart containerd`。
- **harbor 网关不通**：确认 `deploy-local.sh` 已起 `sudo kubectl port-forward 443:443`（harbor envoy svc，绑定 0.0.0.0），且宿主 `443` 可达（`curl -sk https://harbor.sdpworkflow.com/api/v2.0/health`）；若转发进程被 kill，重新跑 `./deploy-local.sh` 或手工 `sudo kubectl -n harbor port-forward --address 0.0.0.0 svc/<harbor-envoy> 443:443`。
- **postgres / keycloak 镜像未进 harbor**：脚本在 harbor 就绪后自动 `push_image_to_harbor postgres:16-alpine` 与 `quay.io/keycloak/keycloak:26.7.4`；若跳过，pod 会 ImagePullBackOff。
- **（macOS Docker Desktop）宿主 `docker push` 可能连不上 host 侧 port-forward**：Docker Desktop 的 docker daemon 运行在独立 VM，与宿主 shell 的 `127.0.0.1` 不互通，导致 `docker push harbor.sdpworkflow.com/...`（经宿主 `/etc/hosts` + port-forward 443）报 `connection refused`。若遇此情况，可改用集群内推送（节点 `ctr images push --skip-verify --plain-http --user admin:Admin@123 harbor.harbor.svc.cluster.local/sdp/<img>:<tag>`，多架构镜像按 digest 推送单架构），或把 harbor 网关临时暴露为节点可达地址。脚本当前仍用宿主 docker push（与既往全量测试一致），请按本机环境验证。
- **sdp 网关 https 未 Programmed**：依赖 `console-ingress-tls`（网关引用名）已存在；若缺失，需确认 `cert-build` 产出与该命名的 secret 对齐（当前为已知历史不一致，未在本轮处理）。
- **重建集群会丢数据**：PVC 为本地测试数据，重建即弃；helm 会全量重装。
