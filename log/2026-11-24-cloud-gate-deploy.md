# 2026-11-24 云上归零态重建部署 + gate 全量验收 操作日志

> 目标：云上 HCE 3.0 / CCE 集群从归零态重建 SDP 平台（走 SWR 外部镜像仓库，不部署 harbor），随后跑 `gate-cloud.sh` 四步 E2E 全量验收。
> 权威清单：`software-distribution-platform-docs/plans/CLOUD-GATE-CHECKLIST.md`。本日志记录实际执行过程与证据落点。

## 1. 执行前状态（只读探查）

### 1.1 云上机器与集群
- 跳板机/目标机同一台：`1.92.124.255:30033`（公网）/ `192.168.0.65`（私网），HCE 3.0 x86_64，root。
- kubeconfig：`/root/.kube/config`，current-context=`internal`，`kubectl cluster-info` 可达。
- 集群归零态：仅 `default/kube-system/kube-node-lease/kube-public` 四个系统 ns；无 `sdp-workflow`/`sdp-run`/`harbor`。
- kube-system 已装 CCE 官方插件：Envoy Gateway controller（2 副本）+ mutating webhook（2 副本）、coredns、everest-csi、icagent，均 Running。

### 1.2 已有资产（云上 `/var/sdp/`）
- 三仓源码与构建产物齐全。`prod-deplyment/` 下三组件包（今日 15:35 就位）：
  - hub `software-distribution-platform-hub-v0.0.1.tar.gz` 79.7M
  - runner `…-runner-v0.0.1.tar.gz` 53.6M
  - console `…-console-v0.0.1.tar.gz` 21.3M
- hub 版本包内镜像含 OIDC 冷启动重试修复：`internal/middleware/auth.go` 有 `OIDC discovery attempt %d/%d failed` 重试逻辑（今日构建，commit ff3ef4c）。本地已闭环的 P0-1 修复随本次部署上云。
- SWR project `sdp-20261022` 已登录（凭据 `/root/docker-login.txt`，config 缓存在 `/root/.docker/config.json`）。

### 1.3 SWR 镜像齐备性（nerdctl manifest inspect 实测）
| 镜像 | 状态 |
|------|------|
| `keycloak:26.7.4` | EXISTS |
| `software-distribution-platform-hub:v0.0.1` | EXISTS |
| `nginx-canary:v0.0.1` / `:v0.0.2` | EXISTS |
| `postgres:16-alpine` | MISSING（本次补推，见 §2） |

## 2. 前置缺口处置：PostgreSQL 镜像补推

- **问题**：hub chart 只带 keycloak 子 chart，hub/keycloak 均硬依赖 `postgres.sdp-workflow.svc:5432`（库 sdp/用户 sdp）。本次不装 harbor，而：
  - `deploy-without-harbor.sh` 不含 PG 部署步骤（那是 `hce-2.0-64bit-deploy.sh` 的职责）；
  - `hub/deploy/manifests/10-postgres.yaml` 镜像写死 `harbor.sdpworkflow.com/sdp/postgres:16-alpine`（无 harbor 不可用）；
  - env 精简目录 `postgresql/`（chart + values）为空。
- **处置**：从可达 mirror 拉取 postgres:16-alpine 推到 SWR，部署时用改过镜像地址的 manifest。
  - mirror 可达性：`docker.1panel.live` / `dockerproxy.net` → 200；daocloud/1ms → 401。选用 1panel。
  - 拉取+推送走后台 `nohup /tmp/push_pg.sh &`（云上长命令约定），日志 `/tmp/push_pg.log`。
  - 源 `docker.1panel.live/library/postgres:16-alpine` → 目标 `swr.cn-north-4.myhuaweicloud.com/sdp-20261022/postgres:16-alpine`。
  - 结果：`PUSH_RC=0` + `PUSH_OK`（manifest inspect 通过）。本次唯一需新增上传的镜像。

## 3. 部署策略

- 入口：`deploy-without-harbor.sh --registry swr.cn-north-4.myhuaweicloud.com/sdp-20261022`
  - 阶段 1-5：集群可达 → ns sdp-workflow → 证书/4 TLS secret/sdp-ca → 平台网关 sdp-gateway（Gateway API，CCE ELB，https listener 443）→ Envoy proxy 资源收敛 → 默认 StorageClass。
  - 阶段 6：委托 run.sh 把三组件包解包、镜像 load/tag/push 到 SWR、helm upgrade --install。
  - 脚本明确不含 DNS/hosts（末尾提示）——本次按用户裁定用 hosts 方案。
