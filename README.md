# software-distribution-platform-env

环境周边依赖清单（可替代）

> 本目录（`software-distribution-platform-env`）收口"平台周边部署脚手架与本地联调基础设施"，
> **不随 hub/runner/console 三仓打包**；各组件 chart 只按名字引用这里的 Gateway 等网关级资源。

## 0. local kind vs cloud 一页对照

本仓有两套部署拓扑，先按下表选一套再读对应 README。差异项的判定方法与逐项落定结果见 docs 仓 `plans/FIDELITY-KIND-VS-CLOUD-2026-10-09.md`；验收状态见 docs 仓 `plans/STATUS.md`。

| 维度 | local kind（`local-kind-dev/`） | cloud（`prod-deplyment/`，CCE 托管 K8s） |
| --- | --- | --- |
| 定位 | 开发迭代、日常 E2E、helm 渲染与镜像构建验证 | 里程碑 / 发布前验收 gate；多节点、真 DNS、真证书、真 LB、canary 真流量 |
| 镜像仓库 | 集群内自建 harbor（`harbor.sdpworkflow.com`，443 无端口）；节点 containerd mirror + CoreDNS rewrite 集群内直达 harbor 网关 ClusterIP；`localhost:5000` 仅作 bootstrap 中转 | 默认集群内自建 harbor（ELB 443 暴露）；也可走 `deploy-without-harbor.sh` 直推外部 OCI registry（如 SWR），此时不需要 harbor 网关与 harbor 内网 DNS |
| 平台入口网关 | 社区版 Envoy Gateway（helm chart `envoy-gateway-helm-v1.6.1.tgz`），数据面 svc 为 NodePort + kind `extraPortMappings`；平台入口 `https://www.sdpworkflow.com:8443`，harbor 走 443 | CCE 官方「Envoy Gateway」插件（GatewayClass `envoy-gateway`），按 Gateway listener 自动创建独享 ELB，平台 https listener = **443**；自建 EG 数据面为 ClusterIP、云上无 LB，禁用 |
| EG 插件来源 | `helm pull envoyproxy/gateway-helm --version 1.6.1`（社区 chart，二进制不入库，部署前拉取） | 云控制台安装的 CCE 官方插件，不装社区 chart；yaml 见 `gateway-sdp-cce.yaml` / `gateway-harbor-cce.yaml` |
| DNS / CoreDNS | 节点 `/etc/resolv.conf` 前置 CoreDNS（10.96.0.10），`rewrite name harbor.sdpworkflow.com` → harbor 网关 ClusterIP；不依赖宿主进程 | 真内网 DNS：`harbor.sdpworkflow.com` / `www.sdpworkflow.com` 分别指向两个 ELB IP；无 rewrite |
| 证书入口 | `cert-build/cert-create.sh` 自签 CA（`*.sdpworkflow.com`）+ 手动信任（节点 `insecure-registries` 或安装 ca.crt 为系统信任根）；`harbor-tls` / `console-ingress-tls` 等 secret；不装 cert-manager | 自签 CA 经 privileged DaemonSet `harbor-ca-trust` 分发全节点并重启 containerd，网关 TLS 终结处配 4 个 TLS secret；正规 CA 消除分发为后续项；不装 cert-manager |
| 重建成本 | 改了 `deploy/kind.yaml`（mirror / 端口映射）必须重建集群，镜像离线缓存在 `images/` | 部署脚本幂等；清理默认可逆（保留 ns/PVC），删数据须显式 `--delete-namespace` / `--delete-pvc` |

### 何时选哪条（决策树）

```
你要做什么？
├─ 改代码 / 跑日常 E2E / 看 helm 渲染 / 构建镜像
│   └─ 选 local kind：读 local-kind-dev/README.md
│       └─ 离线环境先 load-images.sh；改过 kind.yaml 必须重建集群
├─ 发布前验收 / canary 真流量 / 多节点调度与 PV / 真 DNS / 真证书链 / ELB 行为
│   └─ 选 cloud：读 prod-deplyment/README.md
│       ├─ 用集群内 harbor → hce-2.0-64bit-deploy.sh（镜像先入 harbor）
│       └─ 用外部 OCI registry（SWR 等）→ deploy-without-harbor.sh
│           （不需要 harbor 网关、harbor-tls、harbor 内网 DNS 与节点 CA 分发）
└─ 只想搞清两套拓扑差在哪
    └─ 读 docs/plans/FIDELITY-KIND-VS-CLOUD-2026-10-09.md
```

> 云上验收脚本（`e2e-smoke.sh` / `e2e-cancel-rerun.sh` / `e2e-canary.sh`）真源在本仓 `prod-deplyment/`，云上节点直跑；结果状态见 docs 仓 `plans/STATUS.md`。

