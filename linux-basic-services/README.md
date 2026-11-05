# 通用 Linux 基础服务安装器
按 YAML 配置，对启用的 `yum` / `nfs` / `ntp` / `dns` 服务依次执行 **检查 → 清理 → 安装**。
目标环境：RedHat 系列（RHEL/CentOS/Rocky/Alma 等，systemd + yum），需以 root 运行。

## 快速开始

```bash
sudo python3 install_services.py --config config.yaml --validate   # 仅校验配置
sudo python3 install_services.py --config config.yaml --dry-run     # 演练，不真正执行
sudo python3 install_services.py --config config.yaml              # 真实安装（需 root）
sudo python3 install_services.py --config config.yaml --service nfs  # 只处理单个服务
```

## 配置（config.yaml）

每个服务可 `enable: true/false`；下列为可配置字段：

| 服务 | 字段 | 说明 |
|---|---|---|
| `yum` | `iso_path`、`repo_dir` | 先把 `/etc/yum.repos.d/*.repo` **移入** `/etc/yum.repos.d.bk`（目录不存在则创建，仅移动不恢复）以离线安装；再将 `iso_path` **拷贝**到 `/mnt/iso`（保留原文件，目录不存在则创建）后 loop 挂载、临时固化到 `/etc/fstab`；装 `httpd`/`createrepo`（仓库服务端依赖）并把 ISO 内 RPM 拷到 `repo_dir` 由 httpd 经 `Alias /repo/` 对外提供仓库（即 `http://<本机IP>/repo/`）；**校验**对外源成功后直接覆盖写 `Base.repo` 指向本机网络源（`http://<本机IP>/repo/`）、清理本地源 + fstab；原网络源 .repo 备份在 `/etc/yum.repos.d.bk` 不恢复 |
| `nfs` | `data_path` | 装 `nfs-utils` + `rpcbind`（`yum -y install nfs-utils rpcbind`），将 `data_path` 导出（任意主机可挂载），启 `rpcbind` + `nfs`（enable rpcbind → enable nfs → restart rpcbind → restart nfs） |
| `ntp` | — | 装 `ntp`，以本机本地时钟 `127.127.1.0` 授时，开放给所有可达节点（不接外部上游）；启动后用 `ntpdate -q <本机 IP>` 自检服务端可应答（仅查询不校时，失败仅告警） |
| `dns` | `domain`、`map_ip` | 装 `dnsmasq`，把 `domain` 解析到 `map_ip` 作 DNS 服务端对外/对内解析（**不修改本机 /etc/resolv.conf**，各机器自行把 DNS 指向本机 IP） |

各服务只写入带 `# managed by linux-basic-services` 标记的配置片段；`cleanup` 仅移除这些托管片段/文件、不碰其它配置，且只停服 + 禁用自启，不卸载软件包。

## 设计要点

- **配置驱动**：行为全部由 YAML 决定；加新服务 = 新增一个 `deploy_*` 函数并登记到 `REGISTRY`。
- **幂等**：重复运行安全（清理只移除托管片段/文件，不破坏既有配置）。
- **安全演练**：`--dry-run` 仅打印命令不执行；`--validate` 仅校验配置值（IP 合法性、必填项），不探测系统。
- **依赖兜底**：优先用 PyYAML；缺失时回退内置极简解析器（仅支持嵌套映射，列表字段如可选的上游 DNS/服务列表会被忽略）。
- **防火墙**：运行时会关闭 `firewalld`/`iptables`（仅 stop + disable，不卸载），以放行四服务端口 80/123/53/2049。

## 局限（务必知悉）

本脚本在 macOS 等无法运行 yum/nfs/ntp/dns 的环境上，命令真实行为**未经运行验证**。
`--dry-run` / 编译 / `--validate` 只验证逻辑层（解析、编排、校验），不代表目标机真实结果。
首次在真实 RedHat 系列发行版 + root + 真实 ISO 上运行前，请人工复核：
`mount -o loop` 可用性、`exportfs` / `systemctl` 行为、以及 `dnsmasq` 是否需改写客户端 `resolv.conf`（本脚本不自动改写，由各机器自行指向本机 IP）的副作用。

## 文件清单

- `install_services.py` — 安装器（全部逻辑）
- `config.yaml` — 示例配置（含字段说明）
- `prompt.txt` — 原始需求规格
