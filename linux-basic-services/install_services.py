#!/usr/bin/env python3
"""通用 Linux 基础服务安装脚本。

按 YAML 配置，对启用的 yum / nfs / ntp / dns 服务依次执行
安全前检查 -> 清理 -> 安装。支持 --dry-run 演练、--validate 仅校验配置、--service 单服务。

目标环境：RedHat 系列（RHEL/CentOS/Rocky/Alma 等，systemd + yum），需以 root 执行。
用法：
  python3 install_services.py --config config.yaml
  python3 install_services.py --config config.yaml --dry-run
  python3 install_services.py --config config.yaml --service nfs
"""
import argparse
import os
import shutil
import subprocess
import sys


# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------

MARK = "# managed by linux-basic-services"
# ntp 等需要整块托管的配置，用起止标记包裹，清理时整块删除（保证幂等）
MARK_OPEN = "# >>> managed by linux-basic-services"
MARK_CLOSE = "# <<< managed by linux-basic-services"


# ---------------------------------------------------------------------------
# 公共：运行上下文 + 命令执行器（dry-run 开关）
# ---------------------------------------------------------------------------

class Ctx:
    def __init__(self, dry_run=False, silent=False):
        self.dry_run = dry_run
        self.silent = silent
        self.actions = []

    def _emit(self, level, msg):
        if self.silent and level != "ERROR":
            return
        tag = "[DRY-RUN] " if self.dry_run else ""
        print(f"{tag}{level} {msg}")

    def info(self, msg):
        self._emit("INFO ", msg)

    def warn(self, msg):
        self._emit("WARN ", msg)

    def error(self, msg):
        self._emit("ERROR", msg)

    def run(self, cmd, check=True, capture=True):
        """执行 shell 命令。dry-run 下只记录意图并返回 (0, '')，不触达系统。"""
        if isinstance(cmd, (list, tuple)):
            cmd_str = " ".join(str(c) for c in cmd)
            shell = False
        else:
            cmd_str = cmd
            shell = True
        if self.dry_run:
            self.info(f"would run: {cmd_str}")
            self.actions.append(("run", cmd_str))
            return 0, ""
        self.info(f"run: {cmd_str}")
        try:
            proc = subprocess.run(cmd, shell=shell, capture_output=capture, text=True)
        except Exception as exc:  # noqa: BLE001
            if check:
                raise RuntimeError(f"命令执行异常: {cmd_str}: {exc}")
            return 1, str(exc)
        out = proc.stdout if capture else ""
        if check and proc.returncode != 0:
            err = proc.stderr if capture else ""
            raise RuntimeError(f"命令失败 rc={proc.returncode}: {cmd_str}\n{err}")
        self.actions.append(("run", cmd_str))
        return proc.returncode, out


# ---------------------------------------------------------------------------
# 公共：配置加载 / 校验小工具
# ---------------------------------------------------------------------------

def load_config(path, ctx=None):
    """加载 YAML 配置；优先 PyYAML，缺失则回退内置极简解析器。

    返回 (config, used_fallback)。回退时会通过 ctx.warn 明确告警，
    说明列表型字段不被支持（将被忽略）。
    """
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text), False
    except ImportError:
        msg = ("未检测到 PyYAML，已回退内置极简解析器：仅支持嵌套映射，"
               "列表型字段不被支持（将被忽略）；"
               "请安装 PyYAML（pip install pyyaml）以获得准确配置")
        if ctx is not None:
            ctx.warn(msg)
        else:
            sys.stderr.write("[WARN] " + msg + "\n")
        return _mini_yaml(text), True


def _strip_inline_comment(s):
    """剥离 YAML 行尾注释（回退解析器专用）。

    YAML 规则：'#' 只有在**不在引号内**、且位于行首或前一个字符是空白时
    才是注释起点。因此 foo#bar、"a#b"、'a#b' 里的 '#' 都是字面量，必须保留。
    """
    quote = None
    i = 0
    while i < len(s):
        ch = s[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < len(s):
                i += 2                      # 双引号内转义符跳过下一个字符
                continue
            if ch == quote:
                if quote == "'" and i + 1 < len(s) and s[i + 1] == "'":
                    i += 2                  # YAML 单引号内 '' 表示一个字面单引号
                    continue
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "#" and (i == 0 or s[i - 1].isspace()):
            return s[:i]
        i += 1
    return s


def _coerce_scalar(val):
    """解析标量：先剥离行尾注释，再去首尾空白，最后判 bool / 引号字符串。"""
    v = _strip_inline_comment(val).strip()
    if v.lower() in ("true", "yes", "on"):
        return True
    if v.lower() in ("false", "no", "off"):
        return False
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v


def _mini_yaml(text):
    """极简 YAML 解析：仅支持嵌套映射（2 空格缩进）+ 标量（bool/字符串）。
    支持整行注释与行尾注释（与 PyYAML 行为一致）；
    不支持列表（如 - 开头的列表项）：含列表的值会被解析为空映射并忽略。"""
    root = {}
    stack = [(-1, root)]
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        if ":" not in stripped:
            continue
        key, _, val = stripped.partition(":")
        key = key.strip()
        val = val.strip()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        parent = stack[-1][1]
        if val == "":
            child = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _coerce_scalar(val)
    return root


def require_root(ctx):
    if ctx.dry_run:
        ctx.warn("dry-run 模式跳过 root 检查")
        return
    if os.geteuid() != 0:
        raise RuntimeError("必须以 root 身份运行（请使用 sudo 或 root 账户）")


def is_ipv4(s):
    parts = str(s).split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p.isdigit() or not 0 <= int(p) <= 255:
            return False
    return True


def _strip_lines(path, mark):
    """删除文件中带 mark 的行（保留用户其它配置）。"""
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        lines = [ln for ln in fh if mark not in ln]
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)


