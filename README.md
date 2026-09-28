# software-distribution-platform-env

环境周边依赖清单（可替代）

> 本目录（`software-distribution-platform-env`）收口"平台周边部署脚手架与本地联调基础设施"，
> **不随 hub/runner/console 三仓打包**；各组件 chart 只按名字引用这里的 Gateway 等网关级资源。

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

不入库清单（`.gitignore` 全量约定，2026-09-28 起）
- `.DS_Store`（macOS 系统文件）
- 第三方 helm chart 二进制：`local-kind-dev/deploy/*.tgz`（envoy-gateway-helm）、`harbor/*.tgz`（bitnamicharts/harbor 27.0.3）
- 证书生成产物 `cert-build/certs/`：`cert-create.sh` 运行期生成，含 `ca.key` 等私钥，**绝不入库**
- `harbor/harbor-secrets.txt`：harbor 固定密钥记录（CORE_SECRET 等），**绝不入库**，仅本地保存、helm upgrade 时引用
- 外部参考材料：`envoygateway/`（EG 官方命令速查 + examples/ 官方 coffee 示例）、`harbor/harbor-command-guide.txt`（安装/命令笔记，含明文口令；正式 values 以 `harbor/values.yaml` 为准）

在 k8s 中 helm 部署
- envoy gateway（chart 本地 vendor 或从 registry 拉）
- harbor（规划中：集群内 registry，已纳入 `cert-create.sh` 组件列表，证书名为 `harbor-tls`）
- keycloak（已集成到 hub chart，随 hub 安装）
- cert-manager：**不安装**，证书自导入

测试 / 开发环境工作负载部署（helm 部署均可）；生产环境必须高可用、非容器
- postgresql
