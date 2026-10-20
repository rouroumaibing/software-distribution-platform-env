# 2026-10-19 云上 CCE 平台组件部署（hub / console / runner / keycloak + 网关切换插件）操作记录

- 环境：华为云 CCE 托管 K8s，ns `sdp-workflow`；基础设施（harbor / postgresql / Envoy Gateway 插件）见 `2026-10-19-cloud-install.md`
- 入口：跳板机 `119.3.221.126:30033`（即节点 192.168.0.43）
- 执行人：WorkBuddy（agent，经 SSH 直连跳板机操作）

## 时间线

| 时间 | 动作 | 结果 |
|---|---|---|
| ~14:00 | 三组件版本包基线对齐 ECS（hub 63.9M / runner 53.2M / console 21.3M），包落在节点 `/root` | OK |
| ~14:30 | 部署 hub（chart 内置 keycloakx 子 chart，sts `hub-keycloak`；依赖 secret `hub-keycloak-database`、DSN 指向 postgres） | hub 启动 panic（见下） |
| ~15:00 | hub 启动 panic 排查：gin 通配符命名冲突 4 处（`:orgId`/`:opId`/`:stageId` 与 `:id` 同段不同名） | 修 3 文件统一 `:id`，全仓扫描 0 冲突；新 tag 重新构建推 harbor、`kubectl set image`（container 名 `container-1`）后恢复 |
| ~15:20 | console / runner 部署；secrets `console-tls`（generic：ca.crt/server.crt/server.key）、`console-ingress-tls`（tls）按 chart 期望名创建 | pod Running |
| ~15:40 | 自建 Envoy Gateway 问题暴露：数据面 svc 为 ClusterIP，无负载均衡可暴露服务（云上无 MetalLB 类方案，Service type=LoadBalancer 依赖云 LB 控制环，自装 EG 未对接） | 规避：切换 CCE 官方「Envoy Gateway」插件 |
| ~15:50 | 备份自建网关资源到 `prod-deplyment/gw-backup-2026-10-19/` → 卸载自装 EG（helm uninstall eg + GatewayClass `sdp-eg`/EnvoyProxy `sdp-eg`）→ 清理全部 EG CRD（17 个） | 集群网关资源清零 |
| ~16:00 | 安装 CCE 插件（GatewayClass=envoy-gateway，按 Gateway listeners 自动创建独享型 ELB）；apply `gateway-harbor-cce.yaml`、`gateway-sdp-cce.yaml`（https listener 云上=443） | ELB：harbor 192.168.0.12、sdp 192.168.0.80 |
| ~16:10 | RWO PVC 滚动更新死锁（hub/console）：scale 0 → apply 新 yaml → scale 1 破局 | 恢复 Running |
| ~16:20 | 新扩容节点 x509 unknown authority：privileged DaemonSet（harbor-ca-trust）分发自签 CA + systemd-run 异步重启 containerd（缓存池必须重启） | 全节点可拉 harbor 镜像 |
| ~16:28 | harbor 补推 keycloak:26.7.4；console/runner release 就绪（helm ls 全 deployed） | ✅ |
| ~16:30 | 用户注册内网 DNS：harbor.sdpworkflow.com→192.168.0.12、www.sdpworkflow.com→192.168.0.80 | OK |
| 16:38 | 端到端验证：console `/` 200、hub `/api/v1/orgs` 200、keycloak `/keycloak/realms/sdp` 200、harbor `/` 200；集群 43 pod 全 Running/Completed；runner target `local-dev` online | ✅ 全绿 |

## 已知问题与规避

### 自建 Envoy Gateway 无 LB（已规避，结论性约束）

- 自建 Envoy Gateway（helm 装 EG + GatewayClass/EnvoyProxy）数据面 svc 是 ClusterIP，云上托管集群没有 MetalLB，Service type=LoadBalancer 也不会为它创建 ELB → 网关建完无法对外暴露。
- 规避：云上统一使用 CCE 官方「Envoy Gateway」插件（GatewayClass `envoy-gateway`），插件按 Gateway listeners 自动创建独享型 ELB 与监听器；云上不装社区版 EG。
- 端口裁定：云上 https listener=443（本地 kind 8443 是端口映射时代的过渡，不复用到云上）；ELB 443 下 X-Forwarded-Port=443，Keycloak issuer 推导不带端口，与生产形态一致。

### harbor 自签 CA 分发（现运行方案 + 后续路径，详见 README「镜像构建环境要求」同目录说明）

- 现方案：privileged DaemonSet 向所有节点分发 CA 并重启 containerd；缺陷是新节点启动竞态（DS 未就绪前拉镜像会 x509 失败）。
- 后续根治路径见 `prod-deplyment/README.md`。

## 产物与脚本

- 部署脚本：`prod-deplyment/hce-2.0-64bit-deploy.sh`（工具检查 → ns/secrets 幂等 → postgresql → hub/console/runner（组件包），可重复执行；网关/DNS/验证不在脚本职责内）
- 镜像推送：`prod-deplyment/run.sh`（组件包 → registry）
- 网关 yaml：`gateway-harbor-cce.yaml` / `gateway-sdp-cce.yaml`（插件版）；自建版备份在 `gw-backup-2026-10-19/`
- 遗留：hub 3 个 gin 路由修复文件（variable_group.go / agent_op.go / task_template.go）未 commit

## 20:00 canary 验收（STATUS #10 关闭）
- e2e-canary.sh 全绿 PASS=9 FAIL=0：release 流水线 → Rollout 步进 → 50% 双版本 2/2 并存 + NodePort 合成流量 18/22 → 快照回流 /releases → 100% 收口 run Succeeded；脚本真源 prod-deplyment/（docs/plans 副本已清理，真源唯一定 env 仓）
- demo：example 仓 nginx-canary（已去 SDP 化独立案例）v0.0.1/v0.0.2 两版本包构建推 harbor，stable helm 装 sdp-run
- 平台修复（runner v0.0.6 上云）：①-sdp targetPort env>推断>8080 兜底 ②定时 pause 到时且健康才推进（annotation sdp.io/pause-start）③scaleDeployment 改 merge patch（原 Update 永久撞 RV）④健康探测按 healthCheckInterval 节流（缩放瞬时空窗曾 1 秒计满 3 连败）⑤三份 CRD controller-gen 再生成（status.tasks 缺 rollout 属性被剪，快照回流为空）