def _strip_managed_block(path, open_s, close_s):
    """删除 open_s..close_s（含边界）之间的整块托管内容，保证幂等可重复。"""
    if not os.path.exists(path):
        return
    out = []
    skip = False
    with open(path, "r", encoding="utf-8") as fh:
        for ln in fh:
            if open_s in ln:
                skip = True
                continue
            if close_s in ln:
                skip = False
                continue
            if not skip:
                out.append(ln)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(out)


def _read_resolv_nameservers(path):
    """从 resolv.conf 读取真实上游 DNS（排除 127.* 回环，避免转发环）。
    仅读取，绝不修改该文件。"""
    names = []
    if not os.path.exists(path):
        return names
    with open(path, "r", encoding="utf-8") as fh:
        for ln in fh:
            s = ln.strip()
            if s.startswith("nameserver"):
                parts = s.split()
                ip = parts[1] if len(parts) > 1 else ""
                if ip and not ip.startswith("127."):
                    names.append(ip)
    return names


def _advertise_host(advertise):
    """解析对外通告地址：0.0.0.0/空时退化为 127.0.0.1（本机回环）。"""
    return advertise if advertise and advertise != "0.0.0.0" else "127.0.0.1"


def _get_domain(cfg):
    """取托管域名，兼容 doamin 笔误。"""
    return cfg.get("domain") or cfg.get("doamin") or ""


def _resolve_bind(listen_ip):
    """解析监听绑定地址：显式 listen_ip > 自动探测本机 IP；
    0.0.0.0/空表示监听所有接口（返回 None）。"""
    if listen_ip == "0.0.0.0":
        return None
    if listen_ip:
        return listen_ip
    return _detect_local_ip()


def _move_repo_to_bak(ctx):
    """离线安装前：把 /etc/yum.repos.d/*.repo 全部移到 /etc/yum.repos.d.bk
    （目录不存在则创建，同名文件强制覆盖），使本机暂时只使用即将写入的 ISO 离线源，
    避免既有网络源干扰安装。仅移动不删除；原 repo 备份在 .bk 目录、不再恢复
    （由校验成功后写入的 Base.repo 接管网络源）。dry-run 下只打印意图。"""
    if ctx.dry_run:
        ctx.info("would move /etc/yum.repos.d/*.repo -> /etc/yum.repos.d.bk/ "
                 "(create .bk if missing)")
        return
    os.makedirs("/etc/yum.repos.d.bk", exist_ok=True)
    ctx.run("find /etc/yum.repos.d -maxdepth 1 -name '*.repo' "
            "-exec mv -f {} /etc/yum.repos.d.bk/ \\;")


def _write_base_repo(ctx, advertise):
    """校验成功后：直接覆盖写 Base.repo 指向网络源（本机 httpd 对外仓库 /repo/），
    使本机回到网络源。原网络源 .repo 仍保留在 /etc/yum.repos.d.bk 备份目录、不恢复。
    dry-run 下只打印意图。"""
    addr = _advertise_host(advertise)
    content = ("[linux-basic-services-base]\n"
               "name=Linux Basic Services Base Repo\n"
               f"baseurl=http://{addr}/repo/\n"
               "enabled=1\n"
               "gpgcheck=0\n")
    if ctx.dry_run:
        ctx.info(f"would overwrite /etc/yum.repos.d/Base.repo (network source):\n{content}")
    else:
        with open("/etc/yum.repos.d/Base.repo", "w", encoding="utf-8") as fh:
            fh.write(content)


