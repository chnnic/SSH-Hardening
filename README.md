# VPS 开荒脚本 V3.12.1

> **银趴火山帮** 出品 · SSH · BBR · DDNS · Caddy · Firewall · NFT 转发

一键式 VPS 初始化与管理工具，覆盖安全加固、网络调优、服务部署、端口转发全流程。支持 Debian / Ubuntu / CentOS / Alpine / OpenWrt 等主流系统。

> **运行依赖：** 脚本需 **bash** 运行（使用了数组 / `[[ ]]` / here-string 等特性）。Debian/Ubuntu/CentOS 默认自带；**Alpine 需 `apk add bash`，OpenWrt 需 `opkg install bash`**。脚本头部带解释器守卫：非 bash 环境会自动尝试切到 bash，缺失时给出清晰安装提示而非报一堆语法错。

---

## 快速开始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```

### 离线安装包

适合不能访问 GitHub 的中国内地 VPS。先在一台可以访问 GitHub 的电脑或跳板机下载：

```bash
curl -fLO https://github.com/chnnic/SSH-Hardening/releases/download/v3.12.1/vps-tools-offline-V3.12.1.tar.gz
curl -fLO https://github.com/chnnic/SSH-Hardening/releases/download/v3.12.1/vps-tools-offline-V3.12.1.tar.gz.sha256
sha256sum -c vps-tools-offline-V3.12.1.tar.gz.sha256
```

再通过 `scp`、SFTP 或 WinSCP 将两个文件传到 VPS。Linux/macOS 示例：

```bash
scp vps-tools-offline-V3.12.1.tar.gz* root@你的VPS地址:/root/
```

登录 VPS 后离线安装：

```bash
cd /root
sha256sum -c vps-tools-offline-V3.12.1.tar.gz.sha256
tar -xzf vps-tools-offline-V3.12.1.tar.gz
cd vps-tools-offline-V3.12.1
bash install.sh
v
```

安装阶段不会访问网络。安装包包含完整脚本、内部 SHA256 和独立安装器；不会覆盖其他程序已经占用的 `v` / `V` 命令。安装第三方软件、DDNS、自更新等功能仍需要相应网络连接。

开发者也可以从仓库源码自行构建同样的安装包：

```bash
./build-offline-package.sh
```

## 命令行合集

所有入口都可以直接从 GitHub 调用，也可以在安装到本地后用 `v --命令` 调用。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh) --help
```

| 命令 | 功能 |
|------|------|
| `--ssh-menu` | SSH 工具集 |
| `--fail2ban-menu` | Fail2ban 管理 |
| `--bbr-menu` | BBR TCP 调优 |
| `--firewall-menu` | 防火墙管理 |
| `--dns-menu` | DNS 优化 |
| `--ddns-menu` | DDNS 菜单（Cloudflare / 华为云 DNS） |
| `--ddns-install` | 安装 / 配置 DDNS |
| `--ddns-run` | 立即更新 DDNS |
| `--ddns-status` | 查看 DDNS 状态 |
| `--ddns-log` | 查看 DDNS 日志 |
| `--ddns-link` | 用当前 IPv4 / IPv6 DDNS 域名替换代理分享链接地址 |
| `--mirror-menu` | 系统换源 |
| `--ip-menu` | IPv4 / IPv6 配置 |
| `--caddy-menu` | Caddy 管理 |
| `--nft-menu` | NFT 转发 |
| `--time-menu` | 时间与时区 |
| `--swap-menu` | Swap 管理 |
| `--system-toolbox-menu` | 安全与诊断 |
| `--stun-test` | STUN、多端口 UDP 与 NAT 类型检测 |
| `--hostname-menu` | 修改系统 hostname |
| `--docker-menu` | Docker 管理 |
| `--software-menu` | 软件与重装 |
| `--self-manage-menu` | 脚本管理 |
| `--monitor-home` | 监控告警中心 |
| `--monitor-config` | 监控告警配置 |
| `--config-backup-menu` | 配置备份 |
| `--config-transfer-menu` | 配置迁移 |
| `--rollback-center-menu` | 回滚中心 |
| `--monitor-alert` | 监控告警定时任务入口 |
| `--nft-refresh-ddns` | NFT DDNS 刷新内部入口 |

**安装到本地后用快捷键 `v` / `V` 呼出：**

进入脚本 → `m) 脚本管理` → `1) 安装脚本 + 设置快捷键`

之后任意终端输入 `v` 即可启动。快捷键基于 `/usr/local/bin/` 软链接，不会污染 alias，与其他脚本（如 `volss`）完全隔离。

---

## 主界面

```
██╗███╗   ███╗██████╗  █████╗ ██████╗ ████████╗     ██████╗ ██████╗ ███████╗
██║████╗ ████║██╔══██╗██╔══██╗██╔══██╗╚══██╔══╝    ██╔═══██╗██╔══██╗██╔════╝
██║██╔████╔██║██████╔╝███████║██████╔╝   ██║       ██║   ██║██████╔╝███████╗
██║██║╚██╔╝██║██╔═══╝ ██╔══██║██╔══██╗   ██║       ██║   ██║██╔═══╝ ╚════██║
██║██║ ╚═╝ ██║██║     ██║  ██║██║  ██║   ██║       ╚██████╔╝██║     ███████║
╚═╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝        ╚═════╝ ╚═╝     ╚══════╝

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  VPS TOOLS  ·  V3.12.1
  VPS 开荒脚本 · 银趴火山帮
────────────────────────────────────────────────────────────────
  SSH · BBR · DDNS · Caddy · Firewall · NFT · Monitor

  ◆ 系统概览
  ● SSH  22 · 1 公钥          ● 认证  仅密钥
  ● BBR  bbr · 无限速        ● Fail2ban  运行中
  ● 防火墙  ufw active       ● Caddy  运行中
  ● DDNS  运行中             ● Docker  运行中
  ● 时间  16:30:00

  ◆ 安全与网络
    1  SSH 工具集              2  Fail2ban 管理
    3  BBR TCP 调优            4  防火墙管理
    5  DNS 优化                6  DDNS

  ◆ 系统与服务
    7  系统换源                8  IPv4 / IPv6
    9  Caddy 管理              n  NFT 转发
    t  时间与时区              s  Swap 管理
    h  安全与诊断              a  软件与重装
    d  Docker 管理             m  脚本管理
    g  监控告警中心
    0  退出脚本
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 功能详解

### 1. SSH 工具集

| 功能 | 说明 |
|------|------|
| 查看已有公钥 | 列出所有已授权公钥（支持 ed25519/rsa/ecdsa/sk-ssh/sk-ecdsa/dss） |
| 添加公钥 | 粘贴公钥添加，自动去重 |
| 删除公钥 | 按编号删除，匹配公钥主体不受备注/末尾空格影响 |
| 生成密钥对 | Ed25519 或 RSA-4096，可直接加入服务器（去重） |
| 设置登录方式 | 仅密钥 / 密码+密钥 / 仅密码 |
| 修改 SSH 端口 | 自动备份、语法验证、防火墙同步放行 |

**root 用户固定使用 `/root/.ssh/authorized_keys`**，兼容系统预装公钥。

---

### 2. Fail2ban 管理

自动封禁 SSH 暴力破解 IP。安装时自动检测 backend，支持 `python3-systemd` / `rsyslog` / `auto` 多种方式。

