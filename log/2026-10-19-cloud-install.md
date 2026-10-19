# 2026-10-19 云上 CCE 环境安装 harbor / postgresql / envoygateway 操作记录

- 环境：华为云 CCE 托管 K8s，2×HCE 2.0 节点（192.168.0.43 / 192.168.0.145，v1.36.2，everest CSI）
- 入口：跳板机 `119.3.221.126:30033`（即节点 192.168.0.43）
- 依据：env 仓 `harbor/harbor-command-guide.txt`、`envoygateway/envoy-gateway.txt`、`local-kind-dev/deploy/gateway-sdp.yaml`
- 执行人：WorkBuddy（agent，经 SSH 直连跳板机操作）

## 时间线（时间为命令实际执行时刻，约 = 依据会话记录推算）

| 时间 | 动作 | 结果 |
|---|---|---|
| ~11:55 | skill 脚本连通性检查：BASTION_OK；首次 `kubectl get pods` 失败（KUBECTL_FAIL） | kubeconfig 当时未配置 |
| ~12:05 | 集群勘察：`get nodes/pods -A/storageclass/gatewayclass`、helm 探测 | 2 节点 Ready；helm 未装；无默认 SC；纯净集群；用户确认 kubeconfig 已配好 |
| ~12:07 | 出网探测（跳板机）：mirrors.huaweicloud.com=200、github=200、registry-1.docker.io=000 | docker.io 被墙，走 CCE 预置 SWR mirror |
| ~12:10 | 跳板机安装 helm v3.17.4（华为云镜像源） | OK |
| 12:22 | Mac 侧经 `docker.1panel.live` OCI 代理拉 bitnami postgresql chart 16.4.5 | OK（daocloud 挂起不可用） |
| 12:23 | scp 三 chart 上跳板机 `/root/sdp-charts/`：postgresql-16.4.5 / harbor-27.0.3 / envoy-gateway-helm-v1.6.1 | OK |
| 12:25 | 节点拉取实测：发现 CCE SWR mirror（certs.d/docker.io/hosts.toml）；`bitnamilegacy/postgresql:17.2.0-debian-12-r8` 可拉；`envoyproxy/envoy-gateway:v1.6.1`（错误仓名）400 | mirror 可用，400=tag/仓库不存在 |
| 12:28 | 批量预拉验证：EG 控制面 `envoyproxy/gateway:v1.6.1`、ratelimit、os-shell、bitnamilegacy postgres、busybox | 全部 OK |
| ~12:31 | `helm install eg`（envoy-gateway-system，controllerName=gateway.envoyproxy.io/gatewayclass-controller） | rollout 成功 |
| ~12:33 | 建 ns sdp-workflow + GatewayClass `sdp-eg` + EnvoyProxy `sdp-eg`（数据面用官方镜像 distroless-v1.36.4，去掉 kind 的 localhost:5000 钉版）；`envoy:distroless-v1.36.4` 拉取验证 | OK |
| 12:36 | postgresql 安装（ns sdp-workflow，fullnameOverride=postgres，auth sdp/sdp/sdp，20Gi）首次被镜像校验拦截 | 补 `global.security.allowInsecureImages=true` |
| ~12:40 | postgresql 重装 → sts `postgres` 就绪、PVC Bound（csi-disk）、`pg_isready` accepting、DSN 契约对齐 `postgres://sdp:sdp@postgres.sdp-workflow.svc:5432/sdp` | ✅ |
| 12:37–12:39 | harbor 全量 13 镜像预拉验证（bitnamilegacy/*）；redis-exporter 首次 context canceled，12:39 重试成功 | 全部 OK |
| ~12:41 | 上传 harbor 证书（cert-build/certs/harbor.crt/.key）→ 生成 harbor-values.yaml（bitnamilegacy 镜像 + 固定密钥）+ harbor-secrets.txt（chmod 600）；`helm install harbor` | 安装提交 |
| ~12:45 | 排查：harbor 内置 pg/redis PVC Pending（无默认 SC）→ `helm upgrade` 补 SC 失败（sts volumeClaimTemplates 不可 patch） | 半旧状态 |
| ~12:48 | `helm uninstall harbor`（registry 50Gi / jobservice / trivy PVC 因 resourcePolicy:keep 保留复用；删除 Pending 的 pg/redis PVC）→ 重装（`global.defaultStorageClass=csi-disk` + 子 chart persistence.storageClass） | PVC 全部 Bound |
| ~12:55 | harbor 8 pod 全部 Running；导入 TLS secret `harbor-tls`（ns harbor） | ✅ |
| ~12:58 | apply harbor Gateway + HTTPRoute ×2（http→https 301 跳转；https 转发 svc harbor:80，request timeout=0s） | PROGRAMMED=True，ClusterIP 10.247.21.246 |
| ~13:00 | 端到端验证：集群内 curl `https://harbor.sdpworkflow.com/api/v2.0/health`（经 Envoy TLS 终止） | **HTTP 200** ✅ |

## 产物与凭据位置

- 跳板机 `/root/sdp-charts/`：三个 chart tgz、postgresql-values.yaml、harbor-values.yaml、harbor-secrets.txt（固定密钥，helm upgrade 必须复用，勿丢勿入库）、harbor.crt/.key
- Harbor：`admin / Admin@123`；externalURL=`https://harbor.sdpworkflow.com`
- 本地 cert 源：`cert-build/certs/harbor.crt/.key`（SAN `*.sdpworkflow.com`）

## 未完成（后续轮次）

1. `harbor.sdpworkflow.com` DNS / 对外入口（envoy 数据面 svc 为 ClusterIP，外部访问需 LB/ELB 决策）
2. 平台侧 `sdp-gateway`（依赖 console TLS secrets）
3. keycloak / hub / runner / console 部署

## 补充记录

| 时间 | 动作 | 结果 |
|---|---|---|
| 14:48 | 从跳板机（119.3.221.126，hce-2.0 环境）拷回 buildkitd 配置 `/etc/buildkit/buildkitd.toml` → env 仓 `prod-deplyment/buildkitd.toml` | OK；内容为 docker.io 四镜像 mirror（1panel/dockerproxy/daocloud/1ms），由 hce-2.0-64bit-env.sh 生成 |
