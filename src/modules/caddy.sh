# ══════════════════════════════════════════════════════════
#  Caddy 模块
# ══════════════════════════════════════════════════════════

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_LOG="/var/log/caddy/access.log"

# ── 检测 Caddy 状态 ───────────────────────────────────────
caddy_status() {
    if ! command -v caddy &>/dev/null; then
        echo "not_installed"
    elif svc_is_active caddy; then
        echo "running"
    else
        echo "stopped"
    fi
}

# ── 安装后初始化 ──────────────────────────────────────────

caddy_post_install() {
    mkdir -p /etc/caddy /var/log/caddy
    if [ ! -f "$CADDYFILE" ]; then
        cat > "$CADDYFILE" << 'CEOF'
# Caddy 配置文件 — 由 VPS 开荒脚本生成
# 文档：https://caddyserver.com/docs/caddyfile

# 反向代理示例：
# example.com {
#     reverse_proxy localhost:8080
# }

# 静态网站示例：
# example.com {
#     root * /var/www/html
#     file_server
# }
CEOF
        info "已创建默认 Caddyfile：$CADDYFILE"
    fi
    command -v caddy >/dev/null 2>&1 || { error "Caddy 可执行文件不存在"; return 1; }
    svc_enable caddy
    if ! svc_start caddy && ! caddy start --config "$CADDYFILE" &>/dev/null; then
        error "Caddy 启动失败"
        return 1
    fi
    info "Caddy 已启动 ✓"
}

# ── 安装 Caddy（apt/apk/yum/二进制）─────────────────────
caddy_install() {
    print_header "安装 Caddy"
    info "开始安装 Caddy..."
    echo ""

    if command -v apt-get &>/dev/null; then
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl &>/dev/null
        curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
            | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
            | tee /etc/apt/sources.list.d/caddy-stable.list &>/dev/null
        apt-get update -qq &>/dev/null
        if apt-get install -y caddy 2>/dev/null; then info "Caddy 安装成功 ✓"; else caddy_install_binary || return 1; fi
    elif command -v apk &>/dev/null; then
        if apk add --no-cache caddy 2>/dev/null; then info "Caddy 安装成功 ✓"; else caddy_install_binary || return 1; fi
    elif command -v yum &>/dev/null; then
        yum install -y yum-plugin-copr &>/dev/null
        yum copr enable @caddy/caddy -y &>/dev/null
        if yum install -y caddy 2>/dev/null; then info "Caddy 安装成功 ✓"; else caddy_install_binary || return 1; fi
    elif command -v dnf &>/dev/null; then
        dnf install -y yum-plugin-copr &>/dev/null
        dnf copr enable @caddy/caddy -y &>/dev/null
        if dnf install -y caddy 2>/dev/null; then info "Caddy 安装成功 ✓"; else caddy_install_binary || return 1; fi
    else
        caddy_install_binary || return 1
    fi

    caddy_post_install
}

# 二进制安装（通用回退）
caddy_install_binary() {
    info "从 GitHub 下载 Caddy 二进制..."
    local ARCH; ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) error "不支持的架构：$ARCH"; return 1 ;;
    esac

    local TMP; TMP=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/caddy_tmp_$$" && echo "/tmp/caddy_tmp_$$"; })
    local URL="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${ARCH}.tar.gz"

    if curl -fsSL "$URL" -o "$TMP/caddy.tar.gz"; then
        tar -xzf "$TMP/caddy.tar.gz" -C "$TMP" || { rm -rf "$TMP"; error "Caddy 压缩包解压失败"; return 1; }
        [ -f "$TMP/caddy" ] || { rm -rf "$TMP"; error "Caddy 压缩包缺少可执行文件"; return 1; }
        install -m 755 "$TMP/caddy" /usr/local/bin/caddy || { rm -rf "$TMP"; error "Caddy 安装失败"; return 1; }
        rm -rf "$TMP"
        info "Caddy 二进制安装到 /usr/local/bin/caddy ✓"
    else
        rm -rf "$TMP"
        error "下载失败，请检查网络"
        return 1
    fi

    # 创建 systemd service
    if systemd_available; then
        useradd -r -d /var/lib/caddy -s /sbin/nologin caddy 2>/dev/null || true
        cat > /etc/systemd/system/caddy.service << 'SVCEOF'