def _detect_local_ip():
    """Best-effort 探测安装机器（单台 ECS 或集群节点）的本机 IP。

    优先级：NODE_IP/POD_IP 环境变量(k8s，单机 ECS 上恒为空) > 默认路由出口 IP > hostname -i。
    对多网卡、网卡名多变均鲁棒；全部失败返回 None（调用方退化为
    0.0.0.0 全接口监听）。
    """
    # 1) k8s 节点常用环境变量（最可靠；单机 ECS 上通常未设置，会走后续兜底）
    for env in ("NODE_IP", "POD_IP"):
        v = os.environ.get(env, "").strip()
        if v and is_ipv4(v) and v not in ("127.0.0.1", "0.0.0.0"):
            return v
    # 2) 默认路由出口 IP：UDP connect 不发包，仅取本地源地址，多网卡下最可靠
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 53))
        ip = s.getsockname()[0]
        s.close()
        if ip and ip not in ("127.0.0.1", "0.0.0.0"):
            return ip
    except OSError:
        pass
    # 3) hostname -i 兜底（部分环境会回 127.0.0.1，已过滤）
    try:
        out = subprocess.check_output(
            ["hostname", "-i"], stderr=subprocess.DEVNULL, timeout=5
        ).decode().split()
        for ip in out:
            if is_ipv4(ip) and ip not in ("127.0.0.1", "0.0.0.0"):
                return ip
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# 安全前检查：每个服务一个 check_*，安装前校验配置值与运行环境是否安全
# ---------------------------------------------------------------------------

def check_yum(cfg, ctx):
    """yum 安全前检查：iso_path 与 repo_dir 必填；listen_ip 若配置须合法 IPv4。"""
    iso = cfg.get("iso_path", "") or ""
    if not iso:
        raise RuntimeError("yum 已启用但未配置 iso_path")
    if not ctx.dry_run and not os.path.isfile(iso):
        raise RuntimeError(f"ISO 文件不存在: {iso}")
    repo_dir = cfg.get("repo_dir", "") or ""
    if not repo_dir:
        raise RuntimeError("yum 已启用但未配置 repo_dir（对外仓库持久目录）")
    listen_ip = cfg.get("listen_ip", "") or ""
    if listen_ip and not is_ipv4(listen_ip):
        raise RuntimeError(f"yum.listen_ip 不是合法 IPv4: {listen_ip}")


def check_nfs(cfg, ctx):
    """nfs 安全前检查：data_path 必填。"""
    data_path = cfg.get("data_path", "") or ""
    if not data_path:
        raise RuntimeError("nfs 已启用但未配置 data_path")


def check_ntp(cfg, ctx):
    """ntp 安全前检查：本地时钟模式无用户可配置项，无需校验。

    NTP 服务端可用性自检（ntpdate -q）在 deploy_ntp 末尾、ntpd 启动后执行；
    安装前服务尚未运行，不适合在此探测。
    """
    return


def check_dns(cfg, ctx):
    """dns 安全前检查：domain（兼容 doamin）与 map_ip 必填，map_ip 须合法 IPv4；
    listen_ip 若配置须为合法 IPv4。本服务不修改 /etc/resolv.conf。"""
    domain = _get_domain(cfg)
    map_ip = cfg.get("map_ip", "") or ""
    listen_ip = cfg.get("listen_ip", "") or ""
    if not domain:
        raise RuntimeError("dns 已启用但未配置 domain（或 doamin）")
    if not map_ip or not is_ipv4(map_ip):
        raise RuntimeError(f"dns.map_ip 不是合法 IPv4: {map_ip}")
    if listen_ip and not is_ipv4(listen_ip):
        raise RuntimeError(f"dns.listen_ip 不是合法 IPv4: {listen_ip}")


def _verify_yum_repo(advertise, ctx):
    """校验 httpd 对外 yum 源可达：HTTP GET repomd.xml 返回 200。

    仅做只读 HTTP 探测，绝不修改系统。dry-run 下不触网，直接返回 True（仅打印意图）。
    """
    host = _advertise_host(advertise)
    url = f"http://{host}/repo/repodata/repomd.xml"
    if ctx.dry_run:
        ctx.info(f"would verify yum repo via: {url}")
        return True
    try:
        import urllib.request
        with urllib.request.urlopen(url, timeout=10) as resp:
            ok = resp.status == 200
    except Exception as exc:  # noqa: BLE001
        ctx.warn(f"yum 源校验请求异常: {exc}")
        return False
    if not ok:
        ctx.warn(f"yum 源校验返回非 200: {url}")
    return ok


