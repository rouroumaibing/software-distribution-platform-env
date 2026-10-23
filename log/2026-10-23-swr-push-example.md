# 2026-10-23 刷新 SWR 凭据 + 补推 example 镜像 操作日志

> 背景：上午 example 软件「构建+发布」API 测试中，镜像本地 build 成功，但 push SWR 时 `/root/docker-login.txt`(10-22 17:19) 与 `/root/.docker/config.json`(10-22 18:17) 的 SWR 临时令牌均已 401 过期（间隔约 8h）。用户于 17:05 从 SWR 控制台重新生成登录命令刷新凭据后，由本会话补推三个 example 镜像。

## 节点与工具链现状（补推前确认）
- 跳板机公网 `113.44.152.216:30033`；云节点 `m60064325-nodepool-...`（HCE 2.0 x86_64）。
- 工具链：无 `docker`；`nerdctl 2.4.1` + `buildkitd` RUNNING(`tcp://127.0.0.1:1234`)。
- 本地 `nerdctl images` 已有三个 example 镜像并打了 SWR tag：
  - `swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx:v0.0.1`（平铺单镜像，首次 push 因 401 失败）
  - `…/nginx-canary:v0.0.1`
  - `…/nginx-canary:v0.0.2`

## 凭据刷新与登录
- 用户刷新的 `/root/docker-login.txt`（mtime 10-23 17:05）格式：
  `docker login -u cn-north-4@<tenant> -p <token> swr.cn-north-4.myhuaweicloud.com`
- 登录（nerdctl 兼容 docker login 语法，密码走 stdin）：
  `awk '{print $6}' /root/docker-login.txt | nerdctl login swr.cn-north-4.myhuaweicloud.com -u cn-north-4@HST3WRQ3RB49MNMUUO4C --password-stdin`
  → `Login Succeeded`，凭据缓存至 `/root/.docker/config.json`。

## 执行记录（补推三个镜像）
登录后一条命令补齐三个镜像，全部 `PUSH_RC=0`：

| 镜像 | push 结果 |
|------|-----------|
| `swr.cn-north-4.myhuaweicloud.com/sdp-20261022/nginx:v0.0.1` | ✅ PUSH_RC=0（此前 401 未推，本次闭环） |
| `…/nginx-canary:v0.0.1` | ✅ PUSH_RC=0 |
| `…/nginx-canary:v0.0.2` | ✅ PUSH_RC=0 |

- 日志确认三个 manifest 均以 `reduced-platform image` 写入 SWR（OCI v1）。
- 结论：example 软件「构建+发布」全链路镜像现已齐备于 SWR，可随时从 SWR 拉起。

## 残品核查（K8s 侧）
- 注意：本地 `env/.kubeconfig` 指向 kind 本地集群（`127.0.0.1:64587`，当前未运行，连不上）；CCE 集群 kubeconfig 在云节点 `/root/.kube/config`。
- 在云节点用 `$KUBECONFIG=/root/.kube/config` 核查 `sdp-workflow` 命名空间：
  `kubectl -n sdp-workflow get rollouts,pipelineruns,taskruns` → **No resources found**。
- 真实 CRD（pipeline.sdp.io/v1alpha1）：`rollouts` / `pipelineruns` / `taskruns`；无 `workloads` / `runs` / `releases` 复数。
- 结论：之前卡住 run `7e72cd61`（单 stable 镜像发布卡 Progressing）对应的 K8s 残品已不存在于集群，**无需清理**。

## 结论与待办
- ✅ example 镜像全量已在 SWR，发布链路闭环。
- ⏳ 4 个未提交脚本提交前需与用户在建改动对齐：`clean-without-harbor.sh`、`run-bg.sh`、`stop-bg.sh`、`e2e-example-release.sh`（这些脚本含已拍板的工程化改动：BASE 探测、pidfile 停止、canary 双镜像发布；`deploy-without-harbor.sh`/`run.sh`/`e2e-*.sh` 仍有用户未提交 hunk 共存）。