本地开发（一键部署 / 清理脚本）
- `local-kind-dev/`：从工作区根迁来的 5 个本地联调脚本
  - `deploy-local.sh`      本地一键部署三组件（+ postgres / keycloak / gateway）
  - `undeploy-local.sh`    全量卸载（与 deploy 配对）
  - `teardown-local.sh`    彻底清理（clean --deep + 集群卸载 + docker 资源）
  - `clean-local.sh`       工作区级清理（停服务 + 三仓生成物）
  - `stop-dev.sh`          结束本地联调进程
  - 脚本 `ROOT` 重定义为上两级（工作区根），互相调用用 `$SCRIPT_DIR`；详见各脚本头注释。

证书生成
- `cert-build/`
  - `cert-create.sh`         统一证书生成器（自签 CA + 各组件 server/client 证书，
                             `kubectl create secret ... --dry-run=client -o yaml` 产物落 `certs/*-server-secret.yaml` / `*-client-secret.yaml`）
  - `self-signed-ca-cert.sh` 底层 openssl 封装（CA 仅生成一次、跨组件共用）
  - 证书链与消费契约见 `docs/shared/CERTIFICATES.md`

云上生产部署（`prod-deplyment/`）
- 面向云上托管 K8s（CCE 等）的构建环境就绪与平台部署脚手架，详见 `prod-deplyment/README.md`。
- `deploy-without-harbor.sh`：云上一键部署（无需安装 harbor）——证书 + TLS secret 前置 → 平台网关 → Envoy proxy 资源收敛 → 默认 SC 预检 → 把组件包直推任意 OCI registry（如 SWR）并 helm 安装。
- `run.sh`：部署运行入口（组件包 → 推镜像 → helm install），被 `deploy-without-harbor.sh` 委托。
- `hce-2.0-64bit-*.sh`：CCE 节点环境就绪与「依赖 harbor」的旧部署路径（镜像须先入 harbor）。

本地测试基础设施（yaml；归 `local-kind-dev/deploy/`，随 env 仓一起跟踪）
- `local-kind-dev/deploy/` 含：
  - `gateway-sdp.yaml`    Gateway 级资源（GatewayClass / EnvoyProxy / Gateway，http / https listener）
  - `kind.yaml`           kind 单节点集群定义（含 envoy / gateway 端口映射）
  - `envoy-gateway-helm-v1.6.1.tgz`  EG controller helm chart（第三方二进制，**已 gitignore，不入库**，见下方获取方式）
- **是否入库（分类）**：
  - `gateway-sdp.yaml` / `kind.yaml` 为**手写 IaC**，纳入版本控制（随 env 仓跟踪）；
  - `envoy-gateway-helm-v1.6.1.tgz` 是**第三方 helm chart 二进制（~427KB）**，**不入库**（`env/.gitignore` 已忽略 `local-kind-dev/deploy/*.tgz`）。
    - 获取方式（首次部署前，二选一）：
      - `helm pull envoyproxy/gateway-helm --version 1.6.1 --untar=false --filename local-kind-dev/deploy/envoy-gateway-helm-v1.6.1.tgz`
      - 或前往 https://github.com/envoyproxy/gateway/releases/tag/v1.6.1 下载 `gateway-helm-v1.6.1.tgz`，重命名为 `envoy-gateway-helm-v1.6.1.tgz` 放入 `local-kind-dev/deploy/`。

不入库清单（`.gitignore` 节选提示，非穷举：以下为需人工知晓的非显然项；完整忽略规则以根 `.gitignore` 为准，二者非镜像关系）
- `.DS_Store`（macOS 系统文件）
- 第三方 helm chart 二进制：`local-kind-dev/deploy/*.tgz`（envoy-gateway-helm）、`harbor/*.tgz`（bitnamicharts/harbor 27.0.3）
- 证书生成产物 `cert-build/certs/`：`cert-create.sh` 运行期生成，含 `ca.key` 等私钥，**绝不入库**
- `harbor/harbor-secrets.txt`：harbor 固定密钥记录（CORE_SECRET 等），**绝不入库**，仅本地保存、helm upgrade 时引用
- 外部参考材料：`envoygateway/`（EG 官方命令速查 + examples/ 官方 coffee 示例）、`harbor/harbor-command-guide.txt`（安装/命令笔记，含明文口令；正式 values 以 `harbor/values.yaml` 为准）

在 k8s 中 helm 部署
- envoy gateway（chart 本地 vendor 或从 registry 拉）
- harbor（已落地：集群内 registry，由 `local-kind-dev/deploy-local.sh` 核心步骤安装——harbor 先行于平台组件（脚本 harbor 段）；`cert-create.sh` 组件列表含 harbor，产出 `harbor-server-secret` / `harbor-client-secret` 供集群内消费；网关对外 TLS Secret `harbor-tls` 由 `deploy-local.sh` 单独 `create secret tls` 生成）
- keycloak（已集成到 hub chart，随 hub 安装）
- cert-manager：**不安装**，证书自导入

测试 / 开发环境工作负载部署（helm 部署均可）；生产环境必须高可用、非容器
- postgresql