def _verify_ntp_server(target, ctx):
    """ntpd 启动后自检：ntpdate -q 查询 NTP 服务端是否可应答（仅查询，不校时）。

    target 为本机作为 NTP 服务端对外暴露的 IP（探测失败时退化为 127.0.0.1）。
    失败仅告警、不中断：本地时钟（stratum 10）刚启动可能短时尚未可用。
    dry-run 下不执行命令，仅打印意图并返回 True。
    """
    if ctx.dry_run:
        ctx.info(f"would verify ntp server via: ntpdate -q {target}")
        return True
    rc, _ = ctx.run(f"ntpdate -q {target}", check=False)
    if rc != 0:
        ctx.warn(f"ntp 自检未通过：ntpdate -q {target} 返回 rc={rc}；"
                 f"本地时钟刚启动可能短时不可用，请稍后人工复核")
        return False
    ctx.info(f"ntp 自检通过：ntpdate -q {target} 可应答")
    return True


# ---------------------------------------------------------------------------
# 四个服务：每个一个函数，内部按 清理 -> 安装（安装前先调 check_* 安全前检查）
# ---------------------------------------------------------------------------

def deploy_yum(cfg, ctx):
    """yum：搭建**对外**的离线 yum 源（HTTP 仓库服务端）。

    流程：先把本机既有 /etc/yum.repos.d/*.repo **移入** /etc/yum.repos.d.bk
          （目录不存在则创建；仅移动、不恢复）→ 以 ISO 为离线源装构建仓库所需的
          包：把 iso_path **拷贝**到 /mnt/iso（保留原文件；目录不存在则 mkdir -p）
          → 挂载拷贝后的 ISO（loop）→ 临时固化挂载关系到 /etc/fstab
          → 装 httpd+createrepo（本服务所需的仓库服务端依赖）
          → 把 ISO 内 RPM 拷到持久目录并 createrepo 生成元数据
          → 配置 httpd 对外服务（监听地址：显式 listen_ip > 自动探测本机 IP > 0.0.0.0；
            仓库经 Alias /repo/ 对外暴露，即 http://<本机IP>/repo/）
          → **校验** httpd 对外源可达（/repo/repodata/repomd.xml）
          → 校验成功后：直接覆盖写 Base.repo 指向本机网络源（http://<本机IP>/repo/）、
            删除本地 ISO .repo、卸载并删除本地源（/mnt/iso 拷贝 + /mnt/cdrom 挂载）、移除 fstab 记录。
          原网络源 .repo 备份在 /etc/yum.repos.d.bk 目录、不再恢复（由 Base.repo 接管）。
    校验失败则中止，保留 fstab/挂载与 .bk 以便排查（重跑自动清理）。
    其它节点/机器 .repo 写 baseurl=http://<本机IP>/repo/ 即可。
    """
    ctx.info("=== [yum] ===")
    check_yum(cfg, ctx)
    iso = cfg.get("iso_path", "") or ""
    repo_dir = cfg.get("repo_dir", "") or ""
    listen_ip = cfg.get("listen_ip", "") or ""   # 可选；空/0.0.0.0 = 监听所有接口

    mp = "/mnt/cdrom"
    iso_copy_dir = "/mnt/iso"
    iso_copy = os.path.join(iso_copy_dir, os.path.basename(iso)) if iso else ""
    fstab = "/etc/fstab"
    temp_repo = "/etc/yum.repos.d/localsource.repo"
    httpd_conf = "/etc/httpd/conf.d/linux_basic_services_repo.conf"

    # ---- 清理：停服 + 禁用自启 + 移除托管配置 + 清理残留（不恢复 .bk 备份）----
    ctx.run(f"umount -l {mp} 2>/dev/null || true", check=False)
    ctx.run("systemctl stop httpd 2>/dev/null || true", check=False)
    ctx.run("systemctl disable httpd 2>/dev/null || true", check=False)
    ctx.run(f"rm -f {temp_repo}", check=False)
    ctx.run(f"rm -f {httpd_conf}", check=False)
    # 移除上次遗留的 fstab 托管记录与 /mnt/iso 拷贝（幂等可重复）
    if ctx.dry_run:
        ctx.info(f"would remove fstab lines marked '{MARK}' and stale iso copy {iso_copy}")
    else:
        _strip_lines(fstab, MARK)
        if iso_copy and os.path.exists(iso_copy):
            ctx.run(f"rm -f {iso_copy}", check=False)

    # ---- 安装：以 ISO 为离线源装构建仓库所需的包（ISO 存在性已由 check_yum 保证）----
    # 离线安装前：把既有网络源 .repo 移入 .bk（创建若需），确保 yum install 仅用 ISO 离线源
    _move_repo_to_bak(ctx)
    # 1) cp ISO 到 /mnt/iso（保留原文件；目录不存在则创建）
    ctx.run(f"mkdir -p {iso_copy_dir}")
    ctx.run(f"cp -a {iso} {iso_copy}")
    # 2) 挂载拷贝后的 ISO（loop）
    ctx.run(f"mkdir -p {mp}")
    ctx.run(f"mount -o loop {iso_copy} {mp}")
    # 3) 临时固化挂载关系到 /etc/fstab（校验成功后移除）
    fstab_line = f"{iso_copy} {mp} iso9660 loop,ro 0 0 {MARK}\n"
    if ctx.dry_run:
        ctx.info(f"would append to {fstab}: {fstab_line.strip()}")
    else:
        _strip_lines(fstab, MARK)
        with open(fstab, "a", encoding="utf-8") as fh:
            fh.write(fstab_line)

    # 临时 .repo：从挂载点（file://）安装基础包
    content = ("[linux-basic-services-iso]\n"
               "name=Linux Basic Services Offline ISO\n"
               f"baseurl=file://{mp}\n"
               "enabled=1\n"
               "gpgcheck=0\n")
    if ctx.dry_run:
        ctx.info(f"would write {temp_repo}:\n{content}")
    else:
        with open(temp_repo, "w", encoding="utf-8") as fh:
            fh.write(content)
    # 仅装本服务所需的仓库服务端依赖；nfs/ntp/dns 的依赖由各自 deploy_* 安装
    ctx.run("yum install -y httpd createrepo")

    # ---- 构建持久仓库：把 ISO 内 RPM 拷到 repo_dir，生成元数据 ----
    # 幂等：若 repo_dir 已存在有效仓库元数据（repodata/repomd.xml），说明此前已构建，
    # 跳过 cp + createrepo，避免重复拷贝（对应"ISO 内容已在目标目录则无需 cp"的诉求）。
    ctx.run(f"mkdir -p {repo_dir}")
    repo_ready = os.path.exists(os.path.join(repo_dir, "repodata", "repomd.xml"))
    if repo_ready:
        ctx.info(f"repo_dir 已存在有效仓库元数据，跳过 cp + createrepo：{repo_dir}")
    else:
        ctx.run(f"cp -a {mp}/. {repo_dir}/")  # 拷贝 RPM（cp 而非 mv，源 ISO 保持不动）
        ctx.run(f"createrepo {repo_dir}")

    # ---- 配置 httpd 对外服务 ----
    # 关闭 httpd.conf 中的全局 Listen（默认 Listen 80），改由本工具托管 Listen，
    # 以实现「绑本机 IP / 失败退 0.0.0.0」的监听策略（已注释的行不会重复注释）。
    ctx.run("sed -i 's/^Listen/#Listen/g' /etc/httpd/conf/httpd.conf", check=False)
    # 监听地址：显式 listen_ip > 自动探测本机 IP > 0.0.0.0 兜底
    bind = _resolve_bind(listen_ip)
    if bind and bind != "0.0.0.0":
        listen_clause = f"Listen {bind}:80\n"
        advertise = bind
    else:
        listen_clause = "Listen 80\n"
        advertise = _detect_local_ip() or "0.0.0.0"
    httpd_block = (
        f"{MARK}\n"
        f"{listen_clause}"
        f"DocumentRoot {repo_dir}\n"
        f"Alias /repo/ {repo_dir}/\n"
        f"<Directory {repo_dir}>\n"
        f"    Require all granted\n"
        f"    Options Indexes FollowSymLinks\n"
        f"</Directory>\n"
    )
    if ctx.dry_run:
        ctx.info(f"would write {httpd_conf}:\n{httpd_block}")
    else:
        with open(httpd_conf, "w", encoding="utf-8") as fh:
            fh.write(httpd_block)
    ctx.run("systemctl enable --now httpd")

    # ---- 校验 httpd 对外 yum 源是否就绪（只读 HTTP 探测）----
    if not _verify_yum_repo(advertise, ctx):
        raise RuntimeError(
            f"yum 对外源校验失败：http://{advertise}/repo/repodata/repomd.xml 不可达；"
            f"已中止后续步骤。fstab 记录、挂载与 .bk 备份均保留以便排查，重跑将自动清理。"
        )
    ctx.info(f"yum 对外源校验通过：http://{advertise}/repo/")

    # ---- 校验成功：写 Base.repo 切本机回网络源，删除本地源 + fstab 记录 ----
    # 0) 删除本地 ISO .repo（本机离线源移除）
    ctx.run(f"rm -f {temp_repo}", check=False)
    # 1) 覆盖写 Base.repo 指向本机网络源（http://<本机IP>/repo/）；原网络源 .bk 不恢复
    _write_base_repo(ctx, advertise)
    # 2) 删除本地源：卸载 /mnt/cdrom 并删除 /mnt/iso 拷贝
    ctx.run(f"umount -l {mp} 2>/dev/null || true", check=False)
    ctx.run(f"rm -f {iso_copy}", check=False)
    # 3) 移除 fstab 托管记录
    if ctx.dry_run:
        ctx.info(f"would remove fstab lines marked '{MARK}'")
    else:
        _strip_lines(fstab, MARK)
    # 刷新本机 yum 元数据，使其回到网络源（Base.repo 指向本机 /repo/）
    ctx.run("yum makecache 2>/dev/null || true", check=False)

    addr = _advertise_host(advertise)
    client_repo = (
        f"[linux-basic-services-repo]\n"
        f"name=Linux Basic Services Repo\n"
        f"baseurl=http://{advertise}/repo/\n"
        f"enabled=1\n"
        f"gpgcheck=0\n"
    )
    ctx.info(f"校验成功：已写入 Base.repo 指向本机网络源(http://{addr}/repo/)，"
             f"原网络源备份在 /etc/yum.repos.d.bk 不恢复；本地 ISO 源与 fstab 记录已清理")
    ctx.info(f"其它节点 .repo 示例：\n{client_repo}")