- PG：单独 apply 改过镜像地址的 `10-postgres.yaml`（SWR postgres），须先于 hub/keycloak 就绪。

## 4. 执行记录

### 4.1 部署执行（15:42-15:43）
- 先单独部署 PG（临时 manifest `/tmp/pg-deploy.yaml`，镜像改为 SWR postgres），创建 ns sdp-workflow + PVC + Deployment + Service。
- 主部署 `deploy-without-harbor.sh --registry swr.cn-north-4.myhuaweicloud.com/sdp-20261022 --runtime nerdctl` 后台执行，日志 `prod-deplyment/log-deploy-20261124.txt`，`DEPLOY_RC=0`。
  - 阶段 2-5：4 TLS secret + sdp-ca、Gateway sdp-gateway（ELB 192.168.0.155，https 443）、SC csi-disk 设为默认均完成。
  - 阶段 6：console/hub/runner 三个 helm release `STATUS: deployed`（REVISION 1）。
  - helm warning：`unknown field spec.timeout.http.streamIdleTimeout`（CCE EG CRD 版本不识别，O-42 G1 相关，不影响主流程）。

### 4.2 阻塞诊断与本质原因（从第一性原理）

部署提交成功但多 pod 未就绪，逐层下钻，定位到 4 个独立根因：

| # | 现象 | 表层处置 | 本质原因 |
|---|------|---------|---------|
| 1 | hub/keycloak `ImagePullBackOff`（SWR 401 anonymous） | default SA 补 `imagePullSecrets: default-secret` 并重建 pod | hub chart 的 deployment 不渲染 imagePullSecrets（console/runner 渲染了）；无 harbor 场景下 SWR 是私有仓库，必须显式挂载凭据。清单 P2-29 的真实暴露。 |
| 2 | sdp-gateway Pod Pending `Insufficient cpu` | 收敛 EnvoyProxy requests（CM `envoy-gateway-config` 8000m→500m/512Mi，备份 `/tmp/egcm-backup-20261124.yaml`），rollout restart EG controller | CCE EG 插件默认 proxy request 8 核 > 节点 allocatable 7910m；dry-run 已警告未找到 EnvoyProxy CR，需手动收敛 CM。修复后 Gateway `PROGRAMMED=True`。 |
| 3 | SWR 镜像"MISSING"假象 | 用不带 `--platform` 的 `manifest inspect` + 删除本地 tag 后真实 pull 复核 | `nerdctl manifest inspect --platform linux/amd64` 对 SWR 的 reduced-platform OCI manifest 返回假阴性；实际 hub/runner/console/postgres/keycloak 均 EXISTS 且可拉取。部署日志中 manifest 停在 waiting 的 push 已前台重推至 `manifest: done`。 |
| 4 | postgres 反复 `initdb: directory ... not empty / lost+found` | 见下方专项 | CCE csi-disk 在挂载点根自动建 lost+found；K8s volumeMount 把 PVC 直接挂到 mountPath，故 mountPath 与 PGDATA 设为同一路径会让 initdb 撞上 lost+found。且 RollingUpdate 产生两个 ReplicaSet 抢同一 RWO PVC，反复污染数据目录。 |

### 4.3 PG 专项处置（根因 4）
- 错误尝试：mountPath 与 PGDATA 同设为 `/var/lib/postgresql/data/pgdata` → csi-disk 在该挂载点建 lost+found → initdb 仍失败；期间两个 RS 争抢 RWO PVC。
- 按用户授权彻底清理重建：删 Deployment + PVC（失败 initdb 的空盘，无真实数据，已备份 manifest 到 `/tmp/pg-deploy-backup-20261124.yaml`），全新空盘重装。
- 正确配置：mountPath=`/var/lib/postgresql/data`（挂载根，lost+found 在此），PGDATA=`/var/lib/postgresql/data/pgdata`（挂载点内子目录，initdb 自建）。
- 当前状态：单 RS `postgres-858f6d48df`、PVC Bound（pvc-6e84913e）、待确认 PG Ready。