| 功能 | 说明 |
|------|------|
| 查看封禁 IP | 当前所有被封禁的 IP |
| 手动解封 | 立即解封指定 IP |
| 实时日志 | 彩色显示（UTF-8 兼容） |
| 基础参数配置 | bantime / findtime / maxretry / 监控端口 |
| 编辑配置 | 自动选择编辑器（nano → vi → vim） |
| 安装 / 更新 / 卸载 | 一键操作 |

**快速预设：**

| 预设 | bantime | findtime | maxretry |
|------|---------|----------|----------|
| 严格 | 1 天 | 10 分钟 | 3 |
| 标准 | 1 小时 | 10 分钟 | 5 |
| 宽松 | 30 分钟 | 5 分钟 | 10 |
| 永久 | 永久 | 10 分钟 | 3 |

---

### 3. BBR TCP 调优

**智能向导（推荐）** — 自动检测内存推荐预设：

| 内存 | 推荐 |
|------|------|
| < 768 MB | `latency` 低延迟 |
| < 4 GB | `balanced` 均衡 |
| ≥ 4 GB | `throughput` 高吞吐 |

**三种预设：**

| 预设 | 缓冲区 | 适用 |
|------|--------|------|
| `latency` | 32 MB | SSH / 游戏 / 远程桌面 |
| `balanced` | 16-64 MB（按内存动态） | 网页 / 代理 / 日常 |
| `throughput` | 64-512 MB（按内存动态） | 万兆 / 跨洋 |

**自动配置（BDP 三维计算）：**
- 内存：512MB / 1G / 2G / 4G / 8G / 16G+
- 延迟：100ms 以内 / 100-200ms / 200ms 以上
- 带宽：100M / 200M / 500M / 1G / 2G / 5G / 10G

**手动配置（两步式：选用途 → 选缓冲）：** 12 / 16 / 20 / **32** / 40 / 64 / 128 / 256 / 512 / 1024 MB 共 10 档（新增 32MB 为 1G 跨境甜点区）

**安全保护：**
- 自动配置与智能预设的缓冲上限为实际物理内存的 25%；手动配置超过该值时二次确认
- 自动配置误选高内存档位时按实际物理内存计算，例如 512MB 机器选择 16GB 仍按 512MB 限制
- TCP 每连接初始/默认缓冲保持内核保守值（接收 4KB/128KB、发送 4KB/16KB），仅提高自动扩展上限
- `tcp_mem`、`min_free_kbytes`、`tcp_adv_win_scale` 及高风险全局连接参数交还内核管理；升级时恢复首次调优前基线
- 无 sysctl 写入权限（无特权容器）自动检测并提示
- 内核 BBR 支持检测（kernel ≥ 4.9）
- 首次调优保存运行参数基线，每次应用保存运行快照；失败时自动回滚
- 切换预设时检测上一场景遗留的转发/conntrack 参数，并恢复到首次调优前基线（`ip_forward` 单独警告）
- 中转/落地场景默认不修改内核转发；仅在用户确认路由/NAT 用途后启用，并同时设置默认与当前出口 `accept_ra=2`
- 逐行 `sysctl -w` 应用；非核心参数不支持时注释跳过，BBR 与 `fq` 写入失败或回读不一致都会回滚

**其他功能：**
- tc 限速（200M / 500M / 780M / 1G / 2G / 自定义）：`htb` 聚合整形 + `fq` 叶子保留 BBR pacing；兼容不可直接删除的默认 `mq`；默认拒绝外部 QoS，输入精确确认词后可接管或删除 `tbf` / CAKE / HTB 等 root qdisc，操作前诊断快照保存到 `/var/lib/vps-tools/tc-backups/`
- tc 限速状态保存在 `/var/lib/vps-tools/tc-fq.state`；网卡重建导致运行规则丢失时，更新脚本、应用 BBR 配置或进入 BBR 菜单会自动恢复。若默认网卡名称变化，只显示保存状态并提示人工确认，不会静默迁移
- initcwnd（10 / 50 / 100 / 自定义），支持 IPv4/IPv6、无网关默认路由和 systemd/OpenRC/SysV 持久化
- 备份 / 还原 sysctl（按时间戳）

**代理专项参数：**
- 通用核心含 UDP 缓冲（`udp_rmem_min/wmem_min`），优化 QUIC / Hysteria2 / TUIC
- 场景预设（中转/落地）额外含扩大出站端口范围、`tcp_max_tw_buckets`、`fs.file-max`，防高并发端口/fd 耗尽
- 仅用户启用内核转发的中转预设写入 conntrack 参数，`nf_conntrack_max` 按 512MB / 1GB / 2GB / 4GB 内存分档
- 应用场景预设后自动检测代理 service 的 `LimitNOFILE`，偏低时询问写入 drop-in

**写入位置：** `/etc/sysctl.d/99-vps-bbr.conf`（不污染主配置）

---

### 4. 防火墙管理

自动检测 **ufw**（Debian/Ubuntu）和 **firewalld**（CentOS/Rocky）。

| 功能 | 说明 |
|------|------|
| 开启 / 关闭 | 一键切换 |
| 查看规则 | 列出所有规则 |
| 添加 / 删除端口 | 支持端口段，按编号循环删除 |
| 拉黑 / 放行 IP | ufw deny / firewalld rich rule |
| 一键放行常用端口 | SSH + 80 + 443 |
| 安装 / 卸载 | 完整安装 + iptables 残留清理 |

**安全保护：** 卸载防火墙前显示警告（清空规则会暴露主机，2 秒确认延迟）

---

### 5. DNS 优化

启动时自动检测 IPv4/IPv6，无 IPv6 的机器只显示 IPv4 选项。

| 选项 | IPv4 | IPv6 |
|------|------|------|
| Cloudflare | 1.1.1.1 / 1.0.0.1 | 2606:4700:4700::1111 |
| Google | 8.8.8.8 / 8.8.4.4 | 2001:4860:4860::8888 |
| 混合推荐 | CF + Google | 双栈 |
| 阿里云 | 223.5.5.5 / 223.6.6.6 | 2400:3200::1 |
| 腾讯 DNSpod | 119.29.29.29 / 183.60.83.19 | — |
| 114 DNS | 114.114.114.114 / 114.114.115.115 | — |
| 手动编辑 | 自动选择编辑器 | — |

---

### 6. DDNS（Cloudflare / 华为云 DNS）

将动态公网 IP 自动同步到 DNS 服务商。当前支持 Cloudflare 和华为云 DNS。

**安装前准备：**
1. 域名托管到 Cloudflare 或华为云 DNS
2. 准备 API 凭据：Cloudflare 使用 API Token；华为云使用 AK/SK，账号需有 DNS 写权限
3. 准备 IPv4 / IPv6 使用的子域名

**支持配置：**
- IPv4 A 与 IPv6 AAAA 可分别启用、分别设置域名，也可以明确选择同域名双栈更新
- 双栈默认使用独立域名；例如 IPv4 子域名 `hktv4` 会自动建议 IPv6 子域名 `hktv6`
- Cloudflare 会严格按域名和类型匹配记录；检测到交叉残留记录时列出内容，确认后才会删除
- 支持仅 IPv4、仅 IPv6、IPv4+IPv6 双栈
- Cloudflare 支持代理（橙云）开关
- 华为云使用 AK/SK 签名调用 DNS API
- 自定义 TTL（Cloudflare 支持自动 `1` 或 60-86400 秒；开启代理时强制自动，华为云支持 300-2147483647 秒）
- 华为云 Endpoint 仅接受官方 `https://dns[.区域].myhuaweicloud.com` 地址
- 自定义检测间隔（1-59 分钟，默认 5 分钟，常用 1/2/5）
- 分享链接地址替换：保留协议、凭据、端口、参数和备注，按当前配置生成 IPv4 / IPv6 DDNS 链接
- 支持 SIP002/旧式 Shadowsocks、VMess，以及 VLESS、Trojan、Hysteria2、TUIC 等标准 URI