def deploy_nfs(cfg, ctx):
    """nfs：装 nfs-utils + rpcbind，导出 data_path，启 rpcbind + nfs。"""
    ctx.info("=== [nfs] ===")
    check_nfs(cfg, ctx)
    data_path = cfg.get("data_path", "") or ""
    exports = "/etc/exports"

    # 清理：停服 + 禁用自启 + 移除托管配置（不卸载 nfs-utils/rpcbind，符合清理策略）
    if ctx.dry_run:
        ctx.info(f"would remove managed export lines from {exports}")
    else:
        _strip_lines(exports, MARK)
    ctx.run("systemctl stop nfs 2>/dev/null || true", check=False)
    ctx.run("systemctl disable nfs 2>/dev/null || true", check=False)
    ctx.run("systemctl stop rpcbind 2>/dev/null || true", check=False)
    ctx.run("systemctl disable rpcbind 2>/dev/null || true", check=False)
    # 安装
    ctx.run("yum install -y nfs-utils rpcbind")
    ctx.run(f"mkdir -p {data_path}")
    ctx.run(f"chmod +x {data_path}")
    line = f"{data_path} *(rw,no_root_squash,sync,no_subtree_check) {MARK}\n"
    if ctx.dry_run:
        ctx.info(f"would append to {exports}: {line.strip()}")
    else:
        _strip_lines(exports, MARK)
        with open(exports, "a", encoding="utf-8") as fh:
            fh.write(line)
    ctx.run("exportfs -r")
    ctx.run("systemctl enable rpcbind")
    ctx.run("systemctl enable nfs")
    ctx.run("systemctl restart rpcbind")
    ctx.run("systemctl restart nfs")