### 4.4 镜像推送核实（用户特别关注）
- 本次唯一新增上传：`postgres:16-alpine`（PUSH_OK，源 docker.1panel.live mirror）。
- hub/runner/console v0.0.1：部署脚本执行了 push 但 manifest 停在 waiting；已前台逐个重推至 `manifest: done`。
- 最终 SWR 实测（不带 --platform）：hub/runner/console/postgres/keycloak 全部 EXISTS；删除本地 hub tag 后真实 pull 成功。
- 仍缺：`nginx-canary:v0.0.1/v0.0.2`（canary/example 测试素材，example 仓有构建脚本，待构建推送）。
- 用户提及的 `sdp-20161022` project 经核实不存在（全部镜像 MISSING），实际项目为 `sdp-20261022`（本次全程使用）。

### 4.5 hosts 与网关入口（15:52-15:53）
- Gateway `sdp-gateway` PROGRAMMED=True，CCE ELB 地址 `192.168.0.155`（内网），https listener 443。
- DNS 公网仍解析 www.sdpworkflow.com 到 Squarespace；按裁定用 hosts 方案：
  `/etc/hosts` 追加 `192.168.0.155 www.sdpworkflow.com harbor.sdpworkflow.com`（幂等grep判断）。
- 直连 ELB IP 的 HTTPS 会 TLS reset（缺 SNI）——用域名访问自动带 SNI 后正常：
  `https://www.sdpworkflow.com/api/v1/targets` → 200；证书 CN=console.sdp-workflow.svc，issuer=sdpworkflow.com-ROOT-CA（curl -k 忽略自签校验）。

### 4.6 keycloak token 修复（15:52）
- 现象：`GET /token` 返回 `invalid_grant: Account is not fully set up`，realm sdp 导入成功但 admin 用户登录被 required action 拦截。
- 本质：realm JSON 里 admin 用户 `requiredActions: ["UPDATE_PASSWORD"]`（chart 模板 keycloak-realm-configmap.yaml:253），首次 password grant 要求改密码 → E2E 动态取 token 全挂。本地 kind 无此问题因账号已 setup 过。
- 修复：拿 master admin token（admin-cli/admin/sdp@12345），经 Admin REST API 查 sdp realm admin 用户 id，`PUT /admin/realms/sdp/users/<id>` 设 `"requiredActions":[]` → 204；随后 sdp-console password grant 拿到 token（len=1575）。
- 注意：此为运行时修复，PG 重建后会重置；根治应改 realm JSON（用户授权前不动用户文件）。

### 4.7 P0 前置核验结果（全部通过）
| 项 | 结果 |
|---|---|
| 全 pod Running | ✅ console/hub/keycloak/postgres/runner/sdp-gateway×2 |
| Gateway PROGRAMMED | ✅ True，ELB 192.168.0.155 |
| BASE 探活 | ✅ /api/v1/targets → 200 |
| Runner online | ✅ target `local-dev` status=online |
| KC token | ✅ 修复 requiredActions 后 len=1575 |

### 4.8 镜像推送核实补充
- `nginx-canary:v0.0.1/v0.0.2` 本地与 SWR 均缺（canary/example 测试必需）。已从本地 example 仓传 build.sh/Dockerfile/index.html/charts 到云 `/var/sdp/example/nginx-canary/build/nginx-canary/`，后台构建中（log `/tmp/build_canary.log`）；base 镜像 `nginx:perl` 从 1panel mirror 拉取较慢。

### 4.9 gate 前两步结果（15:54-15:55，证据 20261124T075451Z）
- `gate-cloud.sh --only=smoke,cancel-rerun` → OVERALL PASS，GATE_PART1_RC=0。
  - smoke：RESULT PASS=15 FAIL=0
  - cancel-rerun：RESULT PASS=11 FAIL=0
- 证据目录：`gate-evidence/20261124T075451Z/`（summary.txt + 各 script.log）。
- 预检全通过：BASE 探活、kubectl/KUBECONFIG、TOKEN 动态获取（requiredActions 修复后）。