**运行机制：**
- crontab 按配置间隔执行，默认每 5 分钟
- IP 未变化时仅记录日志，不请求 API
- IP 多源备用：`ipify.org → ifconfig.me → ip.sb`
- IPv6 外部探测失败时，会从可用 IPv6 路由选择公网源地址，不发布 ULA、链路本地或无路由地址
- 并发更新优先使用 `flock`；无 `flock` 时使用可恢复的 PID 锁，手动运行会提示已有任务
- 修改服务商或配置时先快照脚本、凭据、配置和 root crontab，测试或安装失败自动恢复
- cron 条目和服务状态分别检测；暂停、卸载或启动失败不会再静默报告成功
- 手动更新分别展示本次 IPv4 A 与 IPv6 AAAA 结果，不再只显示最后执行的 IPv6 日志
- 手动更新前核对运行脚本与当前配置，A/AAAA 开关或域名漂移时停止并提示重新生成
- **IPv4 格式严格校验**：纯 IPv6 机器自动识别不会误发
- **IPv6 独立运行**：仅启用 AAAA 时不会因为无 IPv4 而退出
- **二次校验**：检测到 IP 变化时再查询一次，防止误推
- **日志自动轮转**：超过 500 行自动只保留最近 500 条
- 日志：`/var/log/ddns.log`

**Telegram 通知：**

IP 真实变化时推送通知，实时读取 `/root/.cf_tg`，兼容 crontab 环境（PATH 注入）。

**通知格式：**
```
🌐 DDNS IP 已更新
域名：home.example.com
类型：A
旧IP：1.2.3.4
新IP：5.6.7.8
时间：2026-05-22 16:30:00
```

**菜单：**

| 功能 | 说明 |
|------|------|
| 手动立即更新 | 立即触发同步 |
| 查看日志 | 彩色显示 + 实时跟踪 + UTF-8 完整查看 |
| 修改配置 | 更换服务商 / 域名 / 凭据 / 模式 |
| 暂停 / 恢复 | 临时停用不删除配置 |
| 卸载 | 完整清理 |
| Telegram 通知 | 配置 Bot + Chat ID，发测试消息 |
| 替换分享链接地址 | 将已有节点中的 IP/主机替换为当前 IPv4、IPv6 或同域名双栈 DDNS 地址 |

**状态显示：**
- `运行中` — crontab 正常
- `已停止（cron任务未设置）` — 有 ddns.sh 但 crontab 未写入
- `已停止（cron未安装）` — 系统无 cron，自动安装入口
- `已停止（cron服务未运行）` — 定时任务存在但 cron 守护进程未运行

---

### 7. 系统换源

| 系统 | 支持的源 |
|------|---------|
| Ubuntu | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| Debian | 阿里 / 腾讯 / 清华 / 中科大 / 官方 |
| CentOS / Rocky | 阿里 / 清华 / 默认 |

换源前自动备份，换源后自动 `apt update`。

---

### 8. IPv4/IPv6 配置

| 功能 | 说明 |
|------|------|
| 查看详细状态 | IP 地址 / 优先级 / 默认路由 |
| 设置 IPv4 优先 | 写入 `/etc/gai.conf` 立即生效 |
| 设置 IPv6 优先 | 移除 IPv4 优先规则，恢复系统默认 IPv6 优先 |
| 关闭 IPv6 | sysctl 持久化 |
| 开启 IPv6 | 恢复 sysctl + 等待 SLAAC |
| 多 IP 出口切换 | 在同一默认网卡的多个稳定 IPv4 或 IPv6 地址之间切换默认路由首选源地址 |

多 IP 出口切换只修改运行时默认路由，不直接重写 Netplan、NetworkManager、systemd-networkd 或发行版网络配置。脚本会拒绝多默认路由和 ECMP 环境，切换后同时验证路由选源与绑定地址的 HTTPS 出口；失败立即恢复，成功后仍保留 180 秒防断联自动回滚。网络服务重启或 VPS 重启后，地址选择可能恢复为系统配置。

---

### 9. Caddy 管理

自动 HTTPS 的现代 Web 服务器。

| 功能 | 说明 |
|------|------|
| 查看所有站点 | 列出 Caddyfile 中所有站点 |
| 添加反向代理 | 域名 → 后端，自动判断 SSL 策略 |
| 添加静态网站 | 域名 → 本地目录，自动 HTTPS |
| 删除站点 | 按编号删除，自动重载 |
| SSL 证书状态 | 查看证书及到期时间 |
| 查看访问日志 | 彩色解析 JSON，实时跟踪 |
| 编辑 Caddyfile | 自动选择编辑器，保存后验证并重载 |
| 重载 / 安装 / 卸载 | 完整管理 |

---

### n. NFT 转发管理（端口转发 / DDNS / 访问控制）

**V3.4.0 新增模块**，基于 **nftables** 的现代端口转发，比旧版 iptables NAT 更强大、规则可持久化。

**菜单结构：**
```
  nftables : 已安装    规则数: 3
  访问控制 : 关闭
  DDNS 定时刷新 : 运行中
  ──────────────────────────────────────
  当前规则：
  [1] [ipv4] [单端口] 0.0.0.0:443 → 1.2.3.4:443
  [2] [ipv4] [端口段1:1] 0.0.0.0:10000-10100 → 5.6.7.8:10000-10100
  [3] [ipv6] [单端口] [::]:80 → home.example.com:8080 (2001:db8::1)
  ──────────────────────────────────────
  1) 添加单端口转发     2) 添加端口段转发
  3) 查看所有规则       4) 删除规则
  5) 清空所有规则
  ──────────────────────────────────────
  6) 立即刷新 DDNS
  7) 启用 DDNS 自动刷新
  8) 访问控制（白/黑名单）
```

**核心功能：**

| 功能 | 说明 |
|------|------|
| **单端口转发** | 一个监听端口转发到一个目标端口 |
| **端口段 1:1 映射** | `10000-10100` → 目标 `10000-10100` |
| **端口段偏移映射** | `10000-10100` → 目标 `20000-20100` |
| **双栈支持** | 同一菜单管理 IPv4 + IPv6 规则 |
| **域名目标** | 支持目标填域名，自动 DNS 解析 |

**DDNS 域名目标：**
- 添加规则时目标可填域名（如 `home.example.com`）
- 脚本自动解析为 IP 并记录
- **立即刷新** — 重新解析所有域名目标，IP 变化时更新规则
- **自动刷新** — systemd timer 定时执行（10s ~ 24h 任意间隔）
- 解析失败保留旧 IP，避免规则丢失

**访问控制：**

| 模式 | 行为 |
|------|------|
| 白名单 | 仅允许名单内 IP/CIDR 访问转发端口 |
| 黑名单 | 拒绝名单内 IP/CIDR 访问 |
| 关闭 | 不限制 |

支持 IPv4/IPv6 + CIDR 网段（如 `1.2.3.0/24`、`2001:db8::/32`）。