def deploy_ntp(cfg, ctx):
    """ntp：作为**服务端**向所有可达节点授时（开放模式）。

    设计（按需求）：
      - 不绑定具体 IP，监听所有接口（0.0.0.0），任意可达节点均可访问；
      - 受限默认策略：restrict default kod nomodify notrap nopeer noquery
        （标准 NTP 默认，仍允许外部节点进行时间同步，但禁止改配置、
         禁止 ntpq/ntpdc 查询控制）；
      - 本机时间源使用本地时钟驱动 127.127.1.0，仅以本地时钟独立对外授时，不配置外部 NTP 上游。
    安装前停用冲突的 chronyd → 启动 ntpd → ntpdate -q 自检服务端可应答。
    """
    ctx.info("=== [ntp] ===")
    check_ntp(cfg, ctx)
    conf = "/etc/ntp.conf"
    ntp_bak = "/etc/ntp.conf.bak.linux_basic_services"

    # ---- 清理：停服 + 备份 + 剥离旧行后整块写回（避免默认 server/pool 残留）----
    ctx.run("systemctl stop ntpd 2>/dev/null || true", check=False)
    ctx.run("systemctl disable ntpd 2>/dev/null || true", check=False)
    ctx.run("systemctl stop chronyd 2>/dev/null || true", check=False)
    ctx.run("systemctl disable chronyd 2>/dev/null || true", check=False)
    if ctx.dry_run:
        ctx.info(f"would remove managed block and default server/pool lines from {conf}")
    else:
        if os.path.exists(conf) and not os.path.exists(ntp_bak):
            shutil.copy2(conf, ntp_bak)
        _strip_managed_block(conf, MARK_OPEN, MARK_CLOSE)
        _strip_lines(conf, "server ")   # 移除默认 server 行（避免外部上游残留）
        _strip_lines(conf, "pool ")      # 移除默认 pool 行

    # ---- 安装 ----
    ctx.run("yum install -y ntp")

    # 本机时间源：本地时钟驱动（Undisciplined Local Clock）
    block = f"{MARK_OPEN}\n"
    block += "server 127.127.1.0 iburst\n"
    block += "fudge 127.127.1.0 stratum 10\n"
    # 受限默认：kod nomodify notrap nopeer noquery —— 标准 NTP 默认策略，
    # 仍允许外部节点进行时间同步，但禁止改配置、禁止 ntpq/ntpdc 查询控制。
    block += "restrict default kod nomodify notrap nopeer noquery\n"
    block += f"{MARK_CLOSE}\n"

    if ctx.dry_run:
        ctx.info(f"would write to {conf}:\n{block}")
    else:
        _strip_managed_block(conf, MARK_OPEN, MARK_CLOSE)
        with open(conf, "a", encoding="utf-8") as fh:
            fh.write(block)
    ctx.run("systemctl enable --now ntpd")

    # ---- 自检：ntpd 启动后查询本机 NTP 服务端是否可应答 ----
    # ntpdate -q 仅查询不校时；目标为本机对外 IP（探测失败退 127.0.0.1）。
    _verify_ntp_server(_detect_local_ip() or "127.0.0.1", ctx)