### 4.10 nginx-canary 镜像构建推送（15:51-15:58）
- SWR 与本地均缺 `nginx-canary:v0.0.1/v0.0.2`（canary 脚本 grep 页面里的 `v0.0.1`/`v0.0.2` 做流量采样，两个版本 index.html 必须不同）。
- 第一性原因：example 仓 build.sh 的 `FROM nginx:perl` 需从 docker.io 拉 70M base；云上唯一可用 mirror（1panel）该层下载 stall（234s 仅 69.8M/70M）。
- 正解：本地 example 仓有完整 `nginx/output/images/nginx-v0.0.1.tar`（75M，内置 nginx base 层）。上传 load 到云 → tag `nginx:canarybase` → `nerdctl run --network=host -d`（绕过 CCE 节点缺 CNI bridge 插件）→ `cp` 渲染后的 index.html（替换 `__APP_VERSION__`）→ `nerdctl commit` 成两版本 → tag SWR 推送。commit 走 containerd 本地存储，绕开 buildkit 的 FROM registry 解析与 --network=host entitlement 限制。
- 结果：`VERIFY_v0.0.1=EXISTS`、`VERIFY_v0.0.2=EXISTS`，页面内容实测 `version: v0.0.1` / `version: v0.0.2`，满足 canary 采样断言。

### 4.11 gate 后两步执行中
- `gate-cloud.sh --only=canary,example`（STABLE_IMG/CANARY_IMG 指向 SWR），日志 `/tmp/gate-part2.log`，证据落新 UTC 目录。

### 4.12 用户裁定：拒绝运行时绕过，改源码重建（16:00 起）
- 用户明确要求：遇到问题不绕过，按第一性原理找根本原因修复，重新构建新版本包安装测试。
- 此前 5 处运行时 patch（SA 补 secret、runner env、Service targetPort、EG CM、keycloak Admin API）重装后全部复现，属绕过。逐条固化到源码：

| # | 根因 | 源码修复 | 文件 |
|---|------|---------|------|
| 1 | hub/keycloak default SA 无 imagePullSecrets → SWR 401 | chart 渲染 imagePullSecrets；values 默认 default-secret；keycloak 子 chart 顶层 imagePullSecrets | hub `templates/deployment-hub.yaml`、`values.yaml` |
| 2 | PG 挂载点 lost+found → initdb 失败 | manifest 加 PGDATA=挂载点子目录；部署脚本纳入 PG 阶段（原本缺失） | hub `deploy/manifests/10-postgres.yaml` + env `postgres.yaml`(新增)、`deploy-without-harbor.sh` |
| 3 | realm admin temporary=true + UPDATE_PASSWORD → token invalid_grant | 改 temporary=false + requiredActions=[] | hub `templates/keycloak-realm-configmap.yaml` |
| 4 | canary Service targetPort=8080 → 流量采样 0/0 | 部署时 `--set rollout.serviceTargetPort=80`（chart 已有正规入口） | env `run.sh`（新增 ROLLOUT_SVC_TARGET_PORT 默认 80） |
| 5 | EG proxy requests 8 核 → Gateway Pending | envoy_preflight 增加 CCE CM 自动收敛分支（8000m→500m） | env `deploy-without-harbor.sh` |

- 附带：sdp-run ns 的 default SA 拉取凭据注入固化到部署脚本阶段 6.5。
- 源码已备份（云上 .bak-20261124）+ 上传替换 + bash -n 全绿；go build ./... 通过。
- 正在云上重新构建三组件 v0.0.2 版本包（hub chart 修复随包交付），随后清理重装 + 全量测试。

### 4.13 v0.0.2 干净重装：又发现并根治 4 个源码缺陷（16:08-16:20）
上一节 5 处修复后清理环境（cleanup `--delete-namespace --delete-pvc`，PG PVC 经 CSI 异步解绑，namespace 约 1 分钟内从 Terminating 消失），用 v0.0.2 包重装，又逐条暴露并根治：