**关键安全防护：**
- 启用白名单时自动检测 `$SSH_CONNECTION` 当前 SSH 来源 IP
- 不包含时主动询问是否自动加入，**防止自我封锁**
- 仅影响 NFT 转发端口，不影响 SSH 等其他服务

**持久化与跨发行版：**
- 规则数据：`/etc/nft-port-forward/rules.db`
- 访问控制：`/etc/nft-port-forward/access.conf`
- nftables 主配置：`/etc/nftables.conf`（保留用户规则，只加入 VPS Tools include）
- VPS Tools 托管规则：`/etc/nftables.d/vps-tools-nftpf.nft`（仅包含 `nftpf_*` 表，事务应用）
- 自动安装 nftables（apt / apk / yum / dnf）
- 自动开启 IP 转发
- 服务自启：systemd / OpenRC 双支持

---

### t. 时间同步

| 功能 | 说明 |
|------|------|
| 强制同步时间 | timesyncd → chrony → ntpdate → 多来源 HTTPS 兜底 |
| 设置北京时区 | Asia/Shanghai UTC+8 |
| 一键同步+北京时区 | 两步合一 |
| 其他时区 | 含常用时区参考 |
| 开启 NTP 自动同步 | timesyncd / chrony 自动选择 |
| HTTPS 时间同步 | 使用 TCP/443，适合 UDP/123 被封锁；支持立即同步及每 1/3/6/12/24 小时自动同步 |

HTTPS 同步保持证书验证开启，不使用 `curl -k`；依次探测 Cloudflare、阿里云、Microsoft、GitHub、Google，最多采纳 3 个有效来源，并拒绝相差超过 10 秒的结果。自动同步优先使用 systemd timer，无 systemd 时回退 root crontab，默认推荐每 6 小时；如果系统时间偏差大到 TLS 证书无法验证，需要先通过 VPS 控制台粗略校时。

---

### s. Swap 管理

| 功能 | 说明 |
|------|------|
| 创建 / 更换 Swap | 512MB / 1G / 2G / 4G / 自定义 |
| 删除 Swap | 按编号删除，同步 fstab |
| Swappiness | 10 / 30 / 60 / 自定义 |

LXC / OpenVZ 容器自动提示可能不支持。

---

### h. 安全与诊断工具箱

| 功能 | 说明 |
|------|------|
| 系统安全体检 | 检查 SSH 登录策略、配置语法、防火墙、Fail2ban、UID 0 账户、监听端口及待更新软件包 |
| 登录安全日志 | 查看成功/失败登录、当前会话、SSH 日志和 Fail2ban 状态 |
| 网络诊断 | 地址、路由、DNS、Ping、公网出口和路径 MTU 检测 |
| STUN / NAT 检测 | 多 STUN 端点与 UDP 443 / 3478 / 19302 探测，输出公网 IPv4 映射、Mapping / Filtering Behavior、传统 NAT 类型及动态结果解释；支持自定义主机与多端口 |
| 配置备份恢复 | 统一备份 SSH、防火墙、DNS、sysctl、Caddy、DDNS 和 NFT 配置 |
| 操作记录 | 将关键操作、来源 IP 和结果写入 `/var/log/vps-tools-audit.log` |
| 系统资源健康 | CPU、负载、内存、磁盘、inode、连接、进程及失败服务 |
| 系统更新管理 | 检查更新、安全更新、完整更新、自动安全更新和缓存清理 |
| 修改系统 Hostname | 修改系统 hostname，并同步 `/etc/hostname` 与 `/etc/hosts`；用于改变 `root@主机名` 里的系统名 |
| 配置体检中心 | 汇总检查本地脚本、SSH、Fail2ban、监控 Bot、流量监控、日报、备份与历史版本 |
| 生成诊断包 | 导出脱敏诊断包，包含系统概览、服务状态、路由、资源、最近审计记录和关键配置快照 |

SSH、防火墙、DNS、IP 优先级及 IPv6 修改会启动 180 秒防断联保护。用户未确认新连接正常时，脚本自动恢复修改前配置和服务状态。

高风险配置修改会先显示变更计划或逐行差异；配置备份默认保留最近 20 份，可通过环境变量 `VPS_BACKUP_KEEP` 调整。

DNS 设置会自动识别 `systemd-resolved`、NetworkManager、resolvconf 或静态 `/etc/resolv.conf`，使用对应后端持久化配置。

### g. 监控告警中心

| 功能 | 说明 |
|------|------|
| 快速启用 | 按通知、主机名、日报、流量、续费和后台监控顺序完成首次配置 |
| 通知设置 | 单独配置 Telegram Bot Token / Chat ID、主机显示名和测试推送，告警、日报和续费提醒共用 |
| 后台监控 | 集中显示监控 cron、日报 cron 和下次日报时间，已配置但未启用时会明确提示 |
| 资源告警 | 磁盘、内存、负载、SSH、Fail2ban、Docker、Caddy 状态检查 |
| 流量监控 | 今日流量、周期流量、重置日、下行/上行校准和日阈值告警 |
| 每日日报 | 每天固定时间推送主机、今日流量、周期流量、24h/7d 趋势、周期起点和续费信息；启用日报时会自动安装对应分钟的独立 cron |
| 续费提醒 | 支持固定日期、按周期循环、每月固定日和提前提醒天数；可手动确认已续费，也可选择到期次日机器仍存活时自动顺延周期（默认关闭） |

到期存活自动顺延仅适用于“按周期循环”和“每月固定日”。例如续费日为每月 10 日，后台监控在 11 日仍正常运行时，会推定本期已续费并把日期推进到下月 10 日，同时写入历史和审计记录。服务商可能提供停机宽限期，因此该选项默认关闭，启用前会显示误判风险。
| 高级策略 | 可设置冷却时间、静默时段和恢复通知 |
| 最近告警记录 | 本地保留最近 80 条告警、静默和恢复记录，方便回看触发原因 |

告警冷却用于避免同一问题重复刷屏；静默时段会记录但不推送普通告警，恢复通知可在问题消失后主动推送。

---

### a. 软件与系统重装

**常用软件安装：**

| 分类 | 主要软件 |
|------|----------|
| 基础工具 | curl、wget、git、jq、压缩工具、编辑器、tmux、screen |
| 网络诊断 | iproute、DNS 工具、mtr、traceroute、tcpdump、socat、nmap |
| 系统监控 | htop、iftop、iotop、sysstat、lsof、ncdu |
| 开发环境 | 编译工具、Python、pip |

支持 apt、dnf、yum、apk、opkg 和 pacman，可同时选择多个分类；软件包按发行版映射并逐个安装，单个软件缺失不会中断整组。

**一键 DD / 系统重装：**