def deploy_dns(cfg, ctx):
    """dns：装 dnsmasq，把 domain 解析到 map_ip，并作为 DNS 服务端对外/对内提供解析；
    兼容 doamin 笔误。会转发原 resolv.conf 的上游以解析外部域名（仅读取，不修改 resolv.conf），
    默认监听所有接口（0.0.0.0：其它机器经主机 IP 可访问，本机 127.0.0.1 也保留），
    可用 listen_ip 限制到特定地址。

    本服务**不修改本机 /etc/resolv.conf**：各机器（含本机）须自行把 DNS 指向本机 IP
    才能使用本 dnsmasq。托管配置以起止标记包裹的整块**追加**到主配置 /etc/dnsmasq.conf
    （而非 drop-in 目录），并显式启用 conf-dir=/etc/dnsmasq.d/,*.conf 保证 drop-in 被加载。
    配置行本身不带注释（dnsmasq 只把行首 # 当注释），清理时按起止标记整块剔除、
    保留主配置原有内容，绝不整文件覆盖。
    """
    ctx.info("=== [dns] ===")
    check_dns(cfg, ctx)
    domain = _get_domain(cfg)
    map_ip = cfg.get("map_ip", "") or ""
    listen_ip = cfg.get("listen_ip", "") or ""          # 可选覆盖；空或 0.0.0.0 = 监听所有接口
    upstreams = cfg.get("upstreams") or []              # 可选列表；缺省则从原 resolv.conf 继承（仅读取）
    conf = "/etc/dnsmasq.conf"
    resolv = "/etc/resolv.conf"                          # 仅读取上游，绝不改写
    old_conf = "/etc/dnsmasq.d/linux_basic_services.conf"  # 旧 drop-in，切换后清理避免重复

    # 清理：删除旧 drop-in（避免与新托管块重复加载），并从 dnsmasq.conf 移除托管块。
    # 注意 conf 是 /etc/dnsmasq.conf（主配置），绝不能整文件删除，只能按标记剔除。
    # _strip_lines 兼容清理旧版本写入的零散 MARK 行（旧版把 MARK 放行首，实为注释）。
    # 本服务不触碰 /etc/resolv.conf。
    ctx.run("systemctl stop dnsmasq 2>/dev/null || true", check=False)
    ctx.run("systemctl disable dnsmasq 2>/dev/null || true", check=False)
    ctx.run(f"rm -f {old_conf}", check=False)
    if ctx.dry_run:
        ctx.info(f"would remove managed block from {conf}")
    else:
        _strip_lines(conf, MARK)
        _strip_managed_block(conf, MARK_OPEN, MARK_CLOSE)
    # 安装
    ctx.run("yum install -y dnsmasq")
    # 上游转发：显式配置优先；否则继承原 resolv.conf 的真实 nameserver（仅读取，跨重装仍有效）
    if upstreams:
        fwd = [u for u in upstreams if is_ipv4(u)]
    elif not ctx.dry_run:
        fwd = _read_resolv_nameservers(resolv)
    else:
        fwd = []
    if not fwd:
        ctx.warn("未配置 DNS 上游转发（dns.upstreams 为空且原 resolv.conf 无可用 nameserver），"
                 "本节点将只能解析托管的 domain，无法解析外部域名")
    # 托管块：配置行不带注释，用起止标记包裹，清理时整块剔除（避免被当成注释而不生效）
    lines = [MARK_OPEN,
             f"address=/{domain}/{map_ip}",
             "conf-dir=/etc/dnsmasq.d/,*.conf"]
    for ip in fwd:
        lines.append(f"server={ip}")
    # 监听地址：显式 listen_ip > 自动探测本机 IP > 0.0.0.0 兜底。
    # - 显式具体地址：bind-interfaces + 监听该地址与回环 127.0.0.1。
    #   回环仍监听：方便本机在自行把 resolv.conf 指向 127.0.0.1 时使用本服务（本脚本不自动改）。
    # - 缺省（未配置）：自动探测本机 IP（NODE_IP/POD_IP → 默认路由出口 → hostname -i）；
    #   探测失败 / 显式 0.0.0.0：不写 listen-address，监听所有接口（其它机器经主机 IP 可访问）。
    bind_ip = _resolve_bind(listen_ip)
    if bind_ip and bind_ip != "0.0.0.0":
        lines.append("bind-interfaces")
        lines.append(f"listen-address={bind_ip}")
        lines.append("listen-address=127.0.0.1")
    lines.append(MARK_CLOSE)
    # 前置换行：主配置末尾可能缺换行，避免追加时与原内容粘连
    content = "\n" + "\n".join(lines) + "\n"
    if ctx.dry_run:
        ctx.info(f"would append to {conf}:\n{content}")
    else:
        os.makedirs(os.path.dirname(conf), exist_ok=True)
        with open(conf, "a", encoding="utf-8") as fh:
            fh.write(content)
    ctx.run("systemctl enable --now dnsmasq")