[Unit]
Description=Caddy Web Server
After=network.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCEOF
        svc_daemon_reload
    fi
}

# ── 卸载 Caddy ────────────────────────────────────────────
caddy_uninstall() {
    print_header "卸载 Caddy"
    warn "即将卸载 Caddy（配置文件保留）"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    svc_stop caddy || true
    svc_disable caddy
    pkg_remove caddy 2>/dev/null
    rm -f /usr/local/bin/caddy /etc/systemd/system/caddy.service
    svc_daemon_reload
    info "Caddy 已卸载 ✓（配置文件已保留）"
}

# ── 重载配置 ──────────────────────────────────────────────
# 安全追加 Caddy 配置块：先备份 → 追加 → validate，失败则还原，不污染正式配置
caddy_append_safe() {
    local BLOCK="$1"
    local TMP
    mkdir -p "$(dirname "$CADDYFILE")" || return 1
    TMP=$(mktemp "${CADDYFILE}.tmp.XXXXXX") || return 1
    if [ -f "$CADDYFILE" ]; then
        cp "$CADDYFILE" "$TMP" || { rm -f "$TMP"; return 1; }
    else
        : > "$TMP"
    fi
    printf '%s\n' "$BLOCK" >> "$TMP" || { rm -f "$TMP"; return 1; }
    if caddy validate --config "$TMP" 2>/tmp/caddy_err; then
        mv "$TMP" "$CADDYFILE" || { rm -f "$TMP"; return 1; }
        return 0
    fi
    rm -f "$TMP"
    error "新配置验证失败，已还原（未写入）："
    while IFS= read -r l; do echo -e "  ${RED}$l${NC}"; done < /tmp/caddy_err
    return 1
}

caddy_reload_config() {
    echo ""
    info "验证 Caddyfile 语法..."
    if caddy validate --config "$CADDYFILE" 2>/tmp/caddy_err; then
        info "语法验证通过 ✓"
        if svc_is_active caddy; then
            caddy reload --config "$CADDYFILE" 2>/dev/null || { error "Caddy 配置重载失败"; return 1; }
            info "配置已重载 ✓"
        else
            if ! svc_start caddy && ! caddy start --config "$CADDYFILE" &>/dev/null; then
                error "Caddy 启动失败"
                return 1
            fi
            info "Caddy 已启动 ✓"
        fi
    else
        error "Caddyfile 语法错误："
        while IFS= read -r l; do echo -e "  ${RED}$l${NC}"; done < /tmp/caddy_err
        return 1
    fi
}