| # | 现象 | 第一性根因 | 源码修复 | 文件 |
|---|------|-----------|---------|------|
| 6 | PG pod ErrImagePull / SWR 401 anonymous | K8s 在 Pod **创建时**快照 SA 的 imagePullSecrets，之后 patch SA 不影响存量 Pod；脚本原为「先 apply Deployment 后 patch SA」，时序错 | PG manifest 的 Pod spec 显式 `imagePullSecrets: [{name: default-secret}]`（`__PULL_SECRET__` 占位符由脚本 sed）；SA patch 前置为兜底 | env `postgres.yaml`、`deploy-without-harbor.sh` pg_phase |
| 7 | hub helm install 报 `keycloak: imagePullSecrets.0 Invalid type. Expected object, given string` | keycloakx 子 chart 的 values.schema.json 要求 `imagePullSecrets` 为对象数组 `[{name:...}]`，此前写成字符串数组 `["default-secret"]` | 改为 `- name: default-secret` | hub `values.yaml` |
| 8 | 重装 hub 仍报 `configmaps sdp-keycloak-realm / deployments hub already exists`（helm status=failed） | 云上 chart 源码 templates 目录遗留 `deployment-hub.yaml.bak-20261124` 等 3 个 .bak；build.sh `cp -rf charts` 把它们打进包，Helm 把 `.yaml.bak-xxx` 也当模板渲染 → 每个资源渲染两份 | 归档删除源码+output 里的 .bak 后重建；渲染验证 realm CM/hub Deploy 各 1 份 | （运维清理，非代码；教训：templates 目录禁止放 .bak） |
| 9 | token 仍 `Account is not fully set up`（CM 里 admin 已是 ra=[]/temporary=false） | keycloak `--import-realm` 策略为 IGNORE_EXISTING：PG 中残留旧 realm（调试期反复重装 hub 未清 PG），新 CM 不覆盖；realm 数据持久化在 PG 而非 PVC | 非代码缺陷（标准策略）；PG 先 pg_dump 备份，Admin API DELETE /realms/sdp 后重启 keycloak 重新导入修复版 CM → token len=1575 | 运维数据清理 |

- 每次源码修改均本地 go build/vet/test + bash -n 全绿后再上传云上；hub 包重建 3 次（第 1 次带旧 values、第 2 次 output 残留 .bak、第 3 次干净）。
- 重装后核验：三组件 helm release 全 deployed；全 pod 1/1 Running；PG pod `pullSecrets=[default-secret]`；Gateway PROGRAMMED=True。
- **ELB IP 变化**：gateway 重建后 ELB 从 `192.168.0.155` 变为 `192.168.0.17`，hosts 已更新（备份 `/etc/hosts.bak-20261124-gate`）；域名 HTTPS → 200。

### 4.14 gate 暴露 runner rerun 竞态回归，源码根治 + v0.0.3 重建（16:27-16:40）
- 全量 gate 首次跑：smoke PASS=15 FAIL=0；**cancel-rerun FAIL**（`PASS=10 FAIL=1`，断言「重跑后未见新尝试 phase=Failed」），gate 按约定中止后续 canary/example。
- 第一性根因（两阶段写入非原子 + 跨 controller 竞态，`e55c575`(11-23) 重构引入）：
  - runner 收到 hub 的 rerun 消息后，RerunHandler 给 TaskRun/PipelineRun 打 `AnnRerunRequested` 注解，由两个 controller 各自异步消费。
  - PR controller `applyRerunReviveIntent` 把 Failed→Running 后立即返回；下一轮 Reconcile 因目标 TaskRun 仍是 Failed（`hasFailedTask`）又把 phase 改回 Failed。
  - 更致命的是 TaskRun 侧 `applyRerunIntent`：先 Patch 清注解、再删 Job、最后 `Status().Update` 重置 Pending；当 status 更新遇 resourceVersion 冲突失败后（日志大量 `the object has been modified`），注解已清、意图永久丢失，TaskRun 卡在 Failed + 孤立 jobRef，新 Job 从未创建。
  - 运行时铁证：`message="rerun requested by dev"`（来自 applyRerunIntent）却 `phase=Failed`；Job 被删（日志 orphan warning）但 sdp-run 无新 Job。
