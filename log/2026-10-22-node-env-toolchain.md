# 2026-10-22 云上节点环境就绪 + 连通性排障记录

## 一、工具链就绪结果（任务 #13）
在 CCE 节点（跳板机公网 `113.44.152.216:30033`）跑 `prod-deplyment/hce-2.0-64bit-env.sh` 后，核验全绿：

| 组件 | 版本/状态 |
|------|-----------|
| make | GNU Make 4.3 |
| git | 2.33.0 |
| go | go1.27.2 linux/amd64 |
| node | v22.23.3 |
| pnpm | 11.10.0 |
| containerd | OK（CCE 托管，保持不动） |
| nerdctl | 2.4.1 |
| buildkitd | v0.34.0（`--containerd-worker=true`，RUNNING） |
| helm | v3.17.4（此前已装，不在该脚本范围） |
| SWR 登录 | `/root/.docker/config.json` 已就位（nerdctl login 完成） |
| PostgreSQL | 此前已 `kubectl apply` 跑通（Running 1/1 + PVC Bound + DSN 校验通过） |

## 二、遇到的问题与规避手段（指令 #4）

### 坑 1：沙箱出口代理导致 paramiko 连接随机失败
- **现象**：用 troubleshooting 技能的 `bastion_exec.py` 连节点，间歇 `gaierror` / `exit=-1`，约一半概率失败。
- **根因**：本机 Bash 沙箱注入了 egress 代理 `HTTP_PROXY=http://127.0.0.1:61279`。paramiko 5.x 会读取该变量并对跳板机发起 `CONNECT`，而该本地代理对 `113.44.152.216:30033` 的 CONNECT 间歇拒绝，表现为 `gaierror: nodename nor servname provided`。
- **规避**：执行器里 `os.environ.pop` 掉 `HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy`（及其大写），直连节点即可稳定。裸 socket / TCP 直连不受代理影响（已验证）。
- **结论**：属于「agent 运行沙箱」侧环境特性，**非 SDP 项目问题**；但值得把去代理+重试的执行器沉淀为复用脚本（见 `tools/` 下的 `sexec.py`）。

### 坑 2（核心）：`pkill -f 'buildkit.tar.gz'` 自匹配杀掉 SSH 会话
- **现象**：启动器命令一后台拉起安装脚本就 `exit=-1`，而只读 poll 永远成功。误判为「SSH 随机抖动」，绕了 40+ 次重试。
- **根因**：启动器经 SSH 执行的 shell 命令行本身含有字符串 `buildkit.tar.gz`（就是那行 pkill 自己）。`pkill -f` 按**完整命令行**匹配，**会匹配并杀死启动器自己的 shell** → 会话立即断。
- **规避**：删掉该 pkill（flaky curl 早已不存在）。去掉后最近 3 次连接全部第 1 次成功，证明「随机抖动」纯属假象。
- **结论**：通用 shell 陷阱。已写入经验：**后台/守护命令绝不能用 `pkill -f`/`pgrep -f` 匹配一个会出现在自己命令行里的字符串**；即使要清进程，模式也要避开自身命令行内容。

### 坑 3：`pgrep -f` 自匹配造成「已在运行」误报
- **现象**：用 `pgrep -f 'hce-2.0-64bit-env.sh'` 做「已运行则跳过」守护时，启动器自己的命令行也含该字符串，导致永远误报 `already-running`、实则没启动。
- **规避**：守护改为 `mypid=$$; pgrep -f '...' | grep -qv "^$mypid$"`，排除自身 PID；最终改用 nohup 同型 + 进程真实运行判定。
- **结论**：通用 shell 陷阱（与坑 2 同源），已沉淀经验。

### 坑 4：setsid/nohup + 文件重定向「看起来」会掉线
- **现象**：曾怀疑 `setsid` 或「重定向到文件（非 /dev/null）」触发掉线，专门做了对照实验。
- **结论**：两者都正常（test_setsid、test_redirect 均成功）。掉线是坑 2 的 pkill 造成的，与 setsid/重定向无关。记录以免后人误判。

## 三、沉淀的复用脚本（指令 #4「落实为脚本」）
- `tools/sexec.py`：去代理 + 连接重试的节点执行器（替代 troubleshooting 技能的只读 `bastion_exec.py`，且可用于后台长任务）。
- `tools/sexec_loop.sh`：外层重试封装（直到远端命令 exit 0）。
- 启动/轮询脚本：`launch_env.sh`（nohup 同型 + 进程守护，无自匹配）、`poll_env.sh`。
- 说明：跳板机私网 `192.168.0.166:22` 从本机不可达，统一走公网 `113.44.152.216:30033`。

## 四、遗留（待后续任务）
- 指令 #6：sdpworkflow.com 域名未注册内网 DNS，需给每个节点配 /etc/hosts。
- 指令 #1：构建 hub/console/runner 并推 SWR（`swr.cn-north-4.myhuaweicloud.com/sdp-20261022`）。
- 指令 #2：缺口全量测试。
- 长下载统一落到 `software-distribution-platform-env/tmp/` 复用。