def disable_firewall(ctx):
    """关闭系统防火墙（firewalld / iptables），保证四服务的端口（80/123/53/2049）可通。

    作为全局准备步骤：仅 stop + disable（不卸载），与清理策略一致；
    对应服务不存在时静默跳过（2>/dev/null || true）。
    """
    ctx.info("=== [firewall] 关闭防火墙 ===")
    for svc in ("firewalld", "iptables"):
        ctx.run(f"systemctl stop {svc} 2>/dev/null || true", check=False)
        ctx.run(f"systemctl disable {svc} 2>/dev/null || true", check=False)


# ---------------------------------------------------------------------------
# 注册表 + 入口
# ---------------------------------------------------------------------------

REGISTRY = {
    "yum": deploy_yum,
    "nfs": deploy_nfs,
    "ntp": deploy_ntp,
    "dns": deploy_dns,
}

SAFETY_CHECKS = {
    "yum": check_yum,
    "nfs": check_nfs,
    "ntp": check_ntp,
    "dns": check_dns,
}


def _validate(config, ctx):
    """纯配置值校验（不触达系统）；非法配置返回 2。"""
    if not isinstance(config, dict):
        ctx.error("配置文件根节点必须是映射（mapping）")
        return 2
    for key, fn in REGISTRY.items():
        svc_cfg = config.get(key) or {}
        if not svc_cfg.get("enable", False):
            continue
        # 用 dry-run + silent 的探针跑一遍各 check_* 安全前检查：
        # 值检查会照常抛错，系统探测被 dry-run 挡住，过程日志被 silent 抑制。
        probe = Ctx(dry_run=True, silent=True)
        try:
            SAFETY_CHECKS[key](svc_cfg, probe)
        except Exception as exc:  # noqa: BLE001
            ctx.error(f"配置校验失败 [{key}]: {exc}")
            return 2
    return 0


def parse_args(argv):
    p = argparse.ArgumentParser(description="通用 Linux 基础服务安装脚本")
    p.add_argument("--config", required=True, help="YAML 配置文件路径")
    p.add_argument("--dry-run", action="store_true", help="只打印将执行的动作，不触达系统")
    p.add_argument("--service", default=None, help="只处理指定服务（yum/nfs/ntp/dns）")
    p.add_argument("--validate", action="store_true", help="仅校验配置后退出")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    ctx = Ctx(dry_run=args.dry_run)
    ctx.info(f"加载配置: {args.config}")
    config, _ = load_config(args.config, ctx)

    if _validate(config, ctx) != 0:
        return 2
    if args.validate:
        ctx.info("配置校验通过")
        return 0

    require_root(ctx)
    disable_firewall(ctx)  # 全局准备：关闭防火墙，确保四服务端口可访问

    order = [args.service] if args.service else list(REGISTRY.keys())
    for key in order:
        fn = REGISTRY.get(key)
        if fn is None:
            ctx.error(f"未知服务: {key}")
            return 2
        svc_cfg = config.get(key) or {}
        if not svc_cfg.get("enable", False):
            ctx.info(f"跳过未启用的服务: {key}")
            continue
        try:
            fn(svc_cfg, ctx)
        except Exception as exc:  # noqa: BLE001
            ctx.error(f"服务执行失败 [{key}]: {exc}")
            return 1
    ctx.info("全部启用服务处理完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