- **根治方案（删除式 rerun）**：RerunHandler 直接 Delete 目标 TaskRun（Background 传播），与已删除下游 TR 的做法一致——把 rerun 变成 delete+recreate，由 PipelineRun DAG reconcile 统一重建。单次原子写，无两阶段窗口；目标 TR 消失后 `hasFailedTask=false`，revive 的 Running 不会回退。PR 侧 revive 注解保留（维持 Cancelled run 不被误复活的语义）。
- 源码改动：`runner/internal/dispatch/rerun_handler.go`（删目标 TR）、`rerun_handler_test.go`（断言改删除）、新增 `internal/controller/rerun_delete_regression_test.go`（锁死"删除后不回退+会重建"不变量）。本地 gate：gofmt/build/vet/test 全绿。
- **版本号教训**：先覆盖重建 v0.0.2 并 helm upgrade，但 pod `startTime` 未变——image tag 相同 + `pullPolicy: IfNotPresent` → 节点复用旧镜像，跑的还是旧二进制。**改用新版本号 v0.0.3 重建**，run.sh 全量重推（console/hub 仍 v0.0.2，runner v0.0.3），runner pod 真正重建（start 08:39:24Z，image=...runner:v0.0.3）。
- 验证：`gate-cloud.sh --only=cancel-rerun` → **PASS=11 FAIL=0**（原 PASS=10 FAIL=1），关键断言「重跑后出现新一次尝试 phase=Running」通过。证据 `gate-evidence/20261124T083941Z/`。

### 4.15 gate 暴露 canary 拉取凭据缺陷，源码根治 + runner v0.0.5（16:42-16:50）
- 4.14 的全量 gate 在 canary 步骤 FAIL：canary pod `ImagePullBackOff`（匿名拉 SWR 401）。
- 第一性根因：runner 的 `buildStable`/`ensureCanary` 构建工作负载 PodSpec 时**无任何 imagePullSecrets 注入点**（全仓 grep 零命中）；sdp-run 是 e2e 动态建的 ns，部署脚本阶段 6.5 patch 其 default SA 时它尚不存在，SA 兜底天然失效。stable pod 能跑纯因节点缓存了 v0.0.1 镜像。
- **根治**：按 `SDP_ROLLOUT_SVC_TARGET_PORT` 既有模式新增 `SDP_ROLLOUT_IMAGE_PULL_SECRET` 环境变量——`rollout_controller.go` 加 `rolloutPullSecrets()`（trim + 逐名转 `LocalObjectReference`），buildStable/ensureCanary 注入 PodSpec；chart `values.yaml` 加 `rollout.imagePullSecret`，`deployment-runner.yaml` 透传 env；env `run.sh` 加 `--rollout-image-pull-secret`（默认 default-secret）。补单测 `rollout_pull_secret_test.go`。本地 gate 全绿。
- **chart 模板缩进坑**：新 env 块照抄相邻块的 `  {{- if }}` 前导空格写法，`{{-` trim 吞换行后与前一 `{{- end }}` 粘连，helm template 报 `line 64: did not find expected key`，v0.0.4 包安装失败。修正为顶格 `{{- if }}`（与文件既有风格一致），本地 helm template 渲染通过后重建 **v0.0.5**。
- v0.0.5 部署验证：runner pod 重建（image=...:v0.0.5, start 08:51:18Z），env `SDP_ROLLOUT_IMAGE_PULL_SECRET=default-secret` 注入；旧 canary workload 清理后由新 runner 重建，canary pod 带 `pullSecrets=[default-secret]` 1/1 Running。

### 4.16 canary 采样三连坑，e2e 脚本源码级修复（16:52-17:40）
- pullSecret 修复后 canary 采样仍 `v0.0.1=0 v0.0.2=0`，逐层下钻定位出三个独立缺陷：
  1. **遗留 rollout 互踩**：Rollout CR 在 run 结束后不回收，上一轮 gate 的 rollout（100% Healthy）持续 reconcile 同一 workload——新 rollout setWeight 50 刚把 stable 0→2 即被旧 controller 压回 0，stable 永远到不了 ready，采样窗口 endpoints 抖空。
  2. **窗口内现拉采样 pod 竞态**：50% 暂停仅 30s，脚本在窗口内才创建 curl pod（调度+启动+40 次采样）耗超窗口。
  3. **exec 命令串语法错误（原始缺陷，kind 基线走 NodePort 分支从未暴露）**：`sh -c "for i in $(seq 1 40); do ..."` 中 `$(seq 1 40)` 在双引号内展开，seq 的换行分隔输出被原样保留，pod 内 BusyBox ash 把首个换行当词表终止符 → `syntax error: unexpected word (expecting "do")`，40 次 curl 从未执行。此前 stderr 被 `2>/dev/null` 吞掉，加 exec 错误捕获后才现形。