# 输出 Caddyfile 中的站点与关键指令。只把顶层块识别为站点，避免把使用
# Tab 缩进的 reverse_proxy/header_up/transport 子块误列为独立站点。
caddy_site_records() {
    [ -f "$CADDYFILE" ] || return 0
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function without_comment(value) {
            sub(/[[:space:]]+#.*$/, "", value)
            return value
        }
        {
            line = trim(without_comment($0))
            if (line == "" || line ~ /^#/) next

            opens = (line ~ /\{[[:space:]]*$/) ? 1 : 0
            closes = (line ~ /^\}/) ? 1 : 0

            if (depth == 0 && opens) {
                header = line
                sub(/[[:space:]]*\{[[:space:]]*$/, "", header)
                header = trim(header)
                active_site = (header != "" && header !~ /^\([^)]*\)$/)
                if (active_site) print "site\t" header
            } else if (depth > 0 && active_site) {
                directive = line
                sub(/[[:space:]].*$/, "", directive)
                if (directive ~ /^(reverse_proxy|root|file_server|redir)$/) {
                    target = line
                    sub(/^[^[:space:]]+[[:space:]]*/, "", target)
                    sub(/[[:space:]]*\{[[:space:]]*$/, "", target)
                    print "directive\t" directive "\t" trim(target)
                }
            }

            depth += opens - closes
            if (depth <= 0) {
                depth = 0
                active_site = 0
            }
        }
    ' "$CADDYFILE"
}

caddy_site_count() {
    caddy_site_records | awk -F '\t' '$1 == "site" { count++ } END { print count + 0 }'
}

# ── 查看所有站点 ──────────────────────────────────────────
caddy_list_sites() {
    print_header "当前 Caddy 站点"
    if [ ! -f "$CADDYFILE" ]; then warn "Caddyfile 不存在"; return; fi

    menu_div
    local i=0 kind value target
    while IFS=$'\t' read -r kind value target; do
        case "$kind" in
            site)
                [ "$i" -gt 0 ] && echo ""
                i=$((i+1))
                echo -e "  ${GREEN}[$i]${NC} ${BOLD}${value}${NC}"
                ;;
            directive)
                if [ -n "$target" ]; then
                    echo -e "      ${DIM}${value}${NC} → ${CYAN}${target}${NC}"
                else
                    echo -e "      ${DIM}${value}${NC}"
                fi
                ;;
        esac
    done < <(caddy_site_records)
    [ "$i" -gt 0 ] && echo ""
    [ "$i" -eq 0 ] && echo -e "  ${YELLOW}暂无站点配置${NC}\n"
    menu_div
}

# ── 添加反向代理站点 ──────────────────────────────────────
caddy_add_proxy() {
    print_header "添加反向代理站点"
    echo -e "  ${DIM}Caddy 会自动申请 SSL 证书（需域名已解析到本机）${NC}"
    echo ""
    read -rp "  域名（如 example.com 或 example.com:36366）: " DOMAIN
    [ -z "$DOMAIN" ] && { warn "已取消"; return; }
    read -rp "  转发到（如 127.0.0.1:8080）: " BACKEND
    [ -z "$BACKEND" ] && { warn "已取消"; return; }

    if grep -q "^${DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        warn "域名 ${DOMAIN} 已存在，请先删除再添加"; return
    fi

    # 判断是否是带端口的域名（如 example.com:36366）
    local HAS_PORT=false
    local BARE_DOMAIN="$DOMAIN"
    if echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9].*:[0-9]+$'; then
        HAS_PORT=true
        BARE_DOMAIN=$(echo "$DOMAIN" | cut -d: -f1)
    fi

    # 判断是否是域名（非 IP）
    local IS_DOMAIN=false
    if echo "$BARE_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)+[a-zA-Z]{2,}$'; then
        IS_DOMAIN=true
    fi

    local SSL_LABEL CADDY_BLOCK
    if [ "$IS_DOMAIN" = true ]; then
        if [ "$HAS_PORT" = true ]; then
            # 带端口：检查裸域名站点是否存在（需先有裸域名才能复用证书）
            if grep -q "^${BARE_DOMAIN}" "$CADDYFILE" 2>/dev/null; then
                SSL_LABEL="${GREEN}复用 ${BARE_DOMAIN} 的证书 ✓${NC}"
            else
                SSL_LABEL="${YELLOW}注意：未找到 ${BARE_DOMAIN} 裸域名站点，建议先添加裸域名站点申请证书${NC}"
            fi
        else
            SSL_LABEL="${GREEN}自动 HTTPS（Let's Encrypt）${NC}"
        fi
        CADDY_BLOCK=$(printf '
%s {
    reverse_proxy %s
    encode gzip
}
' "$DOMAIN" "$BACKEND")
    else
        # IP 地址：不申请证书
        SSL_LABEL="${YELLOW}无 SSL（IP 地址无法申请证书）${NC}"
        CADDY_BLOCK=$(printf '
http://%s {
    reverse_proxy %s
}
' "$DOMAIN" "$BACKEND")
    fi

    echo ""
    menu_div
    echo -e "  域名 : ${BOLD}${DOMAIN}${NC}"
    echo -e "  后端 : ${BOLD}${BACKEND}${NC}"
    echo -e "  SSL  : ${SSL_LABEL}"
    menu_div
    echo ""
    read -rp "  确认添加？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    if caddy_append_safe "$CADDY_BLOCK"; then
        caddy_reload_config && info "站点 ${DOMAIN} 已添加 ✓"
    fi
}

# ── 添加静态网站 ──────────────────────────────────────────
caddy_add_static() {
    print_header "添加静态网站"
    echo -e "  ${DIM}Caddy 会自动申请 SSL 证书（需域名已解析到本机）${NC}"
    echo ""
    read -rp "  域名（如 example.com 或 example.com:8443）: " DOMAIN
    [ -z "$DOMAIN" ] && { warn "已取消"; return; }
    read -rp "  网站根目录（默认 /var/www/html）: " WEBROOT
    WEBROOT="${WEBROOT:-/var/www/html}"

    if grep -q "^${DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        warn "域名 ${DOMAIN} 已存在，请先删除再添加"; return
    fi

    local HAS_PORT=false
    local BARE_DOMAIN="$DOMAIN"
    if echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9].*:[0-9]+$'; then
        HAS_PORT=true
        BARE_DOMAIN=$(echo "$DOMAIN" | cut -d: -f1)
    fi

    local IS_DOMAIN=false
    if echo "$BARE_DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*\.)+[a-zA-Z]{2,}$'; then
        IS_DOMAIN=true
    fi

    local SSL_LABEL CADDY_BLOCK
    if [ "$IS_DOMAIN" = true ]; then
        if [ "$HAS_PORT" = true ]; then
            SSL_LABEL="${GREEN}复用 ${BARE_DOMAIN} 证书（需先添加裸域名站点申请证书）${NC}"
        else
            SSL_LABEL="${GREEN}自动 HTTPS（Let's Encrypt）${NC}"
        fi
        CADDY_BLOCK=$(printf '
%s {
    root * %s
    file_server
}
' "$DOMAIN" "$WEBROOT")
    else
        SSL_LABEL="${YELLOW}无 SSL（IP 地址无法申请证书）${NC}"
        CADDY_BLOCK=$(printf '
http://%s {
    root * %s
    file_server
}
' "$DOMAIN" "$WEBROOT")
    fi

    echo ""
    menu_div
    echo -e "  域名 : ${BOLD}${DOMAIN}${NC}"
    echo -e "  目录 : ${BOLD}${WEBROOT}${NC}"
    echo -e "  SSL  : ${SSL_LABEL}"
    menu_div
    echo ""
    read -rp "  确认添加？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    mkdir -p "$WEBROOT"
    if caddy_append_safe "$CADDY_BLOCK"; then
        caddy_reload_config && info "静态站点 ${DOMAIN} 已添加 ✓"
    fi
}

# ── 删除站点 ──────────────────────────────────────────────
caddy_del_site() {
    print_header "删除站点"
    caddy_list_sites

    # 收集所有站点
    local SITES=()
    local kind value
    while IFS=$'\t' read -r kind value; do
        [ "$kind" = "site" ] && SITES+=("$value")
    done < <(caddy_site_records)

    if [ ${#SITES[@]} -eq 0 ]; then warn "暂无站点配置"; return; fi

    echo ""
    local i=1
    for site in "${SITES[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} ${BOLD}${site}${NC}"
        i=$((i+1))
    done
    echo ""
    menu_div
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_read NUM "请输入编号删除（直接回车取消）: " || return 0
    [ "$NUM" = "0" ] && return 0
    [ -z "$NUM" ] && { warn "已取消"; return; }
    if ! echo "$NUM" | grep -qE '^[0-9]+$' || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#SITES[@]} ]; then
        error "无效编号"; return
    fi
    local DOMAIN="${SITES[$((NUM-1))]}"
    echo ""
    warn "即将删除站点：${BOLD}${DOMAIN}${NC}"
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    local TMP BAK
    TMP=$(mktemp "${CADDYFILE}.tmp.XXXXXX") || return 1
    BAK="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
    if ! python3 - "$CADDYFILE" "$TMP" "$DOMAIN" << 'PYEOF'
import sys
path, output, site_header = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()

def syntax_line(line):
    line = line.strip()
    if " #" in line:
        line = line.split(" #", 1)[0].rstrip()
    return line

def block_delta(line):
    return int(line.endswith("{")) - int(line.startswith("}"))

result = []
skip = False
depth = 0
found = False
for line in lines:
    s = syntax_line(line)
    opening_header = s[:-1].strip() if s.endswith("{") else ""
    if not skip and depth == 0 and opening_header == site_header:
        skip = True
        found = True
        depth = 1
        while result and result[-1].strip() == '':
            result.pop()
        continue
    if skip:
        depth += block_delta(s)
        if depth <= 0:
            skip = False
            depth = 0
        continue
    result.append(line)
    depth += block_delta(s)
    if depth < 0:
        depth = 0
if not found:
    raise SystemExit(2)
with open(output, 'w') as f:
    f.writelines(result)
PYEOF
    then
        rm -f "$TMP"
        error "无法生成删除后的 Caddy 配置"
        return 1
    fi
    if ! caddy validate --config "$TMP" 2>/tmp/caddy_err; then
        rm -f "$TMP"
        error "删除后的 Caddy 配置验证失败，原配置未修改"
        return 1
    fi
    cp "$CADDYFILE" "$BAK" || { rm -f "$TMP"; return 1; }
    mv "$TMP" "$CADDYFILE" || { rm -f "$TMP"; return 1; }
    if caddy_reload_config; then
        rm -f "$BAK"
        info "站点 ${DOMAIN} 已删除 ✓"
    else
        cp "$BAK" "$CADDYFILE" 2>/dev/null || true
        rm -f "$BAK"
        caddy_reload_config >/dev/null 2>&1 || true
        error "站点删除应用失败，已恢复原配置"
        return 1
    fi
}

# ── SSL 证书状态 ──────────────────────────────────────────
caddy_ssl_status() {
    print_header "SSL 证书状态"
    echo -e "  ${DIM}Caddy 自动管理证书，首次访问时自动申请${NC}"
    echo ""

    local CERT_DIR=""
    for d in /var/lib/caddy/.local/share/caddy/certificates \
              /root/.local/share/caddy/certificates \
              /home/caddy/.local/share/caddy/certificates; do
        [ -d "$d" ] && CERT_DIR="$d" && break
    done

    if [ -z "$CERT_DIR" ]; then
        warn "未找到证书目录（证书将在首次访问时自动申请）"
        return
    fi

    echo -e "  证书目录：${DIM}${CERT_DIR}${NC}"
    menu_div
    find "$CERT_DIR" -name "*.crt" 2>/dev/null | while read -r cert; do
        local DN; DN=$(basename "$(dirname "$cert")")
        local EXP; EXP=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        echo -e "  ${GREEN}▸${NC} ${BOLD}${DN}${NC}"
        [ -n "$EXP" ] && echo -e "    ${DIM}到期：${NC}${EXP}"
    done
    menu_div
}

# ── 查看访问日志 ──────────────────────────────────────────
caddy_view_logs() {
    print_header "Caddy 访问日志"
    local LOG_FILE="$CADDY_LOG"
    [ ! -f "$LOG_FILE" ] && LOG_FILE=$(find /var/log/caddy /var/log -name "*.log" 2>/dev/null | grep -i caddy | head -1)

    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        if command -v journalctl &>/dev/null; then
            echo -e "  ${DIM}使用 journalctl${NC}"
            echo ""
            journalctl -u caddy -n 50 --no-pager 2>/dev/null | while IFS= read -r line; do
                echo -e "  $line"
            done
            echo ""
            menu_item "1" "开启实时跟踪  ${DIM}Ctrl+C 返回${NC}"
            menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
            echo ""
            menu_read _CH '选择操作: ' || return 0
            if [ "$_CH" = "1" ]; then
                trap 'echo ""; info "已退出实时跟踪"; trap - INT' INT
                journalctl -u caddy -f 2>/dev/null
                trap - INT
            fi
        else
            warn "未找到 Caddy 日志文件，请确认 Caddyfile 中已配置 log 指令"
        fi
        return
    fi

    echo -e "  ${DIM}${LOG_FILE}${NC}"
    menu_div
    echo ""
    tail -n 30 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        local STATUS; STATUS=$(echo "$line" | python3 -c \
            "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('status',''))
except: print('')" 2>/dev/null)
        if [ -n "$STATUS" ]; then
            local SC="$GREEN"
            [ "$STATUS" -ge 400 ] 2>/dev/null && SC="$YELLOW"
            [ "$STATUS" -ge 500 ] 2>/dev/null && SC="$RED"
            local TS METHOD URI
            TS=$(echo "$line" | python3 -c \
                "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('ts','')[:19].replace('T',' '))
except: print('')" 2>/dev/null)
            METHOD=$(echo "$line" | python3 -c \
                "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('request',{}).get('method',''))
except: print('')" 2>/dev/null)
            URI=$(echo "$line" | python3 -c \
                "import sys,json
try:
    d=json.loads(sys.stdin.read())
    print(d.get('request',{}).get('uri',''))
except: print('')" 2>/dev/null)
            echo -e "  ${DIM}${TS}${NC} ${BOLD}${METHOD}${NC} ${URI} ${SC}${STATUS}${NC}"
        else
            echo -e "  $line"
        fi
    done
    echo ""
    menu_div
    menu_item "1" "开启实时跟踪  ${DIM}Ctrl+C 返回${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    menu_read _CH '选择操作: ' || return 0
    if [ "$_CH" = "1" ]; then
        trap 'echo ""; info "已退出实时跟踪"; trap - INT' INT
        tail -f "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do echo -e "  $line"; done
        trap - INT
    fi
}

# ── 编辑 Caddyfile ────────────────────────────────────────
caddy_edit_raw() {
    print_header "编辑 Caddyfile"
    echo -e "  配置文件：${BOLD}${CADDYFILE}${NC}"
    echo ""
    warn "$(get_editor) 打开 Caddyfile，保存退出后自动验证并重载"
    echo ""
    ui_continue
    [ -f "$CADDYFILE" ] || { mkdir -p /etc/caddy; touch "$CADDYFILE"; }
    local BAK
    BAK="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$CADDYFILE" "$BAK" || { error "无法备份 Caddyfile"; return 1; }
    open_editor "$CADDYFILE"
    echo ""
    if caddy_reload_config; then
        rm -f "$BAK"
    else
        cp "$BAK" "$CADDYFILE" 2>/dev/null || true
        rm -f "$BAK"
        error "编辑后的配置无效，已恢复原文件"
        return 1
    fi
}

# ── Caddy 主菜单 ──────────────────────────────────────────
caddy_menu() {
    while true; do
        local C_ST; C_ST=$(caddy_status)
        local C_COLOR
        case "$C_ST" in
            running)       C_COLOR="$GREEN" ;;
            stopped)       C_COLOR="$RED" ;;
            not_installed) C_COLOR="$YELLOW" ;;
        esac

        print_header "Caddy 管理"

        if [ "$C_ST" = "not_installed" ]; then
            echo -e "  服务状态: ${C_COLOR}${BOLD}未安装${NC}"
            echo ""
            echo -e "  ${DIM}Caddy 是一个自动 HTTPS 的现代 Web 服务器，支持反向代理和静态托管${NC}"
            echo ""
            menu_div
            menu_item "1" "立即安装 Caddy"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            menu_div
            echo ""
            menu_read CH '选择操作 [0-1]: ' || return 0
            case "$CH" in
                1) caddy_install; ui_continue ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi

        local C_VER; C_VER=$(caddy version 2>/dev/null | awk '{print $1}')
        local SITE_COUNT; SITE_COUNT=$(caddy_site_count)

        echo -e "  服务: ${C_COLOR}${BOLD}${C_ST}${NC}  版本: ${BOLD}${C_VER:-未知}${NC}  站点数: ${BOLD}${SITE_COUNT}${NC}"
        echo ""
        menu_div
        menu_pair "1" "查看站点" "2" "添加反向代理"
        menu_pair "3" "添加静态网站" "4" "删除站点"
        menu_pair "5" "SSL 证书状态" "6" "查看日志"
        menu_pair "7" "编辑 Caddyfile" "8" "重载配置"
        if [ "$C_ST" = "running" ]; then
            menu_item "9" "停止服务" "$YELLOW"
        else
            menu_item "9" "启动服务"
        fi
        menu_pair "u" "安装 / 更新" "d" "卸载 Caddy" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作: ' || return 0

        case "$CH" in
            1) caddy_list_sites ;;
            2) caddy_add_proxy ;;
            3) caddy_add_static ;;
            4) caddy_del_site ;;
            5) caddy_ssl_status ;;
            6) caddy_view_logs ;;
            7) caddy_edit_raw ;;
            8) caddy_reload_config ;;
            u|U)
                print_header "安装/更新 Caddy"
                info "正在更新 Caddy..."
                caddy_install
                local NEW_VER; NEW_VER=$(caddy version 2>/dev/null | awk '{print $1}')
                info "当前版本：${NEW_VER:-未知} ✓"
                ;;
            9)
                if [ "$C_ST" = "running" ]; then
                    svc_stop caddy
                    info "Caddy 已停止 ✓"
                else
                    svc_start caddy \
                        || caddy start --config "$CADDYFILE" &>/dev/null
                    info "Caddy 已启动 ✓"
                fi
                sleep 1; continue
                ;;
            d|D) caddy_uninstall ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}