- 支持 Debian 12/13、Ubuntu 22.04/24.04、Alpine 3.20/3.22、Rocky Linux 9
- 支持自定义 RAW/VHD 镜像直链
- 使用 [`bin456789/reinstall`](https://github.com/bin456789/reinstall) 官方工具，下载后先执行 Bash 语法检查并显示计算出的 SHA256，便于审计
- 自动继承当前 SSH 端口；存在公钥时优先将首个公钥写入新系统
- 拒绝 OpenVZ、LXC、Docker 等容器环境
- 执行前显示根分区、系统磁盘和虚拟化类型，并要求输入 `ERASE-ALL-DATA`

> 系统重装会清空整块系统盘。执行前必须确认商家控制台/VNC可用，并在异地保存所有必要数据。第三方重装工具会在执行时从其官方仓库及系统镜像源继续下载资源。

---

### m. 脚本管理

| 功能 | 说明 |
|------|------|
| 安装 + 设置快捷键 | `/usr/local/bin/vps-tools` + `v` / `V` 软链接 |
| 从 GitHub 更新 | Manifest / SHA256 + Bash 语法校验、保存旧版本、覆盖并自动重启 |
| 回滚脚本版本 | 从 `/var/lib/vps-tools/versions` 选择更新前版本恢复 |
| 删除本地脚本 | 仅删除指向本脚本的软链接，不影响其他脚本 |

**快捷键设计（V3.0.4+）：**
- 只用 `/usr/local/bin/v` 和 `/V` 软链接
- **不写 alias**，避免拦截 `v` 开头的其他命令（如 `volss`）
- 更新时自动清理历史遗留 alias

**自动检测新版本：** 后台请求 GitHub，新版本时主界面显示 🔔 提示。

---

## 安全增强

| 项 | 说明 |
|----|------|
| DDNS 脚本权限 | `chmod 700`，仅 root 可执行；API 凭据文件 `chmod 600` |
| 防火墙卸载警告 | 清空规则会暴露主机，2 秒延迟 + 警告 |
| pf_flush 警告 | 清空所有 NAT 规则会影响其他应用 |
| HTTPS 时间同步 | 强制校验证书并使用多来源时间共识，来源不足或差异过大时拒绝改时 |
| 内核支持检测 | BBR 应用前检测内核版本和模块 |
| 容器权限检测 | 自动识别无特权容器，sysctl 操作受限时友好提示 |
| 防断联保护 | 高风险网络修改 180 秒未确认自动回滚 |
| 更新完整性 | 下载脚本必须匹配仓库中的 SHA256 校验文件 |

---

## 兼容性

| 特性 | 说明 |
|------|------|
| 发行版 | Debian / Ubuntu / CentOS / Alpine / OpenWrt |
| 架构 | x86_64 / aarch64 / armv7 |
| 服务管理 | systemd / OpenRC / SysV init |
| 容器 | KVM / LXC / OpenVZ / 无特权容器 |
| 终端 | 36-76 列响应式布局；标准 / dumb / tmux / OpenWrt；支持 `NO_COLOR=1` |
| Shell | **bash 必需**（Alpine: `apk add bash`，OpenWrt: `opkg install bash`；非 bash 环境自动切换 / fail-fast 提示） |

---

## 关键文件路径

| 文件 | 说明 |
|------|------|
| `/usr/local/bin/vps-tools` | 主脚本 |
| `/usr/local/bin/v` `/V` | 快捷命令（软链接） |
| `/var/lib/vps-tools/backups` | 统一配置备份与防断联快照 |
| `/var/lib/vps-tools/versions` | 更新前的历史脚本版本 |
| `/var/log/vps-tools-audit.log` | 脚本操作审计日志（600） |
| `SSH-Hardening.sh.sha256` | 自更新完整性校验值 |
| `/etc/sysctl.d/99-vps-bbr.conf` | BBR TCP 配置 |
| `/var/lib/vps-tools/bbr-sysctl-baseline.conf` | BBR 首次调优前运行参数基线（600） |
| `/etc/nftables.conf` | nftables 主配置（保留用户规则） |
| `/etc/nftables.d/vps-tools-nftpf.nft` | VPS Tools 托管的 NFT 转发规则 |
| `/etc/nft-port-forward/rules.db` | NFT 转发规则数据库 |
| `/etc/nft-port-forward/access.conf` | NFT 访问控制配置 |
| `/etc/systemd/system/nftpf-ddns.timer` | NFT DDNS 自动刷新 timer |
| `/root/.cf_token` | Cloudflare API Token（600） |
| `/root/.hw_dns_aksk` | 华为云 DNS AK/SK（600） |
| `/root/.cf_zone` | DDNS 服务商、域名、模式、Endpoint、TTL、检测间隔配置 |
| `/root/.cf_tg` | Telegram Bot 配置（600） |
| `/root/ddns.sh` | DDNS 执行脚本（700） |
| `/var/log/ddns.log` | DDNS 日志（自动轮转 500 行） |
| `/etc/fail2ban/jail.local` | Fail2ban 用户配置 |
| `/etc/caddy/Caddyfile` | Caddy 站点配置 |

---

## 开源地址

```
https://github.com/chnnic/SSH-Hardening
```

```bash
# 一行安装
bash <(curl -fsSL https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh)
```

### 开发与构建

仓库源码位于 `src/lib/` 和 `src/modules/`。用户安装的 `SSH-Hardening.sh` 是由模块生成的完整单文件，运行时不下载任何模块：

```bash
./build.sh          # 生成单文件并刷新 SHA256
./build.sh --check  # 检查发行文件是否与模块源码一致
tests/smoke.sh
tests/fault-injection.sh
```

GitHub Actions 还会在 Debian、Ubuntu、Alpine、Rocky Linux 容器中加载生成脚本并执行冒烟测试。

### BBR 独立仓同步

`src/modules/bbr.sh` 同时发布到 [chnnic/BBR-tune](https://github.com/chnnic/BBR-tune)。修改 BBR 行为或其依赖的 core helper 后，必须在同一批工作中同步并推送独立仓：

```bash
cd ../BBR-tune
scripts/sync-from-upstream.sh ../SSH-Hardening
scripts/sync-from-upstream.sh --check ../SSH-Hardening
tests/smoke.sh
```

详细规则由主仓 [AGENTS.md](AGENTS.md) 和独立仓 `SYNC_BBR.md` 共同维护。

---

## 版本沿革（近期）

| 版本 | 主要变更 |
|------|---------|
| **V3.12.1** | 修复首页 BBR 状态误判：当本工具管理的 HTB + FQ 限速拓扑已经存在时，按实际 `class` / `maxrate` 显示“已生效”，不再显示“已保存，未生效”；进入首页时自动恢复确实丢失的已保存规则，并补充对应冒烟测试 |
| **V3.12.0** | IPv4/IPv6 模块新增同网卡多 IP 出口切换：分别列出默认网卡上的稳定 IPv4、IPv6 地址并标记当前出口源地址，通过默认路由 `src` 切换；应用后验证内核选源及绑定地址的 HTTPS 出口，失败立即恢复原路由，成功后保留 180 秒防断联回滚；拒绝多默认路由和 ECMP，不修改发行版持久网络配置 |
| **V3.11.9** | 修复双栈 DDNS 手动更新只显示最后一条 IPv6 日志、容易误判 IPv4 未执行的问题：现在分别展示本次 IPv4 A 与 IPv6 AAAA 结果；执行前校验 `/root/ddns.sh` 与当前配置的开关和域名，旧版或损坏脚本缺少 IPv4 域名时停止并提示重新生成，定时脚本也拒绝静默跳过启用的记录 |
| **V3.11.8** | DDNS 配置中的 Cloudflare API Token、华为云 Secret Access Key 和 Telegram Bot Token 输入统一明文显示，便于检查粘贴内容；确认页仍只显示凭据前缀，凭据文件继续使用 600 权限 |
| **V3.11.7** | DDNS 加固：Cloudflare / 华为云修改配置改为事务式快照，脚本测试、语法校验或 cron 安装失败自动恢复原脚本、凭据、配置与 root crontab；并发改用 `flock` 或可恢复 PID 锁并区分运行中；严格校验域名归属、华为云官方 HTTPS Endpoint 和 TTL；IPv6 本地回退只发布有路由的公网源地址；cron 状态、暂停/卸载错误和 Telegram API 失败均准确报告 |
| **V3.11.6** | 修复更新或网卡重建后 tc 运行规则丢失却显示“无限速”：区分活动规则与“已保存、未生效”状态，更新完成、应用 BBR 配置及进入 BBR 菜单时按状态文件自动恢复；更新器通过新安装脚本的内部入口执行，首次升级即可生效，并自动刷新旧版 tc 持久化助手；默认网卡变化时拒绝静默迁移 |
| **V3.11.5** | BBR 自动/智能配置按实际物理内存计算并将缓冲上限收紧至 25%，TCP 每连接默认缓冲恢复保守值；停止覆盖内核计算的 `tcp_mem`、`min_free_kbytes` 及过时/高风险全局参数，升级时恢复原始基线；场景转发改为按需确认，补齐默认网卡 IPv6 RA，conntrack 按内存分档，并对 BBR 与 `fq` 执行写后回读及失败回滚 |
| **V3.11.4** | 修复多队列网卡默认 `mq` 无法通过 `tc qdisc del` 删除而导致限速应用失败，改用 `replace` 原子安装 HTB，持久化辅助脚本同步修复；取消限速时会识别并标注外部 qdisc，输入 `DELETE <网卡>` 后可保存快照并明确删除 |
| **V3.11.3** | tc 限速新增外部 root qdisc 强制接管：默认仍拒绝覆盖，展示现有 qdisc/class/filter 并要求输入 `FORCE <网卡>`；覆盖前保存文本与 JSON 诊断快照，持久化记录授权以便重启后继续接管 |
| **V3.11.2** | HTTPS 时间同步新增自动定时管理，支持每 1/3/6/12/24 小时执行；优先使用 systemd timer、无 systemd 时回退 root crontab，记录最近结果并使用进程锁防止任务重叠 |
| **V3.11.1** | 新增自包含离线安装包构建器和 GitHub Release 附件：归档包含完整脚本、SHA256、独立安装器与说明文档，可通过 SCP/SFTP/WinSCP 传入无法访问 GitHub 的 VPS 安装 |
| **V3.11.0** | 时间菜单新增 HTTPS 时间同步，使用 TCP/443 适配 UDP/123 被封锁的 VPS；从 Cloudflare、阿里云、Microsoft、GitHub、Google 获取经 TLS 验证的 `Date` 响应，至少两个来源在 10 秒内达成共识才设置系统时间，并作为普通强制同步的最终兜底 |
| **V3.10.9** | 修复未配置公钥时首页和 SSH 工具集显示 `0` 后又换行显示第二个 `0`：保留 `grep -c` 的零计数输出，空文件或文件不存在时统一返回单个 `0` |
| **V3.10.8** | 修复 Caddy 站点列表在 Tab 缩进或嵌套 `reverse_proxy` / `header_up` / `transport` 块下误把内部指令当作站点、真实后端显示不完整及站点计数错误；查看、删除与计数统一按顶层配置块解析，并正确保留多域名站点标题 |
| **V3.10.7** | 续费提醒新增可选的“到期次日存活自动顺延”：每月固定日或循环续费到期后，后台监控仍运行即推定已续费，按原周期推进日期并记录历史、审计，已配置 Telegram 时发送通知；默认关闭且明确提示服务商宽限期可能造成误判 |
| **V3.10.6** | DDNS 新增分享链接地址替换工具：粘贴已有 SS、VMess、VLESS、Trojan、Hysteria2、TUIC 等节点 URI，保留凭据、端口、参数和备注，自动生成当前 IPv4 / IPv6 或同域名双栈 DDNS 链接 |
| **V3.10.5** | 修复 DDNS 双栈配置容易把 AAAA 默认放到 IPv4 子域名的问题：新增共用/独立域名明确选择，默认独立并将 `hktv4` 建议为 `hktv6`；Cloudflare 严格复核记录域名与类型，拒绝同类型重复记录，并可在用户确认后清理 IPv4 域名上的旧 AAAA 或 IPv6 域名上的旧 A |
| **V3.10.4** | 首页 `IMPART OPS` 品牌标题改为 ANSI Shadow 块状字幅；76 列终端同行完整展示，47-75 列终端上下分行，更窄终端自动回退为居中纯文字，避免手机终端折行错位 |
| **V3.10.3** | STUN 检测结果下方新增动态解释区，分别说明 UDP 连通性、NAT 类型、映射行为、过滤行为、判定置信度和使用建议；覆盖公网直连、UDP 过滤、各类锥型、对称型、细分未知及无响应结果 |
| **V3.10.2** | STUN 快速检测移除频繁超时的 Sipgate 3478/3479，改用 Nextcloud 443/3478、Cloudflare 3478、Google 19302 和 MiWiFi 3478；保留同地址跨端口映射判定，并同步更新自定义检测默认值 |
| **V3.10.1** | Cloudflare DDNS 配置时 API Token 改为明文回显，便于确认是否输入及检查粘贴内容；确认页仍只显示前 8 位，凭据文件继续使用 600 权限 |
| **V3.10.0** | 新增 STUN 检测、多端口 UDP 探测和 NAT 类型判定；同一 UDP socket 探测多个端点，支持 RFC 5389 / RFC 5780 地址与过滤行为分析、自定义 STUN 主机和最多 12 个端口，并在证据不足时降低置信度而不强行判型 |
| **V3.9.48** | 修复升级到 V3.9.45 后，旧版生成的 `htb 1:` + `fq 100:` 限速因缺少状态文件被误判为外部 QoS；通过完整 tc 拓扑与持久化文件标记安全迁移，仍拒绝覆盖真正的第三方规则 |
| **V3.9.47** | 修复通过 `bash <(curl ...)` 运行时安装函数复制 `/dev/fd` 流导致本地脚本被截断；安装前后增加语法与版本标记校验，失效快捷键自动修复，测试改用隔离目录且不再污染宿主机 `/usr/local/bin/v` |
| **V3.9.46** | 修复 UFW 放行失败仍启用导致断联、配置导入可覆盖任意路径、NFT 覆盖用户规则及失败无回滚、Swap 关闭失败仍删除、DDNS 占位记录与 cron 假成功、Caddy/Fail2ban/DNS/IPv6/NTP 错误传播；换源支持 deb822 并为 RPM 仓库增加验证回滚 |
| **V3.9.45** | 修复 BBR 场景切换写入危险默认值、智能向导绕过预检和应用失败误报；增加运行参数回滚、IPv6 RA 保护、tc 规则所有权、跨 init 持久化、无网关/IPv6 initcwnd 路由解析，并修正 BDP 与 4GB 推荐逻辑 |
| **V3.9.44** | 修复监控告警通知失败仍标记成功、续费日期未经确认自动推进、冷却签名随指标变化失效、cron 并发重复推送、多网卡流量重复统计和阈值输入缺少校验 |
| **V3.9.43** | 修复 DDNS 二次确认分支无法触发、失败状态覆盖最近成功 IP、短间隔并发执行、华为云查询失败误创建及 cron 误匹配；敏感凭据输入不再回显 |
| **V3.9.42** | DDNS 检测到本机公网 IP 变化时，即使 DNS 记录已同步，也会记录 `IP变化` 并推送 Telegram |
| **V3.9.41** | 修复 DDNS 首页变更记录可能显示旧 IP 状态的问题，按最新状态过滤并比较日志/状态时间 |
| **V3.9.40** | 自更新优先锁定 GitHub main commit 下载脚本、manifest 和 SHA256，避免 raw/CDN 缓存不一致导致校验失败 |
| **V3.9.39** | DDNS 支持自定义检测间隔分钟数，安装、修改和恢复自动更新时写入对应 cron，可设 1 / 2 / 5 分钟等 |
| **V3.9.38** | DDNS IPv6 外部探测失败时回退读取本机全局 IPv6，避免有公网 IPv6 但 `curl -6` 不通时报“无法获取公网 IPv6” |
| **V3.9.37** | DDNS 新增华为云 DNS 服务商，支持 AK/SK 签名调用华为云 DNS API 更新 A / AAAA 记录，并保留 Cloudflare 旧配置兼容 |
| **V3.9.36** | 流量监控记录上次网卡计数，VPS 重启或网卡计数重置后把已用流量滚入持久 offset，避免今日/周期统计回到 0 |
| **V3.9.35** | 修复监控配置被 `source` 执行的风险；SSH 加固写入置顶托管块避免被 `Include` 覆盖；NFT 转发不再 `flush ruleset` 清空宿主机规则；修复 Telegram HTML 转义 |
| **V3.9.34** | 修复 VPS 重启或网卡计数重置后，流量监控当前周期被旧基线钳成 0、长期不增长的问题 |
| **V3.9.33** | DDNS 首页按 IPv4 A / IPv6 AAAA 分别展示最新状态和最后变更，避免双栈时只看到最后执行的 AAAA |
| **V3.9.32** | 修复 DDNS 菜单最后变更时间变量误用 `LC_TIME` 导致的 locale warning |
| **V3.9.31** | DDNS 支持 IPv4 A 与 IPv6 AAAA 分别设置，可同域名或不同子域名同时更新；仅启用 IPv6 时不再依赖 IPv4 |
| **V3.9.30** | 修正 SSH 改端口流程：先确认新端口可登录，再决定是否关闭旧端口，避免关闭旧连接后才发现新端口不可用 |
| **V3.9.29** | 修复每日日报和续费提醒同日重复推送；Telegram 推送中的主机显示名增加 HTML 转义，避免 `<`、`&` 等字符破坏消息格式 |
| **V3.9.28** | 首页采用清爽运维风，缩小 `IMPART OPS` 字幅，并增加 `VPS 开荒脚本 · 银趴火山帮` 副标题 |
| **V3.9.27** | 统一所有交互界面标题为 `VPS TOOLS · 版本号` 与当前模块名，主菜单和特殊模块不再使用不同标题风格 |
| **V3.9.26** | 流量监控启用时新增“是否清除旧记录”确认，可保留旧统计或从当前流量重新统计 |
| **V3.9.25** | 安全与诊断工具箱新增“修改系统 Hostname”，支持校验后写入 `/etc/hostname` 并同步 `/etc/hosts`，用于修改 SSH 提示符中的系统主机名 |
| **V3.9.24** | 续费提醒新增“我已续费”，确认后跳过当前周期并从下一周期继续提醒 |
| **V3.9.23** | 日报、流量、续费和资源告警子页统一增加“立即发送一次”，可手动推送对应模块的实时快照 |
| **V3.9.22** | 重排监控告警中心流程，新增快速启用、通知、日报、流量、续费、资源、高级策略和后台监控独立页面，保留旧配置兼容 |
| **V3.9.21** | 每日日报启用 / 改时间时自动安装独立 cron，按 `23:59` 这类精确分钟推送，避免被 10 分钟监控轮询错过 |
| **V3.9.20** | 监控日报和测试快照新增 24h / 7d 趋势摘要，资源 / 流量 / 续费告警支持提醒、警告和严重分级 |
| **V3.9.19** | 监控告警中心增强，支持冷却时间、静默时段、恢复通知、检查项开关和最近告警记录 |
| **V3.9.18** | 新增配置体检与诊断包入口，并引入 manifest 支撑更新校验 |
| **V3.9.17** | 服务管理统一使用 `systemd_available` 检测，减少 cron / 容器环境下的 systemd 误判 |
| **V3.9.16** | 流量监控阈值设置与启用逻辑拆分，修改阈值不再重置今日与周期累计 |
| **V3.9.15** | 监控告警 SSH 状态同时兼容 `ssh` / `sshd`，并移除 cron 环境下易误判的 `pidof systemd` 依赖 |
| **V3.9.14** | 整理 README 版本沿革为单一倒序表，去除 V3.9.x 重复追加导致的排序混乱 |
| **V3.9.13** | 新增全模块 CLI 菜单入口和 `--help` 命令，并在 README 汇总命令行合集 |
| **V3.9.12** | 新增 DDNS 独立 CLI 入口，支持从 GitHub 直接拉起 DDNS 菜单、安装、运行和日志查看 |
| **V3.9.11** | 续费提醒页面按模式显示字段，避免每月固定日与周期天数同时出现 |
| **V3.9.10** | 流量重置日遇到短月时顺延到下月 `1` 日，避免 `31` 被提前到月底 |
| **V3.9.9** | 流量重置日限制为 `1-31`，并明确 `31` 遇到短月时按当月月底计算 |
| **V3.9.8** | 周期流量校准支持大于网卡累计值的人工修正，避免显示被当前计数器上限截断 |
| **V3.9.7** | 周期流量校准支持分别设置下行/上行，并避免旧合计基线误补分项导致下行归零 |
| **V3.9.6** | 修复旧流量基线科学计数法导致的 Bash 算术错误；流量监控子页统一 `↓1.45G ↑1.81G ↓↑3.26G` 显示 |
| **V3.9.5** | 更新器增加多源重试和 hash 诊断；终端与 Telegram 的流量显示统一为 `↓1.45G ↑1.81G ↓↑3.26G` 简洁格式 |
| **V3.9.4** | 监控流量统计拆分为下行、上行和合计，并同步显示到监控首页、每日日报、测试告警和流量超限告警 |
| **V3.9.3** | 日报时间支持 `23:59` / `2359`，续费日期支持 `2026-05-15` / `20260515`；测试告警改为发送当前系统状态快照 |
| **V3.9.2** | 监控首页保留唯一 Bot 配置入口；每日日报改为真正分段文本，避免 Telegram 显示成一行 |
| **V3.9.1** | 强制更新加入重试与缓存失效参数，降低 GitHub raw 拉取和 SHA256 校验的误报 |
| **V3.9.0** | 监控首页新增共用 Bot 配置入口；流量统计输出改为纯整数，避免部分环境出现科学计数法导致的算术错误 |
| **V3.8.9** | 监控推送支持自定义主机显示名，便于多台机器区分，默认仍使用 hostname |
| **V3.8.8** | 监控告警中心独立到首页，新增每日日报、流量重置日和当前周期流量统计，可按月固定日重置并手动校准当前周期消耗 |
| **V3.8.7** | 新增离线安装包与监控告警中心，支持本地打包安装脚本、生成离线安装包，并通过定时检查对磁盘、负载和关键服务状态进行告警 |
| **V3.8.6** | 新增配置导出/导入与统一回滚中心入口，集中管理配置备份恢复、脚本版本回滚和迁移操作 |
| **V3.8.5** | 新增从 URL 拉取 Compose 文件、自动校验并部署的入口，支持先预览再落盘执行 `docker compose up -d --pull always` |
| **V3.8.4** | 新增 Docker Engine 与 Compose 插件一键安装；新增容器查看、详情、启停、重启、日志、Shell 和删除管理；Compose 容器可拉取新镜像并按原配置重建，普通容器采用无损镜像更新检查，避免丢失启动参数 |
| **V3.8.3** | 新增常用软件多选安装，适配 apt/dnf/yum/apk/opkg/pacman；新增使用官方重装工具的一键 DD/Linux 重装向导，包含容器拒绝、目标磁盘展示、脚本语法检查与 SHA256 展示、SSH 参数继承及固定确认词保护 |
| **V3.8.2** | 统一剩余子页面：BBR 多级向导、Fail2ban 参数页、Swap、换源、DNS、日志、NFT 访问控制和安装向导全面接入响应式菜单、统一输入提示与返回行为 |
| **V3.8.1** | 全面重构终端 UI：响应式宽度、窄屏单列/宽屏双列、统一状态仪表盘与操作提示、紧凑页面标题、主要模块菜单规范化，并支持 `NO_COLOR` 与非交互终端无 ANSI 输出 |
| **V3.8.0** | 源码拆分为 core 和功能模块，由 `build.sh` 生成单文件发行版；新增 Debian/Ubuntu/Alpine/Rocky 冒烟测试与故障注入测试；新增备份保留策略、配置变更预览、资源健康检查和系统更新管理 |
| **V3.7.0** | 新增安全体检、登录安全日志、网络诊断、统一配置备份恢复、操作审计；SSH/防火墙/DNS/IP 修改加入 180 秒防断联回滚；DNS 自动适配 resolved/NetworkManager/resolvconf；脚本更新增加 SHA256 校验、旧版本留存和一键回滚 |
| **V3.6.3** | IPv4/IPv6 配置菜单新增“设置 IPv6 优先”，可移除 `/etc/gai.conf` 中的 IPv4 优先规则并恢复系统默认地址选择策略 |
| **V3.6.2** | BBR 模块增强：sysctl 权限探测不再改变 TCP 参数；tc 限速服务运行时动态识别 `tc` 路径和默认网卡；不支持的 sysctl 参数会在持久化文件中注释；Alpine 内核包安装改为确认后执行；新增 BBR 诊断入口 |
| **V3.6.1** | 修复删除最后一个 SSH 公钥不生效；DDNS 在 `/var/log/ddns.log` 不可写时正确使用备用日志路径；nftables 配置应用失败时不再误报成功；BBR `initcwnd` 支持无网关默认路由 |
| **V3.6.0** | Fail2ban 修正：jail 加 `mode = aggressive`（纯公钥机/禁密码下也能抓扫描者并封禁，解决 `Total failed` 恒为 0）；`journalmatch` 显式双服务名 `ssh.service + sshd.service`（兼容 Debian/RedHat，不改系统 filter）；`jail.local` 已存在由「跳过」改为「备份后重写」（否则脚本更新的配置永不生效） |
| **V3.5.9** | 安全加固一批：SSH 改端口/配置失败**自动回滚**到备份；改端口**延后删旧端口**（先确认新端口可连，防锁死）；防火墙卸载**不再 flush 全表/改默认策略**（只删本脚本规则，避免裸奔与误删 NFT/代理规则）；DDNS IPv4 **严格校验**每段 0-255；服务操作统一 `svc_start/stop/restart` 封装（OpenRC/sysvinit 兼容）；默认网卡改用 `ip route get`；Caddy 配置**临时验证通过才写入**（失败自动还原） |
| **V3.5.8** | 修复 `bbr-tune.sh` 独立版缺失 4 个辅助函数（`ensure_conntrack_module` / `svc_daemon_reload` / `svc_enable` / `svc_disable`，提取时遗漏），独立运行限速 / 场景预设 / initcwnd 不再中断（主脚本不受影响） |
| **V3.5.7** | DDNS 状态区增加「最后一次 IP 变更时间 + 新旧 IP」显示（记录于 `/root/.cf_last_change`，PUT 成功时写入，卸载时清理） |
| **V3.5.6** | 新增 UDP 缓冲（`udp_rmem_min/wmem_min`，优化 QUIC/Hysteria2/TUIC）；场景预设加扩大出站端口范围 + `tcp_max_tw_buckets` + `fs.file-max`，防高并发端口/fd 耗尽；应用场景预设后自动检测代理 service 的 `LimitNOFILE`，偏低时询问写入 drop-in |
| **V3.5.5** | BBR 限速改 htb 整形 + fq pacing（多队列网卡保留 BBR pacing，旧 tbf 会废 pacing）；burst 随速率缩放；切换预设复位残留场景键；新增 32MB 缓冲档；修 BDP 双截断；line_landing ADV_WIN 1→2；UI 全面美化对齐（统一 menu_div/menu_group/menu_item，分隔线对齐 40 宽） |
| **V3.5.4** | bash-first：脚本头部加解释器守卫（非 bash 自动切换 / fail-fast 提示）；修复 DDNS 自动创建 A/AAAA 记录时内联 JSON 引号拼接错误（改用 printf 构建，原写法发出非法 JSON 导致建记录失败） |
| V3.5.3 | NFT 新增规则修改功能（逐项交互修改，应用失败自动回滚） |
| V3.5.2 | BBR 手动配置加场景选择前置层（中转/落地/线路落地/通用） |
| V3.5.1 | 场景预设注入转发参数（5 项）+ 仅中转追加 conntrack（3 项），自动 modprobe nf_conntrack |
| V3.5.0 | 智能向导菜单分组，新增 3 个场景化预设（relay/landing/line_landing） |
| V3.4.5 | DDNS 日志查看内部循环，按 0 立即返回 |
| V3.4.4 | 新增 iptables 本地端口转发子菜单 |
| V3.4.3 | NFT 菜单加安装/卸载，未安装时只显安装入口 |
| V3.4.2 | 修复 grep -c 返回 `0\n0` 导致 integer expression 报错 |
| V3.4.1 | BBR sysctl 精简到 15 个核心参数，按 4 组分类 |
| **V3.4.0** | 新增 NFT 转发管理模块（替代 iptables NAT 端口转发 + 整合入站白名单） |
| V3.3.5 | 清理 7 个死代码函数 + 提取重复的 iptables 清理逻辑 |
| V3.3.4 | DDNS 二次校验，避免查询失败误推 Telegram 通知 |
| V3.3.3 | less / 日志显示强制 UTF-8，避免中文乱码 |
| V3.3.2 | DDNS 日志按行数限制（500 条） |
| V3.2.5 | BBR 支持万兆 / 4G+ 内存（256/512/1024MB 缓冲区） |
| V3.2.3 | 修复 DDNS 模块定义两遍导致所有修复失效的 Bug |
| V3.2.1 | 无特权容器 sysctl 权限检测 |
| V3.2.0 | BBR sysctl 逐行写入，跳过 Alpine 不支持的参数 |
| V3.1.6 | Alpine ash 兼容（去除 bash 专属语法） |
| V3.0.4 | 快捷键改用纯软链接，不写 alias，避免冲突其他脚本 |
| V3.0.0 | 主菜单与 fork 同步，整合 BBR 智能向导 + DDNS 双栈 + Telegram |
