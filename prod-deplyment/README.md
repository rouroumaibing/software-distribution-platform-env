# prod-deplyment — 生产环境部署脚手架

面向云上生产节点的**构建环境就绪脚本**：在目标节点上安装/核验构建三组件交付包（hub / runner / console）所需的全部工具链。脚本均幂等，可重复执行；`--check-only` 只核验不安装。

## 脚本清单

| 脚本 | 目标 OS | 说明 |
| --- | --- | --- |
| `centos-stream-9-64bit-env.sh` | CentOS Stream 9 (x86_64) | 通用 ECS 节点：docker + containerd 路线 |
| `hce-2.0-64bit-env.sh` | Huawei Cloud EulerOS 2.0 (x86_64) | **CCE 托管 K8s 节点**：复用宿主 containerd，走 nerdctl + buildkitd 路线（禁装 docker / containerd.io，会与 CCE 托管 containerd.service 冲突） |
| `hce-2.0-64bit-deploy.sh` | Huawei Cloud EulerOS 2.0 (x86_64) | **SDP 平台一键部署**：工具检查 → ns/secrets（幂等）→ postgresql → hub/console/runner（组件包）；网关/DNS/验证不在职责内 |
| `run.sh` | —— | 部署运行入口（组件包 → 推镜像 → helm install） |

### E2E 验证脚本（云上节点直跑）

云上验证脚本（认证/取数全部脚本内动态完成，一条命令直跑；脚本真源在本目录）：

| 脚本 | 覆盖范围 |
| --- | --- |
| `e2e-smoke.sh` | 全页面 API 契约冒烟（PASS=15） |
| `e2e-cancel-rerun.sh` | 取消/重跑定向验证（PASS=11） |
| `e2e-canary.sh` | canary 真流量验收：release 流水线 → Rollout 步进 → 50% 暂停窗口合成流量采样 → 权重快照回流 → 100% 收口 |

前提：平台已部署（`hce-2.0-64bit-deploy.sh`）、`nginx-canary` stable 已入 harbor 并 helm 部署（见 example 仓 `nginx-canary/`）。

## 网关与入口（云上约束）

- 云上统一使用 CCE 官方「Envoy Gateway」插件（GatewayClass `envoy-gateway`），插件按 Gateway listeners 自动创建独享型 ELB；**不装社区版 Envoy Gateway**——自建 EG 数据面 svc 为 ClusterIP，云上无 MetalLB，无法对外暴露。
- 网关 yaml：`gateway-harbor-cce.yaml`（harbor ELB）、`gateway-sdp-cce.yaml`（平台 ELB，https listener=443）；自建版备份在 `gw-backup-2026-10-19/`。
- 内网 DNS：`harbor.sdpworkflow.com`、`www.sdpworkflow.com` 分别指向两个 ELB IP。

## harbor 自签 CA 与节点分发

节点拉 harbor 镜像要求信任 harbor 的自签 CA（根 CA 见 `cert-build/certs/`），这取决于**拉镜像的节点**而非 harbor 所在位置，固定 harbor 节点不能消除该要求。现状方案为 privileged DaemonSet（`harbor-ca-trust`）向所有节点分发 CA 并重启 containerd，缺陷是新节点存在启动竞态。后续根治优先级：

1. **正规 CA 证书**（推荐根治）：网关 TLS 终结处替换为节点已信任的证书（云上托管证书 / 企业 CA 签发），节点无需任何分发。
2. **CCE 节点池初始化脚本 / 自定义镜像**：把 CA 安装固化进节点池"安装后执行脚本"，新节点纳管即带 CA，无竞态。
3. **DaemonSet 分发**（现状）：可用但需接受新节点启动竞态。

## 镜像构建工具链要求（containerd 路线）

三组件镜像由各仓 `build/<comp>/build.sh` 构建。无 docker 的环境走 nerdctl + buildkitd 复用宿主 containerd，对工具链版本有**硬要求**：

| 工具 | 版本要求 | 原因 |
| --- | --- | --- |
| nerdctl | **>= 2.x** | `nerdctl save` 默认输出 docker 归档格式，无 `--format` 旗标；`build.sh` 的 `sdp_save` 按此直写 |
| buildkitd | **>= v0.34** | `--containerd-worker` 为 string 型（true/false/auto），`build.sh` 用 `--containerd-worker=true` 显式赋值拉起；裸旗标会把后面的 `--addr` 当值吃掉导致 `strconv.ParseBool` 崩溃 |
| containerd | 复用宿主托管实例 | 禁止安装 docker / containerd.io（会与宿主 containerd.service 冲突） |

版本要求的统一权威见 docs 仓 [`shared/BUILD-TOOLCHAIN.md`](https://github.com/rouroumaibing/software-distribution-platform-docs/blob/main/shared/BUILD-TOOLCHAIN.md)。

## buildkitd registry mirrors

buildkitd 读取默认配置 `/etc/buildkit/buildkitd.toml`。docker.io 直连不通的环境（如华为云内网节点）需在此配置 registry mirrors，env 脚本会自动写入：

```toml
[registry."docker.io"]
  mirrors = ["docker.1panel.live", "dockerproxy.net", "docker.m.daocloud.io", "docker.1ms.run"]
```

> 注意：buildkitd **启动时**读取该文件；若 buildkitd 已在运行，写入后需 `pkill -x buildkitd` 让 build.sh 下次构建时重新拉起才能生效。

## 构建工作日志

按日期记录在 [`log/`](../log/) 下（如 `log/2026-10-19-cloud-install.md`、`log/2026-10-19-hce2.0-build-env.md`、`log/2026-10-19-cloud-deploy.md`）。