- **修复**（`env/prod-deplyment/e2e-canary.sh`）：① 新增「环境复位」段——按 `spec.workloadRef` 清理同 workload 遗留 rollout 并把部署复位到 stable(v0.0.1) 基线（scale stable=REPLICAS / canary=0）；② 新增「采样 pod 预热」段——run 触发后立即拉起 canary-sample 并等 Ready，窗口内直接采样（窗口内现拉仅作兜底）；③ 等待条件升级为**滚动收敛**（readyReplicas≥2 且 ready==spec）；④ 采样双 0 时窗口内最多重试 3 次并捕获 exec stderr 落采样行（`exec_err=...`）；⑤ `seq -s ' ' 1 40` 空格分隔修复 ash 解析。
- 单项验证：`gate-cloud.sh --only=canary` → **PASS=10 FAIL=0**，采样 `stable=2 canary=2 流量 v0.0.1=26 v0.0.2=14`，双版本真实流量断言通过。证据 `gate-evidence/20261124T093359Z/`。

### 4.17 example 断言过期修复（17:42）
- 全量 gate（`gate-full-final2-20261124T093552Z`）前三步全绿：smoke 15/0、cancel-rerun 11/0、canary 10/0，example FAIL（6/1）。
- 根因：`e2e-example-release.sh` 终态断言过期——run 到 weight=100 时 rollout controller 语义为 **canary 副本占满、stable 收缩归零**（canary e2e 的终态断言即此语义），而该脚本仍断言「stable ≥1 ready」（旧 promotion 语义残留）。
- **修复**（`env/prod-deplyment/e2e-example-release.sh`）：① 终态断言改为 canary 占满(4/4) + stable 归零（weight=100 语义）；② 补同款「环境复位」段（清理 example-nginx 遗留 rollout + 复位基线）。
- 单项验证：`--only=example` → **PASS=7 FAIL=0**（`[终态] run=Succeeded weight=100 stableReady= canaryReady=4`）。证据 `gate-evidence/20261124T094025Z/`。

### 4.18 最终全量 gate：总判定 PASS（17:42-17:45）
- `gate-full-final3-20261124T094214Z`：**smoke 15/0、cancel-rerun 11/0、canary 10/0、example 7/0，OVERALL: PASS**。
- canary 采样 `stable=2 canary=2 流量 v0.0.1=20 v0.0.2=20`（精确 50/50 双版本真实流量）。证据 `gate-evidence/20261124T094214Z/`（含 summary.txt 与四步明细日志）。

### 4.19 hub 协调框架多副本专项测试（17:46-18:05）
- **chart 源码接线**（hub v0.0.3/v0.0.4 两次重建）：
  - v0.0.3：values.yaml 新增 `coordination.{enabled,clusterId}`（enabled=true 时 `required` 强校验 clusterId），deployment-hub.yaml 渲染 `SDP_COORDINATION_ENABLED`/`SDP_CLUSTER_ID` + `POD_IP`（fieldRef status.podIP，作实例锁身份）。
  - 部署双副本后暴露**结构性冲突**：artifact `driver: local` 默认挂 `hub-artifacts` RWO PVC，第二副本 `Multi-Attach error` 起不来——与协调设计「实例无本地状态」矛盾。
  - v0.0.4：新增 `artifact.pvcEnabled`（默认 true 保单副本兼容；多副本置 false，生产多副本应配 S3 兼容存储 driver=s3，设计已预留）。
- **测试结果（2 副本 + SDP_COORDINATION_ENABLED=true + cluster=sdp-cloud）**：
  - 两级选主：`coord_workers` 双 worker 注册（心跳正常），`coord_leases` 中 cluster 租约由集群集体续约、instance 租约唯一持有者 10.0.0.55（master），10.0.0.74 为 standby。
  - **故障转移**：强杀 master pod（10:00:29）→ 租约过期（TTL 10s）后 standby 10.0.0.74 接管 instance lease（10:00:54），Deployment 重建的新 pod（10.0.0.56）以 worker 身份注册，全程 API 探活 200。
  - 协调参数确认：renewal 2s / ttl 10s，与设计一致。
- 最终形态：hub v0.0.4 × 2 副本，协调开启，artifact PVC 关闭；console v0.0.2、runner v0.0.5。
- 版本包位置：`/var/sdp/env/prod-deplyment/`（现行）+ `old-*` 目录（历史包）；`.bak-archive-20261124` 存放已清理的 chart 备份。

（example 复跑、清单回填见后续章节）
