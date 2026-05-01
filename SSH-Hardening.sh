#!/bin/bash

# ============================================================
#  VPS 开荒脚本 — 银趴火山帮
#  功能：SSH管理 / Fail2ban / BBR TCP 调优
# ============================================================

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTH_KEYS="$HOME/.ssh/authorized_keys"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
error() { echo -e "  ${RED}✘${NC}  $1"; }

# ── 可见宽度计算（用 python3，中文=2，ASCII=1）────────────
vis_len() {
    python3 -c "
import unicodedata, sys
s = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in s))
" "$1" 2>/dev/null || echo "${#1}"
}

# ── 边框常量（可见字符宽度）──────────────────────────────
BOX_W=42   # 总宽含两侧 ║

# 顶/底/分隔线
box_top() { printf "${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_bot() { printf "${CYAN}"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }
box_sep() { printf "${CYAN}"; printf '─%.0s' $(seq 1 $((BOX_W-2))); printf "${NC}\n"; }

# 居中标题行（只传纯文本，自动居中）
box_title() {
    local TEXT="$1"
    local LEN; LEN=$(vis_len "$TEXT")
    local INNER=$((BOX_W - 2))
    local PAD_TOTAL=$(( INNER - LEN ))
    local PAD_L=$(( PAD_TOTAL / 2 ))
    local PAD_R=$(( PAD_TOTAL - PAD_L ))
    printf '%*s' "$PAD_L" ''
    printf "${BOLD}${CYAN}%s${NC}" "$TEXT"
    printf '%*s' "$PAD_R" ''
    printf "\n"
}

# 普通内容行：PLAIN=纯文本(算宽度)  COLORED=带色码(显示用)
# 用法: box_line "纯文本" "带色码文本"
box_line() {
    local PLAIN="$1"
    local COLORED="${2:-$1}"
    echo -e "$COLORED"
}

# 空行
box_empty() {
    echo ""
}

# 统一标题栏
print_header() {
    clear
    echo ""
    box_top
    box_title "VPS 开荒脚本"
    box_line "  ··银趴火山帮··" "  ${DIM}··银趴火山帮··${NC}"
    box_sep
    box_title "$1"
    box_bot
    echo ""
}

# ── 权限检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ── 通用工具函数 ──────────────────────────────────────────
get_config() {
    grep -E "^[[:space:]]*$1[[:space:]]" "$SSHD_CONFIG" 2>/dev/null \
        | tail -1 | awk '{print $2}'
}

set_config() {
    local KEY="$1" VALUE="$2"
    if grep -qE "^#?[[:space:]]*${KEY}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i "s|^#\?[[:space:]]*${KEY}[[:space:]].*|${KEY} ${VALUE}|" "$SSHD_CONFIG"
    else
        echo "${KEY} ${VALUE}" >> "$SSHD_CONFIG"
    fi
}

backup_config() {
    local BACKUP="$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP"
    info "配置已备份：$BACKUP"
}

apply_and_restart() {
    if ! sshd -t 2>/dev/null; then
        error "配置文件语法错误，已取消应用"
        return 1
    fi
    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        info "SSH 服务已重启 ✓"
    else
        error "SSH 服务重启失败，请手动执行：systemctl restart ssh"
        return 1
    fi
}

list_keys() {
    if [ ! -f "$AUTH_KEYS" ] || ! grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null; then
        echo -e "  ${YELLOW}（暂无公钥）${NC}"
        return 1
    fi
    local i=1
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
            local TYPE COMMENT FINGER
            TYPE=$(echo "$line" | awk '{print $1}')
            COMMENT=$(echo "$line" | awk '{print $3}')
            FINGER=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || echo "N/A")
            echo -e "  ${GREEN}[$i]${NC} ${BOLD}$TYPE${NC}"
            echo -e "      ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
            echo -e "      ${DIM}备注：${NC}${YELLOW}${COMMENT:-（无备注）}${NC}"
            echo ""
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"
    return 0
}

firewall_allow_port() {
    local PORT="$1"
    local UFW_ACTIVE=false FIREWALLD_ACTIVE=false IPTABLES_ACTIVE=false

    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && UFW_ACTIVE=true
    command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null && FIREWALLD_ACTIVE=true
    if command -v iptables &>/dev/null; then
        local RULES
        RULES=$(iptables -L INPUT --line-numbers 2>/dev/null             | grep -v "^Chain\|^num\|^$\|ACCEPT.*all.*anywhere.*anywhere" | wc -l)
        [ "$RULES" -gt 0 ] && IPTABLES_ACTIVE=true
    fi

    if [ "$UFW_ACTIVE" = false ] && [ "$FIREWALLD_ACTIVE" = false ] && [ "$IPTABLES_ACTIVE" = false ]; then
        info "未检测到活跃防火墙，跳过端口放行"
        return 0
    fi

    echo ""
    warn "检测到活跃防火墙，是否自动放行新端口 ${PORT}/tcp？"
    read -rp "  自动放行？(yes/no，默认 yes): " FW_CONFIRM
    FW_CONFIRM="${FW_CONFIRM:-yes}"
    if [ "$FW_CONFIRM" != "yes" ]; then
        warn "已跳过，请在防火墙管理中手动添加端口 $PORT"
        return 0
    fi

    if [ "$UFW_ACTIVE" = true ]; then
        ufw allow "${PORT}"/tcp 2>/dev/null && info "ufw 已放行 ${PORT}/tcp ✓"
    fi
    if [ "$FIREWALLD_ACTIVE" = true ]; then
        firewall-cmd --permanent --add-port="${PORT}/tcp" 2>/dev/null &&         firewall-cmd --reload 2>/dev/null &&         info "firewalld 已放行 ${PORT}/tcp ✓"
    fi
    if [ "$IPTABLES_ACTIVE" = true ]; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        [ -f /etc/iptables/rules.v4 ] && iptables-save > /etc/iptables/rules.v4
        info "iptables 已放行 ${PORT}/tcp ✓"
    fi
}

# ══════════════════════════════════════════════════════════
#  功能模块
# ══════════════════════════════════════════════════════════

show_keys() {
    print_header "查看已有公钥"
    list_keys
}

add_key() {
    print_header "添加 SSH 公钥"
    echo -e "  请粘贴公钥内容（以 ssh-ed25519 / ssh-rsa 等开头）"
    echo -e "  粘贴完成后按 ${BOLD}Enter${NC}，再按 ${BOLD}Ctrl+D${NC} 结束输入："
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""

    if [ -z "$PUBKEY_INPUT" ]; then
        warn "未输入任何内容，已取消。"
        return
    fi
    if ! echo "$PUBKEY_INPUT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
        error "公钥格式不正确，应以密钥类型开头（如 ssh-ed25519）。"
        return
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    echo "$PUBKEY_INPUT" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"

    local TOTAL
    TOTAL=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS")
    info "公钥已添加！当前共 $TOTAL 个公钥 ✓"
}

delete_key() {
    print_header "删除 SSH 公钥"

    if ! list_keys; then
        return
    fi

    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    read -rp "  请输入要删除的编号（直接回车取消）: " DEL_NUM
    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"; return
    fi

    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then TARGET_LINE="$line"; break; fi
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"

    if [ -z "$TARGET_LINE" ]; then
        error "编号 $DEL_NUM 不存在。"; return
    fi

    echo ""
    warn "即将删除以下公钥："
    echo -e "  ${RED}$(echo "$TARGET_LINE" | awk '{print $1, $3}')${NC}"
    echo ""
    read -rp "  确认删除？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消。"; return; }

    grep -vF "$TARGET_LINE" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    info "公钥已删除 ✓"
}

generate_key() {
    print_header "生成 SSH 密钥对"

    echo -e "  选择密钥类型："
    echo -e "  ${GREEN}1${NC}) Ed25519  ${YELLOW}[推荐，更安全更短]${NC}"
    echo -e "  ${GREEN}2${NC}) RSA 4096"
    echo -e "  ${GREEN}0${NC}) 返回"
    echo ""
    read -rp "  请选择 [0-2]: " KEY_TYPE_CHOICE

    case "$KEY_TYPE_CHOICE" in
        0) return ;;
        1) KEY_TYPE="ed25519"; KEY_BITS="" ;;
        2) KEY_TYPE="rsa";     KEY_BITS="-b 4096" ;;
        *) warn "无效选项，已取消。"; return ;;
    esac

    echo ""
    read -rp "  输入密钥备注（如 mypc@home，直接回车跳过）: " KEY_COMMENT
    KEY_COMMENT="${KEY_COMMENT:-ssh-key-$(date +%Y%m%d)}"

    local TMP_DIR KEY_FILE
    TMP_DIR=$(mktemp -d)
    KEY_FILE="$TMP_DIR/id_${KEY_TYPE}"

    echo ""
    info "正在生成 $KEY_TYPE 密钥对..."

    if ! ssh-keygen -t "$KEY_TYPE" $KEY_BITS -C "$KEY_COMMENT" -f "$KEY_FILE" -N "" -q 2>/dev/null; then
        error "密钥生成失败。"; rm -rf "$TMP_DIR"; return
    fi

    local PUBKEY PRIVKEY FINGER
    PUBKEY=$(cat "${KEY_FILE}.pub")
    PRIVKEY=$(cat "$KEY_FILE")
    FINGER=$(ssh-keygen -lf "${KEY_FILE}.pub" 2>/dev/null | awk '{print $2}')

    print_header "密钥生成完成 — 请复制保存"

    echo -e "  ${DIM}类型：${NC}${BOLD}$KEY_TYPE${NC}   ${DIM}备注：${NC}${YELLOW}$KEY_COMMENT${NC}"
    echo -e "  ${DIM}指纹：${NC}${BLUE}$FINGER${NC}"
    echo ""
    echo -e "  ${BOLD}${RED}┌─── 私钥（仅显示一次，请立即复制！）───┐${NC}"
    echo ""
    echo "$PRIVKEY"
    echo ""
    echo -e "  ${BOLD}${RED}└────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}┌─── 公钥（可添加到服务器）─────────────┐${NC}"
    echo ""
    echo "$PUBKEY"
    echo ""
    echo -e "  ${BOLD}${GREEN}└────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    warn "私钥请立即复制到本地保存，关闭后无法找回！"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""

    read -rp "  是否将公钥添加到本服务器？(yes/no): " ADD_CONFIRM
    if [ "$ADD_CONFIRM" = "yes" ]; then
        mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
        echo "$PUBKEY" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
        local TOTAL
        TOTAL=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS")
        echo ""
        info "公钥已添加到服务器！当前共 $TOTAL 个公钥 ✓"
    else
        warn "已跳过，公钥未添加到服务器。"
    fi

    rm -rf "$TMP_DIR"
}

set_login_mode() {
    print_header "登录方式设置"

    local CURRENT_PWD CURRENT_PUBKEY CURRENT_ROOT
    CURRENT_PWD=$(get_config "PasswordAuthentication")
    CURRENT_PUBKEY=$(get_config "PubkeyAuthentication")
    CURRENT_ROOT=$(get_config "PermitRootLogin")

    echo -e "  ${DIM}当前配置：${NC}"
    echo -e "  PasswordAuthentication : ${BOLD}${CURRENT_PWD:-未设置}${NC}"
    echo -e "  PubkeyAuthentication   : ${BOLD}${CURRENT_PUBKEY:-未设置}${NC}"
    echo -e "  PermitRootLogin        : ${BOLD}${CURRENT_ROOT:-未设置}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 仅密钥登录（禁用密码）    ${YELLOW}[推荐]${NC}"
    echo -e "  ${GREEN}2${NC}) 密码 + 密钥均可登录"
    echo -e "  ${GREEN}3${NC}) 仅密码登录（禁用密钥）    ${RED}[不推荐]${NC}"
    echo -e "  ${GREEN}0${NC}) 返回"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-3]: " MODE
    echo ""

    case "$MODE" in
        1)
            local KEYCOUNT
            KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)
        local F2B_STAT; F2B_STAT=$(f2b_status)
            if [ "$KEYCOUNT" -eq 0 ]; then
                warn "当前没有公钥！启用仅密钥登录后将无法通过密码登录！"
                read -rp "  仍要继续？(yes/no): " FORCE
                [ "$FORCE" != "yes" ] && { warn "已取消。"; return; }
            fi
            backup_config
            set_config "PasswordAuthentication" "no"
            set_config "PubkeyAuthentication"   "yes"
            set_config "PermitRootLogin"        "prohibit-password"
            apply_and_restart && info "已切换：仅密钥登录 ✓"
            ;;
        2)
            backup_config
            set_config "PasswordAuthentication" "yes"
            set_config "PubkeyAuthentication"   "yes"
            set_config "PermitRootLogin"        "yes"
            apply_and_restart && info "已切换：密码 + 密钥均可登录 ✓"
            ;;
        3)
            warn "仅密码登录安全性较低，建议配合强密码使用！"
            read -rp "  确认切换？(yes/no): " CONFIRM
            [ "$CONFIRM" != "yes" ] && { warn "已取消。"; return; }
            backup_config
            set_config "PasswordAuthentication" "yes"
            set_config "PubkeyAuthentication"   "no"
            set_config "PermitRootLogin"        "yes"
            apply_and_restart && info "已切换：仅密码登录 ✓"
            ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) return ;;
    esac
}

change_port() {
    print_header "修改 SSH 端口"

    local CURRENT_PORT
    CURRENT_PORT=$(get_config "Port")
    echo -e "  当前端口：${BOLD}${CURRENT_PORT:-22}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    read -rp "  请输入新端口号（直接回车取消）: " INPUT_PORT
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""

    [ -z "$INPUT_PORT" ] && { warn "已取消。"; return; }

    if ! echo "$INPUT_PORT" | grep -qE '^[0-9]+$' || [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        error "无效端口号（请输入 1-65535）。"; return
    fi

    if [ "$INPUT_PORT" = "${CURRENT_PORT:-22}" ]; then
        warn "端口未变化，无需修改。"; return
    fi

    backup_config
    set_config "Port" "$INPUT_PORT"

    if ! sshd -t 2>/dev/null; then
        error "配置语法错误，已取消。"; return
    fi

    firewall_allow_port "$INPUT_PORT"
    apply_and_restart || return

    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    warn "请【保持当前连接不断开】，新开终端测试新端口："
    echo ""
    echo -e "     ${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    echo ""
    warn "确认登录成功后再关闭当前会话！"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
}


# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════

# 检测 fail2ban 是否已安装并运行
f2b_status() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "not_installed"
    elif systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 安装 fail2ban
f2b_install() {
    print_header "安装 Fail2ban"
    info "正在更新软件包列表..."
    apt-get update -qq 2>/dev/null || yum makecache -q 2>/dev/null || true

    info "正在安装 fail2ban..."
    if apt-get install -y fail2ban 2>/dev/null || yum install -y fail2ban 2>/dev/null; then
        # 创建基础 jail.local（如果不存在）
        if [ ! -f /etc/fail2ban/jail.local ]; then
            cat > /etc/fail2ban/jail.local << 'JAILEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = auto

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
JAILEOF
            info "已创建默认配置 /etc/fail2ban/jail.local"
        fi
        systemctl enable fail2ban --quiet 2>/dev/null
        systemctl start fail2ban 2>/dev/null
        info "Fail2ban 安装并启动成功 ✓"
    else
        error "安装失败，请检查网络或手动安装：apt install fail2ban"
    fi
}

# ── 基础参数配置 ──────────────────────────────────────────
f2b_config_params() {
    print_header "Fail2ban 基础参数配置"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    # 读取当前值
    local CUR_BAN CUR_FIND CUR_MAX
    CUR_BAN=$(grep -E "^bantime\s*=" "$JAIL_LOCAL" 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
    CUR_FIND=$(grep -E "^findtime\s*=" "$JAIL_LOCAL" 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
    CUR_MAX=$(grep -E "^maxretry\s*=" "$JAIL_LOCAL" 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
    [ -z "$CUR_BAN"  ] && CUR_BAN="3600"
    [ -z "$CUR_FIND" ] && CUR_FIND="600"
    [ -z "$CUR_MAX"  ] && CUR_MAX="5"

    echo -e "  当前配置："
    echo -e "  封禁时长  (bantime)  : ${BOLD}${CUR_BAN}${NC} 秒  $(( CUR_BAN / 60 )) 分钟"
    echo -e "  时间窗口  (findtime) : ${BOLD}${CUR_FIND}${NC} 秒  $(( CUR_FIND / 60 )) 分钟"
    echo -e "  最大重试  (maxretry) : ${BOLD}${CUR_MAX}${NC} 次"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 修改封禁时长   (bantime)"
    echo -e "  ${GREEN}2${NC}) 修改时间窗口   (findtime)"
    echo -e "  ${GREEN}3${NC}) 修改最大重试次数 (maxretry)"
    echo -e "  ${GREEN}4${NC}) 快速预设"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-4]: " CH

    case "$CH" in
        1)
            echo ""
            echo -e "  常用参考：3600=1小时  86400=1天  604800=7天  -1=永久"
            read -rp "  请输入新的 bantime（秒）: " VAL
            [[ "$VAL" =~ ^-?[0-9]+$ ]] || { error "无效数值"; return; }
            f2b_set_param "bantime" "$VAL"
            ;;
        2)
            echo ""
            echo -e "  常用参考：300=5分钟  600=10分钟  3600=1小时"
            read -rp "  请输入新的 findtime（秒）: " VAL
            [[ "$VAL" =~ ^[0-9]+$ ]] || { error "无效数值"; return; }
            f2b_set_param "findtime" "$VAL"
            ;;
        3)
            echo ""
            echo -e "  常用参考：3=严格  5=默认  10=宽松"
            read -rp "  请输入新的 maxretry（次）: " VAL
            [[ "$VAL" =~ ^[0-9]+$ ]] || { error "无效数值"; return; }
            f2b_set_param "maxretry" "$VAL"
            ;;
        4)
            echo ""
            echo -e "  ${GREEN}1${NC}) 严格模式  — 封禁1天  窗口10分钟  最多3次"
            echo -e "  ${GREEN}2${NC}) 标准模式  — 封禁1小时 窗口10分钟  最多5次"
            echo -e "  ${GREEN}3${NC}) 宽松模式  — 封禁30分钟 窗口5分钟  最多10次"
            echo -e "  ${GREEN}4${NC}) 永久封禁  — 封禁永久  窗口10分钟  最多3次"
            echo ""
            read -rp "  请选择预设 [1-4]: " PRESET
            case "$PRESET" in
                1) f2b_set_param "bantime" "86400";  f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "3" ;;
                2) f2b_set_param "bantime" "3600";   f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "5" ;;
                3) f2b_set_param "bantime" "1800";   f2b_set_param "findtime" "300"; f2b_set_param "maxretry" "10" ;;
                4) f2b_set_param "bantime" "-1";     f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "3" ;;
                *) warn "无效选项"; return ;;
            esac
            ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    echo ""
    info "重启 Fail2ban 使配置生效..."
    systemctl restart fail2ban 2>/dev/null && info "Fail2ban 已重启 ✓" || error "重启失败"
}

# 写入参数到 jail.local
f2b_set_param() {
    local KEY="$1" VAL="$2"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"

    # 确保文件存在且有 [DEFAULT] 节
    if [ ! -f "$JAIL_LOCAL" ]; then
        echo -e "[DEFAULT]" > "$JAIL_LOCAL"
    fi
    if ! grep -q "^\[DEFAULT\]" "$JAIL_LOCAL"; then
        sed -i "1i [DEFAULT]" "$JAIL_LOCAL"
    fi

    if grep -qE "^${KEY}\s*=" "$JAIL_LOCAL"; then
        sed -i "s|^${KEY}\s*=.*|${KEY} = ${VAL}|" "$JAIL_LOCAL"
    else
        sed -i "/^\[DEFAULT\]/a ${KEY} = ${VAL}" "$JAIL_LOCAL"
    fi
    info "${KEY} 已设置为 ${VAL} ✓"
}

# ── 编辑配置文件 ──────────────────────────────────────────
f2b_edit_config() {
    print_header "编辑 Fail2ban 配置文件"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"
    local JAIL_CONF="/etc/fail2ban/jail.conf"

    echo -e "  ${GREEN}1${NC}) 编辑 jail.local  ${YELLOW}（推荐，用户自定义配置）${NC}"
    echo -e "  ${GREEN}2${NC}) 查看 jail.conf    ${DIM}（系统默认配置，只读参考）${NC}"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-2]: " CH

    case "$CH" in
        1)
            if [ ! -f "$JAIL_LOCAL" ]; then
                warn "jail.local 不存在，正在创建默认模板..."
                cat > "$JAIL_LOCAL" << 'JAILEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = auto

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
JAILEOF
                info "已创建 $JAIL_LOCAL"
            fi
            echo ""
            warn "即将用 nano 打开 $JAIL_LOCAL"
            warn "编辑完成后按 Ctrl+O 保存，Ctrl+X 退出"
            echo ""
            read -rp "  按 Enter 继续..." _
            nano "$JAIL_LOCAL"
            echo ""
            read -rp "  是否重启 Fail2ban 使配置生效？(yes/no): " RESTART
            [ "$RESTART" = "yes" ] && systemctl restart fail2ban && info "Fail2ban 已重启 ✓"
            ;;
        2)
            if [ -f "$JAIL_CONF" ]; then
                echo ""
                echo -e "  ${DIM}--- $JAIL_CONF（只读）---${NC}"
                echo ""
                less "$JAIL_CONF"
            else
                warn "$JAIL_CONF 不存在"
            fi
            ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 卸载 Fail2ban ─────────────────────────────────────────
f2b_uninstall() {
    print_header "卸载 Fail2ban"
    warn "即将卸载 Fail2ban，所有配置将被清除！"
    echo ""
    read -rp "  确认卸载？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消"; return; }

    systemctl stop fail2ban 2>/dev/null
    systemctl disable fail2ban 2>/dev/null
    if apt-get remove -y fail2ban 2>/dev/null || yum remove -y fail2ban 2>/dev/null; then
        info "Fail2ban 已卸载 ✓"
    else
        error "卸载失败，请手动执行：apt remove fail2ban"
    fi
}

# ── Fail2ban 主菜单 ───────────────────────────────────────
fail2ban_menu() {
    while true; do
        # 获取状态
        local F2B_ST; F2B_ST=$(f2b_status)

        # 若未安装，提示安装
        if [ "$F2B_ST" = "not_installed" ]; then
            print_header "Fail2ban 管理"
            warn "检测到 Fail2ban 未安装！"
            echo ""
            echo -e "  ${GREEN}1${NC}) 立即安装 Fail2ban"
            echo -e "  ${RED}0${NC}) 返回主菜单"
            echo -e "  ${RED}00${NC}) 退出脚本"
            echo ""
            read -rp "  请选择 [0-1]: " CHOICE
            case "$CHOICE" in
                1) f2b_install ;;
                0) return ;;
                00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            echo ""; read -rp "  按 Enter 继续..." _
            continue
        fi

        # 已安装 — 收集数据
        local F2B_COLOR BANNED_COUNT TOTAL_FAIL JAIL_NAME
        [ "$F2B_ST" = "running" ] && F2B_COLOR="$GREEN" || F2B_COLOR="$RED"

        # 自动找 SSH jail 名称（sshd / ssh）
        JAIL_NAME=$(fail2ban-client status 2>/dev/null | grep -oE 'sshd?'| head -1)
        JAIL_NAME="${JAIL_NAME:-sshd}"

        if [ "$F2B_ST" = "running" ]; then
            BANNED_COUNT=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null                 | grep "Currently banned" | awk -F: '"'"'{gsub(/ /,"",$2); print $2}'"'"' || echo 0)
            TOTAL_FAIL=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null                 | grep "Total failed" | awk -F: '"'"'{gsub(/ /,"",$2); print $2}'"'"' || echo 0)
        else
            BANNED_COUNT="-"; TOTAL_FAIL="-"
        fi

        clear
        echo ""
        box_top
        box_title "VPS 开荒脚本"
        box_line "  ··银趴火山帮··" "  ${DIM}··银趴火山帮··${NC}"
        box_sep
        box_title "Fail2ban 管理"
        box_sep
        box_line "  服务状态: ${F2B_ST}"                  "  服务状态: ${F2B_COLOR}${BOLD}${F2B_ST}${NC}"
        box_line "  SSH jail: ${JAIL_NAME}  封禁: ${BANNED_COUNT}  失败: ${TOTAL_FAIL}"                  "  SSH jail: ${BOLD}${JAIL_NAME}${NC}  封禁: ${RED}${BOLD}${BANNED_COUNT}${NC}  失败: ${YELLOW}${BOLD}${TOTAL_FAIL}${NC}"
        box_sep
        box_line "  1) 查看封禁 IP 列表" "  ${GREEN}1${NC}) 查看封禁 IP 列表"
        box_line "  2) 手动解封 IP"      "  ${GREEN}2${NC}) 手动解封 IP"
        box_line "  3) 实时日志"         "  ${GREEN}3${NC}) 实时日志"
        box_line "  4) 基础参数配置"     "  ${GREEN}4${NC}) 基础参数配置"
        box_line "  5) 编辑配置文件"     "  ${GREEN}5${NC}) 编辑配置文件"
        box_line "  6) 卸载 Fail2ban"    "  ${YELLOW}6${NC}) 卸载 Fail2ban"
        if [ "$F2B_ST" = "running" ]; then
            box_line "  7) 停止服务"     "  ${YELLOW}7${NC}) 停止服务"
        else
            box_line "  7) 启动服务"     "  ${GREEN}7${NC}) 启动服务"
        fi
        box_line "  0) 返回主菜单"       "  ${RED}0${NC}) 返回主菜单"
        box_line "  00) 退出脚本"        "  ${RED}00${NC}) 退出脚本"
        box_bot
        echo ""
        read -rp "  请选择 [0-7]: " CHOICE

        case "$CHOICE" in
            1) f2b_banned_list "$JAIL_NAME" ;;
            2) f2b_unban "$JAIL_NAME" ;;
            3) f2b_logs ;;
            4) f2b_config_params ;;
            5) f2b_edit_config ;;
            6) f2b_uninstall ;;
            7)
                if [ "$F2B_ST" = "running" ]; then
                    systemctl stop fail2ban && info "Fail2ban 已停止" || error "停止失败"
                else
                    systemctl start fail2ban && info "Fail2ban 已启动" || error "启动失败"
                fi
                sleep 1; continue
                ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CHOICE}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ── 查看封禁 IP 列表 ──────────────────────────────────────
f2b_banned_list() {
    local JAIL="${1:-sshd}"
    print_header "封禁 IP 列表 — $JAIL"

    local RAW
    RAW=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list:\s*//')

    if [ -z "$RAW" ] || [ "$RAW" = "" ]; then
        echo -e "  ${GREEN}当前没有封禁的 IP${NC}"
        return
    fi

    local i=1
    for IP in $RAW; do
        echo -e "  ${RED}[$i]${NC} $IP"
        i=$((i+1))
    done
    echo ""
    echo -e "  ${DIM}共 $((i-1)) 个封禁 IP${NC}"
}

# ── 手动解封 IP ───────────────────────────────────────────
f2b_unban() {
    local JAIL="${1:-sshd}"
    print_header "手动解封 IP — $JAIL"

    # 显示当前封禁列表
    local RAW
    RAW=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list:\s*//')

    if [ -z "$RAW" ] || [ "$RAW" = "" ]; then
        echo -e "  ${GREEN}当前没有封禁的 IP，无需解封${NC}"
        return
    fi

    local i=1 IPS=()
    for IP in $RAW; do
        echo -e "  ${RED}[$i]${NC} $IP"
        IPS+=("$IP")
        i=$((i+1))
    done
    echo ""

    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    read -rp "  输入要解封的 IP 地址（直接回车取消）: " UNBAN_IP
    [ -z "$UNBAN_IP" ] && { warn "已取消。"; return; }

    echo ""
    if fail2ban-client set "$JAIL" unbanip "$UNBAN_IP" 2>/dev/null; then
        info "IP ${BOLD}$UNBAN_IP${NC} 已解封 ✓"
    else
        error "解封失败，请确认 IP 地址正确。"
    fi
}

# ── 实时日志 ──────────────────────────────────────────────
f2b_logs() {
    print_header "Fail2ban 实时日志"
    echo -e "  ${DIM}显示最近 30 条，按 Ctrl+C 退出实时模式${NC}"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""

    local LOG_FILE="/var/log/fail2ban.log"
    if [ ! -f "$LOG_FILE" ]; then
        LOG_FILE=$(journalctl -u fail2ban --no-pager -n 1 2>/dev/null | head -1)
        # 用 journalctl
        echo -e "  ${DIM}（使用 journalctl）${NC}"
        echo ""
        journalctl -u fail2ban -n 30 --no-pager 2>/dev/null             | grep -E "Ban|Unban|Found|WARNING|ERROR"             | while IFS= read -r line; do
                if echo "$line" | grep -q "Ban"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -q "Unban"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Found"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo -e "  ${DIM}$line${NC}"
                fi
            done
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${DIM}按 Enter 开启实时跟踪（Ctrl+C 退出）...${NC}"
        read -r _
        journalctl -u fail2ban -f 2>/dev/null
    else
        tail -n 30 "$LOG_FILE"             | while IFS= read -r line; do
                if echo "$line" | grep -q "Ban"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -q "Unban"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Found"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo -e "  ${DIM}$line${NC}"
                fi
            done
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${DIM}按 Enter 开启实时跟踪（Ctrl+C 退出）...${NC}"
        read -r _
        tail -f "$LOG_FILE"             | while IFS= read -r line; do
                if echo "$line" | grep -q "Ban"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -q "Unban"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Found"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo -e "  $line"
                fi
            done
    fi
}


# ══════════════════════════════════════════════════════════
#  BBR TCP 调优模块
# ══════════════════════════════════════════════════════════

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SYSCTL_FILE="/etc/sysctl.conf"

# ── 状态显示 ──────────────────────────────────────────────
bbr_print_status() {
    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    local RATE; RATE=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oP '(?:maxrate|rate) \K\S+' | head -1)
    [ -z "$RATE" ] && RATE="未设置"
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local CWND; CWND=$(ip route show | grep "^default" | grep -oP 'initcwnd \K\d+' || echo "10")
    echo -e "  网卡 ${BOLD}$DEV${NC}  |  拥塞控制 ${BOLD}$BBR${NC}  |  限速 ${BOLD}$RATE${NC}  |  initcwnd ${BOLD}$CWND${NC}"
}

# ── 备份 sysctl ───────────────────────────────────────────
bbr_backup_sysctl() {
    if [ -f "$SYSCTL_FILE" ]; then
        local BAK="${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$SYSCTL_FILE" "$BAK"
        info "已备份至：$BAK"
    fi
}

# ── 还原 sysctl ───────────────────────────────────────────
bbr_restore_sysctl() {
    print_header "还原 sysctl.conf"
    local BACKUPS=()
    mapfile -t BACKUPS < <(ls -t "${SYSCTL_FILE}.bak."* 2>/dev/null)
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        warn "未找到任何备份文件"
        return
    fi
    local i=1
    for f in "${BACKUPS[@]}"; do
        echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  $(stat -c '%y' "$f" | cut -d'.' -f1)"
        (( i++ ))
    done
    echo -e "  ${YELLOW}[d]${NC} 清除全部备份"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "  请选择: " CH
    case "$CH" in
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        d|D)
            read -rp "  确认清除全部 ${#BACKUPS[@]} 个备份？(yes/no): " C
            [ "$C" = "yes" ] && rm -f "${SYSCTL_FILE}.bak."* && info "已清除全部备份" || warn "已取消"
            ;;
        *)
            if [[ "$CH" =~ ^[0-9]+$ ]] && [ "$CH" -ge 1 ] && [ "$CH" -le ${#BACKUPS[@]} ]; then
                local T="${BACKUPS[$((CH-1))]}"
                cp "$T" "$SYSCTL_FILE"
                sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
                info "已还原：$(basename "$T") ✓"
            else
                error "无效选项"
            fi
            ;;
    esac
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() {
    local CONFIG="$1"
    rm -f "$SYSCTL_FILE"
    echo "$CONFIG" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" > /dev/null 2>&1
    info "sysctl 配置已应用 ✓"
}

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_apply_tc() {
    local RATE="$1"
    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    local TX_Q; TX_Q=$(ls /sys/class/net/"$DEV"/queues/ 2>/dev/null | grep "^tx-" | wc -l)
    local IS_MQ=0
    { tc qdisc show dev "$DEV" 2>/dev/null | grep -q "qdisc mq" || [ "$TX_Q" -gt 1 ]; } && IS_MQ=1

    if [ "$IS_MQ" -eq 1 ]; then
        tc qdisc replace dev "$DEV" root tbf rate "${RATE}mbit" burst 10mbit latency 50ms
        cat > "$SERVICE_TC" << EOF
[Unit]
Description=FQ rate limit
After=network.target
[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${DEV} root tbf rate ${RATE}mbit burst 10mbit latency 50ms
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    else
        tc qdisc replace dev "$DEV" root fq maxrate "${RATE}mbit"
        cat > "$SERVICE_TC" << EOF
[Unit]
Description=FQ rate limit
After=network.target
[Service]
Type=oneshot
ExecStart=/sbin/tc qdisc replace dev ${DEV} root fq maxrate ${RATE}mbit
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload
    systemctl enable tc-fq &>/dev/null
    systemctl restart tc-fq
    info "tc 限速已应用：${RATE}Mbps ✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
bbr_generate_config() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAPPINESS=$7 TCP_RMEM_DEFAULT=$8
    cat << EOF
# BBR TCP 调优配置 — 生成时间：$(date)
kernel.pid_max = 65535
kernel.panic = 1
kernel.sysrq = 176
kernel.numa_balancing = 0
kernel.sched_autogroup_enabled = 0
vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.overcommit_memory = 1
vm.min_free_kbytes = ${MIN_FREE}
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 8192
net.core.optmem_max = 1048576
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 32768 ${TCP_RMEM_DEFAULT} ${RMEM}
net.ipv4.tcp_wmem = 32768 ${TCP_RMEM_DEFAULT} ${WMEM}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = ${ADV_WIN}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_notsent_lowat = ${NOTSENT}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
EOF
}

# ── 确认并应用参数 ────────────────────────────────────────
bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 TCP_MEM=$3 NOTSENT=$4 ADV_WIN=$5 \
          MIN_FREE=$6 SWAP=$7 TCP_RMEM_DEFAULT=$8 \
          LABEL_MODE=$9 LABEL_BUF=${10}

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  ${YELLOW}── 配置摘要 ──────────────────────────────${NC}"
    echo -e "  模式         : ${BOLD}$LABEL_MODE${NC}"
    echo -e "  缓冲区       : ${BOLD}${LABEL_BUF}MB${NC}  (rmem/wmem max)"
    echo -e "  tcp_rmem default : ${BOLD}$(( TCP_RMEM_DEFAULT / 1048576 ))MB${NC}"
    echo -e "  min_free_kbytes  : ${BOLD}${MIN_FREE}${NC}"
    echo -e "  tcp_mem      : ${BOLD}${TCP_MEM}${NC}"
    echo -e "  adv_win_scale: ${BOLD}${ADV_WIN}${NC}"
    echo -e "  swappiness   : ${BOLD}${SWAP}${NC}"
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    echo ""
    read -rp "  确认应用？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消"; return; }

    if [ -f "$SYSCTL_FILE" ]; then
        read -rp "  是否备份旧的 sysctl.conf？(yes/no): " DO_BAK
        [ "$DO_BAK" = "yes" ] && bbr_backup_sysctl
    fi

    local CONFIG
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT")
    bbr_apply_sysctl "$CONFIG"
    echo ""
    info "BBR TCP 调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6

    local BW_MBS=$(( BW_MBPS / 8 ))
    local BDP_MB=$(( BW_MBS * LAT_MS / 1000 ))
    local BUF_CALC=$(( BDP_MB * 3 / 2 ))

    local RMEM WMEM ADV_WIN NOTSENT TCP_RMEM_DEFAULT
    if   [ "$BUF_CALC" -le 10 ];  then RMEM=12582912;  WMEM=12582912;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 20 ];  then RMEM=20971520;  WMEM=20971520;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 40 ];  then RMEM=41943040;  WMEM=41943040;  ADV_WIN=3; NOTSENT=262144; TCP_RMEM_DEFAULT=1048576
    elif [ "$BUF_CALC" -le 64 ];  then RMEM=67108864;  WMEM=67108864;  ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576
    else                                RMEM=134217728; WMEM=134217728; ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576
    fi

    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -eq 512  ]; then MIN_FREE=32768; SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -eq 1024 ]; then MIN_FREE=65536; SWAP=10; TCP_MEM="49152 65536 131072"
    else                               MIN_FREE=65536; SWAP=5;  TCP_MEM="131072 196608 393216"
    fi

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  BDP 估算：${BOLD}${BDP_MB}MB${NC}  →  推荐缓冲区：${BOLD}${BUF_MB}MB${NC}"
    echo -e "  内存：${MEM_LBL}  延迟：${LAT_LBL}  带宽：${BW_LBL}"

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN" \
        "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT" \
        "自动计算（${MEM_LBL} / ${LAT_LBL} / ${BW_LBL}）" "$BUF_MB"
}

# ── 手动选择缓冲区模式 ────────────────────────────────────
# ── 自动模式：带宽子菜单 ─────────────────────────────────
bbr_menu_bandwidth() {
    local MEM_MB=$1 LAT_MS=$2 MEM_LBL=$3 LAT_LBL=$4
    print_header "BBR 自动配置 — 选择带宽"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}  延迟：${BOLD}${LAT_LBL}${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 200 Mbps"
    echo -e "  ${GREEN}2${NC}) 500 Mbps"
    echo -e "  ${GREEN}3${NC}) 1 Gbps  (1024 Mbps)"
    echo -e "  ${GREEN}4${NC}) 2 Gbps  (2048 Mbps)"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-4]: " CH
    case "$CH" in
        1) bbr_auto_calc "$MEM_MB" "$LAT_MS" 200  "$MEM_LBL" "$LAT_LBL" "200Mbps" ;;
        2) bbr_auto_calc "$MEM_MB" "$LAT_MS" 500  "$MEM_LBL" "$LAT_LBL" "500Mbps" ;;
        3) bbr_auto_calc "$MEM_MB" "$LAT_MS" 1024 "$MEM_LBL" "$LAT_LBL" "1Gbps" ;;
        4) bbr_auto_calc "$MEM_MB" "$LAT_MS" 2048 "$MEM_LBL" "$LAT_LBL" "2Gbps" ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：延迟子菜单 ─────────────────────────────────
bbr_menu_latency() {
    local MEM_MB=$1 MEM_LBL=$2
    print_header "BBR 自动配置 — 选择延迟"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) 100ms 以内     （国内 / 亚洲近距离）"
    echo -e "  ${GREEN}2${NC}) 100ms - 200ms  （跨国，如美西→中国）"
    echo -e "  ${GREEN}3${NC}) 200ms 以上     （欧洲→中国 / 长距离）"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-3]: " CH
    case "$CH" in
        1) bbr_menu_bandwidth "$MEM_MB" 50  "$MEM_LBL" "100ms以内" ;;
        2) bbr_menu_bandwidth "$MEM_MB" 150 "$MEM_LBL" "100-200ms" ;;
        3) bbr_menu_bandwidth "$MEM_MB" 250 "$MEM_LBL" "200ms以上" ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：内存子菜单 ─────────────────────────────────
bbr_menu_auto() {
    print_header "BBR 自动配置 — 选择内存"
    echo -e "  ${GREEN}1${NC}) 512 MB"
    echo -e "  ${GREEN}2${NC}) 1 GB"
    echo -e "  ${GREEN}3${NC}) 2 GB"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo ""
    read -rp "  请选择 [0-3]: " CH
    case "$CH" in
        1) bbr_menu_latency 512  "512MB" ;;
        2) bbr_menu_latency 1024 "1GB" ;;
        3) bbr_menu_latency 2048 "2GB" ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 手动模式：内存子菜单 ─────────────────────────────────
bbr_menu_manual() {
    # 自动检测系统内存
    local MEM_KB; MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local MEM_MB=$(( MEM_KB / 1024 ))
    local MEM_LBL
    if   [ "$MEM_MB" -le 768  ]; then MEM_LBL="512MB"
    elif [ "$MEM_MB" -le 1536 ]; then MEM_LBL="1GB"
    else                               MEM_LBL="2GB+"
    fi

    print_header "BBR 手动缓冲区配置"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}（内存参数将自动匹配）"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 12 MB   — 低带宽 / 低延迟"
    echo -e "  ${GREEN}2${NC}) 16 MB   — 小内存保守"
    echo -e "  ${GREEN}3${NC}) 20 MB   — 中低带宽"
    echo -e "  ${GREEN}4${NC}) 40 MB   — 中等带宽"
    echo -e "  ${GREEN}5${NC}) 64 MB   — 高带宽推荐"
    echo -e "  ${GREEN}6${NC}) 128 MB  — 超高带宽 / 高延迟"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-6]: " CH

    local RMEM WMEM ADV_WIN NOTSENT TCP_RMEM_DEFAULT BUF_LBL
    case "$CH" in
        1) RMEM=12582912;  WMEM=12582912;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576; BUF_LBL=12 ;;
        2) RMEM=16777216;  WMEM=16777216;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576; BUF_LBL=16 ;;
        3) RMEM=20971520;  WMEM=20971520;  ADV_WIN=2; NOTSENT=131072; TCP_RMEM_DEFAULT=1048576; BUF_LBL=20 ;;
        4) RMEM=41943040;  WMEM=41943040;  ADV_WIN=3; NOTSENT=262144; TCP_RMEM_DEFAULT=1048576; BUF_LBL=40 ;;
        5) RMEM=67108864;  WMEM=67108864;  ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576; BUF_LBL=64 ;;
        6) RMEM=134217728; WMEM=134217728; ADV_WIN=3; NOTSENT=524288; TCP_RMEM_DEFAULT=1048576; BUF_LBL=128 ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    local MIN_FREE SWAP TCP_MEM
    if   [ "$MEM_MB" -le 768  ]; then MIN_FREE=32768; SWAP=10; TCP_MEM="32768 49152 98304"
    elif [ "$MEM_MB" -le 1536 ]; then MIN_FREE=65536; SWAP=10; TCP_MEM="49152 65536 131072"
    else                               MIN_FREE=65536; SWAP=5;  TCP_MEM="131072 196608 393216"
    fi

    bbr_confirm_apply "$RMEM" "$WMEM" "$TCP_MEM" "$NOTSENT" "$ADV_WIN"         "$MIN_FREE" "$SWAP" "$TCP_RMEM_DEFAULT"         "手动选择（内存 ${MEM_MB}MB）" "$BUF_LBL"
}

# ── tc 限速菜单 ───────────────────────────────────────────
bbr_menu_tc() {
    print_header "限速设置（tc）"
    local DEV; DEV=$(ip route | awk '/^default/{print $5}')
    local TX_Q; TX_Q=$(ls /sys/class/net/"$DEV"/queues/ 2>/dev/null | grep "^tx-" | wc -l)
    local IS_MQ=0
    { tc qdisc show dev "$DEV" 2>/dev/null | grep -q "qdisc mq" || [ "$TX_Q" -gt 1 ]; } && IS_MQ=1
    local CUR; CUR=$(tc qdisc show dev "$DEV" 2>/dev/null | grep -oP '(?:maxrate|rate) \K\S+' | head -1)
    [ -z "$CUR" ] && CUR="未设置"

    echo -e "  网卡：${BOLD}${DEV}${NC}  类型：${BOLD}$([ "$IS_MQ" -eq 1 ] && echo "mq多队列" || echo "单队列")${NC}  当前限速：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 200 Mbps"
    echo -e "  ${GREEN}2${NC}) 500 Mbps"
    echo -e "  ${GREEN}3${NC}) 780 Mbps"
    echo -e "  ${GREEN}4${NC}) 1024 Mbps (1Gbps)"
    echo -e "  ${GREEN}5${NC}) 2048 Mbps (2Gbps)"
    echo -e "  ${GREEN}6${NC}) 自定义输入"
    echo -e "  ${YELLOW}7${NC}) 取消限速"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-7]: " CH

    local RATE=0
    case "$CH" in
        1) RATE=200 ;;
        2) RATE=500 ;;
        3) RATE=780 ;;
        4) RATE=1024 ;;
        5) RATE=2048 ;;
        6)
            read -rp "  请输入限速值（Mbps）: " RATE
            if ! [[ "$RATE" =~ ^[0-9]+$ ]] || [ "$RATE" -lt 1 ]; then
                error "无效数值"; return
            fi
            ;;
        7) RATE=0 ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    if [ "$RATE" -eq 0 ]; then
        if [ "$IS_MQ" -eq 1 ]; then
            tc qdisc del dev "$DEV" root 2>/dev/null
            tc qdisc add dev "$DEV" root mq 2>/dev/null
        else
            tc qdisc del dev "$DEV" root 2>/dev/null
        fi
        systemctl disable tc-fq &>/dev/null
        rm -f "$SERVICE_TC"
        systemctl daemon-reload
        info "已取消限速 ✓"
    else
        bbr_apply_tc "$RATE"
    fi
}

# ── initcwnd 菜单 ─────────────────────────────────────────
bbr_menu_initcwnd() {
    print_header "initcwnd 设置"
    local DEV GW ONLINK
    DEV=$(ip route | awk '/^default/{print $5}')
    GW=$(ip route | awk '/^default/{print $3}')
    ONLINK=$(ip route | grep "^default" | grep -q "onlink" && echo "onlink" || echo "")
    local CUR; CUR=$(ip route show | grep "^default" | grep -oP 'initcwnd \K\d+' || echo "10")

    echo -e "  网卡：${BOLD}${DEV}${NC}  网关：${BOLD}${GW}${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${GREEN}1${NC}) 10   — 默认保守"
    echo -e "  ${GREEN}2${NC}) 50   — 跨国高延迟推荐"
    echo -e "  ${GREEN}3${NC}) 100  — 激进（可能丢包）"
    echo -e "  ${GREEN}4${NC}) 自定义输入"
    echo -e "  ${RED}0${NC}) 返回"
    echo -e "  ${RED}00${NC}) 退出脚本"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo ""
    read -rp "  请选择 [0-4]: " CH

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=50 ;;
        3) VAL=100 ;;
        4)
            read -rp "  请输入 initcwnd 值（1-1000）: " VAL
            if ! [[ "$VAL" =~ ^[0-9]+$ ]] || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
                error "无效数值"; return
            fi
            ;;
        0) return ;;
        00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    ip route change default via "$GW" dev "$DEV" $ONLINK initcwnd "$VAL" initrwnd "$VAL" || {
        error "ip route change 失败"; return
    }

    local SERVICE_CWND="/etc/systemd/system/initcwnd.service"
    cat > "$SERVICE_CWND" << EOF
[Unit]
Description=Set TCP initcwnd
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'GW=\$(ip route | awk '"'"'/^default/{print \$3}'"'"'); DEV=\$(ip route | awk '"'"'/^default/{print \$5}'"'"'); ONLINK=\$(ip route | grep "^default" | grep -q "onlink" && echo "onlink" || echo ""); ip route change default via \$GW dev \$DEV \$ONLINK initcwnd ${VAL} initrwnd ${VAL}'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable initcwnd &>/dev/null
    systemctl restart initcwnd
    info "initcwnd 已设置为 ${VAL}，重启后自动生效 ✓"
}

# ── BBR 主菜单 ────────────────────────────────────────────
bbr_menu() {
    while true; do
        print_header "BBR TCP 调优"
        bbr_print_status
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${GREEN}1${NC}) 自动配置（根据内存 / 延迟 / 带宽计算）"
        echo -e "  ${GREEN}2${NC}) 手动选择缓冲区大小"
        echo -e "  ${GREEN}3${NC}) 限速设置（tc）"
        echo -e "  ${GREEN}4${NC}) initcwnd 设置"
        echo -e "  ${GREEN}5${NC}) 备份 sysctl.conf"
        echo -e "  ${GREEN}6${NC}) 还原 sysctl.conf"
        echo -e "  ${RED}0${NC}) 返回主菜单"
            echo -e "  ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-6]: " CH

        case "$CH" in
            1) bbr_menu_auto ;;
            2) bbr_menu_manual ;;
            3) bbr_menu_tc ;;
            4) bbr_menu_initcwnd ;;
            5) bbr_backup_sysctl ;;
            6) bbr_restore_sysctl ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


# ══════════════════════════════════════════════════════════
#  防火墙模块
# ══════════════════════════════════════════════════════════

# ── 检测防火墙类型 ────────────────────────────────────────
# 返回: ufw / firewalld / none
fw_detect() {
    if command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    else
        echo "none"
    fi
}

# ── 获取防火墙运行状态 ────────────────────────────────────
fw_running() {
    local TYPE="$1"
    case "$TYPE" in
        ufw)      ufw status 2>/dev/null | grep -q "Status: active" && echo "active" || echo "inactive" ;;
        firewalld) systemctl is-active --quiet firewalld 2>/dev/null && echo "active" || echo "inactive" ;;
        *) echo "none" ;;
    esac
}

# ── 安装防火墙 ────────────────────────────────────────────
fw_install() {
    local TYPE="$1"
    print_header "安装防火墙"
    info "正在更新软件包列表..."
    apt-get update -qq 2>/dev/null || yum makecache -q 2>/dev/null || true

    case "$TYPE" in
        ufw)
            if apt-get install -y ufw 2>/dev/null; then
                info "ufw 安装成功 ✓"
                ufw --force enable
                info "ufw 已启用 ✓"
            else
                error "安装失败，请检查网络或手动安装：apt install ufw"
            fi
            ;;
        firewalld)
            if yum install -y firewalld 2>/dev/null || apt-get install -y firewalld 2>/dev/null; then
                systemctl enable --now firewalld
                info "firewalld 安装并启动成功 ✓"
            else
                error "安装失败，请检查网络或手动安装"
            fi
            ;;
    esac
}

# ══════════════════════════════════════════════════════════
#  UFW 子功能
# ══════════════════════════════════════════════════════════

ufw_show_rules() {
    print_header "防火墙规则 — ufw"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    ufw status numbered 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^\['; then
            echo -e "  ${GREEN}${line}${NC}"
        else
            echo -e "  ${line}"
        fi
    done
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
}

ufw_add_port() {
    print_header "添加端口规则 — ufw"
    echo -e "  示例：80  或  8080/tcp  或  3000:3010/tcp"
    echo ""
    read -rp "  请输入端口（直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return; }
    read -rp "  方向 [in/out，默认 in]: " DIR
    DIR="${DIR:-in}"
    echo ""
    if ufw allow "$DIR" "$PORT" 2>/dev/null || ufw allow "$PORT" 2>/dev/null; then
        info "已放行端口 $PORT ✓"
    else
        error "添加失败，请检查端口格式"
    fi
}

ufw_del_port() {
    print_header "删除端口规则 — ufw"
    ufw status numbered 2>/dev/null | grep -E '^\[' | while IFS= read -r line; do
        echo -e "  ${YELLOW}${line}${NC}"
    done
    echo ""
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    read -rp "  请输入要删除的规则编号（直接回车取消）: " NUM
    [ -z "$NUM" ] && { warn "已取消"; return; }
    if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号"; return
    fi
    echo "y" | ufw delete "$NUM" 2>/dev/null && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
}

ufw_block_ip() {
    print_header "拉黑 IP — ufw"
    read -rp "  请输入要拉黑的 IP 或 CIDR（如 1.2.3.4 或 1.2.3.0/24）: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    ufw deny from "$IP" to any 2>/dev/null && info "已拉黑 $IP ✓" || error "操作失败"
}

ufw_allow_ip() {
    print_header "白名单 IP — ufw"
    read -rp "  请输入要放行的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    ufw allow from "$IP" to any 2>/dev/null && info "已放行 $IP ✓" || error "操作失败"
}

ufw_del_ip() {
    print_header "删除 IP 规则 — ufw"
    ufw status numbered 2>/dev/null | grep -iE 'deny|allow' | grep -E '^\[' | while IFS= read -r line; do
        echo -e "  ${YELLOW}${line}${NC}"
    done
    echo ""
    read -rp "  请输入要删除的规则编号（直接回车取消）: " NUM
    [ -z "$NUM" ] && { warn "已取消"; return; }
    echo "y" | ufw delete "$NUM" 2>/dev/null && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
}

ufw_quick_allow() {
    print_header "一键放行常用端口 — ufw"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT"
    echo -e "  ${GREEN}HTTP${NC}  : 80"
    echo -e "  ${GREEN}HTTPS${NC} : 443"
    echo ""
    read -rp "  确认放行？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消"; return; }
    ufw allow "$SSH_PORT"/tcp  && info "SSH $SSH_PORT 已放行 ✓"
    ufw allow 80/tcp           && info "HTTP 80 已放行 ✓"
    ufw allow 443/tcp          && info "HTTPS 443 已放行 ✓"
}

# ── ufw 子菜单 ────────────────────────────────────────────
ufw_menu() {
    while true; do
        local STATUS; STATUS=$(fw_running "ufw")
        local ST_COLOR; [ "$STATUS" = "active" ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"

        print_header "防火墙管理 — ufw"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        if [ "$STATUS" = "active" ]; then
            echo -e "  ${YELLOW}1${NC}) 关闭防火墙"
        else
            echo -e "  ${GREEN}1${NC}) 开启防火墙"
        fi
        echo -e "  ${GREEN}2${NC}) 查看当前规则"
        echo -e "  ${GREEN}3${NC}) 添加端口规则"
        echo -e "  ${GREEN}4${NC}) 删除端口规则"
        echo -e "  ${GREEN}5${NC}) 拉黑 IP（黑名单）"
        echo -e "  ${GREEN}6${NC}) 放行 IP（白名单）"
        echo -e "  ${GREEN}7${NC}) 删除 IP 规则"
        echo -e "  ${GREEN}8${NC}) 一键放行常用端口"
        echo -e "  ${RED}0${NC}) 返回"
        echo -e "  ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-8]: " CH

        case "$CH" in
            1)
                if [ "$STATUS" = "active" ]; then
                    ufw --force disable && info "防火墙已关闭 ✓"
                else
                    ufw --force enable  && info "防火墙已开启 ✓"
                fi
                sleep 1; continue
                ;;
            2) ufw_show_rules ;;
            3) ufw_add_port ;;
            4) ufw_del_port ;;
            5) ufw_block_ip ;;
            6) ufw_allow_ip ;;
            7) ufw_del_ip ;;
            8) ufw_quick_allow ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  Firewalld 子功能
# ══════════════════════════════════════════════════════════

fwd_show_rules() {
    print_header "防火墙规则 — firewalld"
    local ZONE; ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
    echo -e "  默认 Zone：${BOLD}${ZONE}${NC}"
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
    echo -e "  ${BOLD}已开放端口：${NC}"
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | while read -r p; do
        [ -n "$p" ] && echo -e "    ${GREEN}▸${NC} $p"
    done
    echo ""
    echo -e "  ${BOLD}已开放服务：${NC}"
    firewall-cmd --list-services 2>/dev/null | tr ' ' '\n' | while read -r s; do
        [ -n "$s" ] && echo -e "    ${GREEN}▸${NC} $s"
    done
    echo ""
    echo -e "  ${BOLD}拒绝 IP：${NC}"
    firewall-cmd --list-rich-rules 2>/dev/null | grep "reject\|drop" | while IFS= read -r r; do
        echo -e "    ${RED}▸${NC} $r"
    done
    echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
}

fwd_add_port() {
    print_header "添加端口规则 — firewalld"
    echo -e "  示例：80/tcp  或  3000-3010/tcp"
    echo ""
    read -rp "  请输入端口（直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-port="$PORT" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "已放行端口 $PORT ✓" || error "添加失败，请检查格式（需含协议，如 80/tcp）"
}

fwd_del_port() {
    print_header "删除端口规则 — firewalld"
    echo -e "  当前开放端口："
    firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | nl | while read -r i p; do
        echo -e "  ${GREEN}[$i]${NC} $p"
    done
    echo ""
    read -rp "  请输入要删除的端口（如 80/tcp，直接回车取消）: " PORT
    [ -z "$PORT" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --remove-port="$PORT" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "端口 $PORT 已删除 ✓" || error "删除失败"
}

fwd_block_ip() {
    print_header "拉黑 IP — firewalld"
    read -rp "  请输入要拉黑的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${IP}' reject" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "已拉黑 $IP ✓" || error "操作失败"
}

fwd_allow_ip() {
    print_header "白名单 IP — firewalld"
    read -rp "  请输入要放行的 IP 或 CIDR: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${IP}' accept" 2>/dev/null && \
    firewall-cmd --reload 2>/dev/null && \
    info "已放行 $IP ✓" || error "操作失败"
}

fwd_del_ip() {
    print_header "删除 IP 规则 — firewalld"
    echo -e "  当前 Rich Rules："
    firewall-cmd --list-rich-rules 2>/dev/null | nl | while read -r i r; do
        echo -e "  ${YELLOW}[$i]${NC} $r"
    done
    echo ""
    read -rp "  请输入要删除的完整 IP（如 1.2.3.4，直接回车取消）: " IP
    [ -z "$IP" ] && { warn "已取消"; return; }
    # 尝试删除 reject 和 accept 规则
    firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' reject" 2>/dev/null
    firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' accept" 2>/dev/null
    firewall-cmd --reload 2>/dev/null && info "IP $IP 相关规则已删除 ✓" || error "删除失败"
}

fwd_quick_allow() {
    print_header "一键放行常用端口 — firewalld"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT/tcp"
    echo -e "  ${GREEN}HTTP${NC}  : 80/tcp"
    echo -e "  ${GREEN}HTTPS${NC} : 443/tcp"
    echo ""
    read -rp "  确认放行？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消"; return; }
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"  && info "SSH $SSH_PORT 已放行 ✓"
    firewall-cmd --permanent --add-port="80/tcp"           && info "HTTP 80 已放行 ✓"
    firewall-cmd --permanent --add-port="443/tcp"          && info "HTTPS 443 已放行 ✓"
    firewall-cmd --reload && info "规则已重载 ✓"
}

# ── firewalld 子菜单 ──────────────────────────────────────
fwd_menu() {
    while true; do
        local STATUS; STATUS=$(fw_running "firewalld")
        local ST_COLOR; [ "$STATUS" = "active" ] && ST_COLOR="$GREEN" || ST_COLOR="$RED"

        print_header "防火墙管理 — firewalld"
        echo -e "  服务状态: ${ST_COLOR}${BOLD}${STATUS}${NC}"
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        if [ "$STATUS" = "active" ]; then
            echo -e "  ${YELLOW}1${NC}) 关闭防火墙"
        else
            echo -e "  ${GREEN}1${NC}) 开启防火墙"
        fi
        echo -e "  ${GREEN}2${NC}) 查看当前规则"
        echo -e "  ${GREEN}3${NC}) 添加端口规则"
        echo -e "  ${GREEN}4${NC}) 删除端口规则"
        echo -e "  ${GREEN}5${NC}) 拉黑 IP（黑名单）"
        echo -e "  ${GREEN}6${NC}) 放行 IP（白名单）"
        echo -e "  ${GREEN}7${NC}) 删除 IP 规则"
        echo -e "  ${GREEN}8${NC}) 一键放行常用端口"
        echo -e "  ${RED}0${NC}) 返回"
        echo -e "  ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-8]: " CH

        case "$CH" in
            1)
                if [ "$STATUS" = "active" ]; then
                    systemctl stop firewalld && info "防火墙已关闭 ✓"
                else
                    systemctl start firewalld && info "防火墙已开启 ✓"
                fi
                sleep 1; continue
                ;;
            2) fwd_show_rules ;;
            3) fwd_add_port ;;
            4) fwd_del_port ;;
            5) fwd_block_ip ;;
            6) fwd_allow_ip ;;
            7) fwd_del_ip ;;
            8) fwd_quick_allow ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  防火墙总入口
# ══════════════════════════════════════════════════════════
firewall_menu() {
    local FW_TYPE; FW_TYPE=$(fw_detect)

    # 未安装：引导安装
    if [ "$FW_TYPE" = "none" ]; then
        while true; do
            print_header "防火墙管理"
            warn "未检测到已安装的防火墙！"
            echo ""
            echo -e "  请选择要安装的防火墙："
            echo -e "  ${GREEN}1${NC}) ufw       （推荐，Ubuntu/Debian 常用）"
            echo -e "  ${GREEN}2${NC}) firewalld （CentOS/Rocky/Fedora 常用）"
            echo -e "  ${RED}0${NC}) 返回主菜单"
            echo -e "  ${RED}00${NC}) 退出脚本"
            echo ""
            read -rp "  请选择 [0-2]: " CH
            case "$CH" in
                1) fw_install "ufw";      echo ""; read -rp "  按 Enter 继续..." _; FW_TYPE=$(fw_detect); break ;;
                2) fw_install "firewalld"; echo ""; read -rp "  按 Enter 继续..." _; FW_TYPE=$(fw_detect); break ;;
                0) return ;;
                00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
        done
    fi

    # 已安装：进入对应子菜单
    case "$FW_TYPE" in
        ufw)      ufw_menu ;;
        firewalld) fwd_menu ;;
    esac
}

# ── SSH 工具集子菜单 ──────────────────────────────────────
ssh_tools_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)

        print_header "SSH 工具集"
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}" \
                 "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}" \
                 "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${GREEN}1${NC}) 查看已有公钥"
        echo -e "  ${GREEN}2${NC}) 添加公钥"
        echo -e "  ${GREEN}3${NC}) 删除公钥"
        echo -e "  ${GREEN}4${NC}) 生成密钥对"
        echo -e "  ${GREEN}5${NC}) 设置登录方式"
        echo -e "  ${GREEN}6${NC}) 修改 SSH 端口"
        echo -e "  ${RED}0${NC}) 返回主菜单"
        echo -e "  ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-6]: " CHOICE

        local NEED_PAUSE=1
        case "$CHOICE" in
            1) show_keys ;;
            2) add_key ;;
            3) delete_key ;;
            4) generate_key ;;
            5) set_login_mode ;;
            6) change_port ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; NEED_PAUSE=0 ;;
        esac

        [ "$NEED_PAUSE" -eq 1 ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


# ══════════════════════════════════════════════════════════
#  DNS 优化模块
# ══════════════════════════════════════════════════════════

dns_show_current() {
    echo -e "  ${BOLD}当前 DNS 地址：${NC}"
    grep "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r line; do
        local IP; IP=$(echo "$line" | awk '{print $2}')
        # IPv6 用黄色，IPv4 用青色
        if echo "$IP" | grep -q ":"; then
            echo -e "    ${YELLOW}$line${NC}"
        else
            echo -e "    ${CYAN}$line${NC}"
        fi
    done
}

dns_write() {
    local V4_LIST="$1"
    local V6_LIST="$2"
    local RESOLV="/etc/resolv.conf"

    # 去除 chattr 锁定（某些系统会锁定 resolv.conf）
    chattr -i "$RESOLV" 2>/dev/null

    # 备份
    cp "$RESOLV" "${RESOLV}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

    # 保留非 nameserver 行
    local OTHER
    OTHER=$(grep -v "^nameserver" "$RESOLV" 2>/dev/null)

    {
        [ -n "$OTHER" ] && echo "$OTHER"
        for ip in $V4_LIST; do echo "nameserver $ip"; done
        for ip in $V6_LIST; do echo "nameserver $ip"; done
    } > "$RESOLV"

    info "DNS 已更新 ✓"
    echo ""
    echo -e "  ${BOLD}更新后：${NC}"
    grep "^nameserver" "$RESOLV" | while read -r line; do
        local IP; IP=$(echo "$line" | awk '{print $2}')
        echo "$IP" | grep -q ":" \
            && echo -e "    ${YELLOW}$line${NC}" \
            || echo -e "    ${CYAN}$line${NC}"
    done
}

dns_menu() {
    while true; do
        print_header "DNS 优化"
        dns_show_current
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${BOLD}国外 DNS：${NC}"
        echo -e "  ${GREEN}1${NC}) Cloudflare  v4: 1.1.1.1 / 1.0.0.1"
        echo -e "       v6: 2606:4700:4700::1111 / 2606:4700:4700::1001"
        echo -e "  ${GREEN}2${NC}) Google      v4: 8.8.8.8 / 8.8.4.4"
        echo -e "       v6: 2001:4860:4860::8888 / 2001:4860:4860::8844"
        echo -e "  ${GREEN}3${NC}) 混合推荐    Cloudflare + Google"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${BOLD}国内 DNS：${NC}"
        echo -e "  ${GREEN}4${NC}) 阿里云      v4: 223.5.5.5 / 223.6.6.6"
        echo -e "       v6: 2400:3200::1 / 2400:3200:baba::1"
        echo -e "  ${GREEN}5${NC}) 腾讯 DNSpod v4: 119.29.29.29 / 183.60.83.19"
        echo -e "  ${GREEN}6${NC}) 114 DNS     v4: 114.114.114.114 / 114.114.115.115"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${GREEN}7${NC}) 手动编辑 DNS 配置"
        echo -e "  ${RED}0${NC}) 返回"
        echo -e "  ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-7]: " CH

        case "$CH" in
            1) dns_write "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001" ;;
            2) dns_write "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844" ;;
            3) dns_write "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888" ;;
            4) dns_write "223.5.5.5 223.6.6.6" "2400:3200::1 2400:3200:baba::1" ;;
            5) dns_write "119.29.29.29 183.60.83.19" "" ;;
            6) dns_write "114.114.114.114 114.114.115.115" "" ;;
            7)
                warn "即将用 nano 编辑 /etc/resolv.conf"
                chattr -i /etc/resolv.conf 2>/dev/null
                read -rp "  按 Enter 继续..." _
                nano /etc/resolv.conf
                info "DNS 配置已保存"
                ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  换源模块
# ══════════════════════════════════════════════════════════

# 检测系统发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}:${VERSION_ID}"
    else
        echo "unknown"
    fi
}

mirror_backup() {
    local SRC_FILE="$1"
    local BAK="${SRC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SRC_FILE" "$BAK" 2>/dev/null && info "已备份原始源文件：$BAK"
}

mirror_apply_ubuntu() {
    local MIRROR="$1"
    local CODENAME; CODENAME=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    mirror_backup "/etc/apt/sources.list"
    cat > /etc/apt/sources.list << EOF
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF
    info "已切换 Ubuntu 源 → $MIRROR"
    apt-get update -qq && info "apt update 完成 ✓" || warn "apt update 出现警告，请检查"
}

mirror_apply_debian() {
    local MIRROR="$1"
    local CODENAME; CODENAME=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
    mirror_backup "/etc/apt/sources.list"
    cat > /etc/apt/sources.list << EOF
deb ${MIRROR} ${CODENAME} main contrib non-free non-free-firmware
deb ${MIRROR} ${CODENAME}-updates main contrib non-free non-free-firmware
deb ${MIRROR} ${CODENAME}-backports main contrib non-free non-free-firmware
deb ${MIRROR}-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
    info "已切换 Debian 源 → $MIRROR"
    apt-get update -qq && info "apt update 完成 ✓" || warn "apt update 出现警告，请检查"
}

mirror_apply_centos() {
    local REGION="$1"
    if command -v dnf &>/dev/null; then
        dnf install -y epel-release &>/dev/null
        case "$REGION" in
            cn)    dnf config-manager --setopt="*.baseurl=https://mirrors.aliyun.com/centos/\$releasever" --save &>/dev/null ;;
            edu)   dnf config-manager --setopt="*.baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/\$releasever" --save &>/dev/null ;;
            *)     info "海外地区使用默认源" ;;
        esac
    fi
    info "CentOS/Rocky 源已更新 ✓"
}

mirror_menu() {
    while true; do
        local OS_INFO; OS_INFO=$(detect_os)
        local OS_ID; OS_ID=$(echo "$OS_INFO" | cut -d: -f1)
        local OS_VER; OS_VER=$(echo "$OS_INFO" | cut -d: -f2)

        print_header "系统换源"
        echo -e "  检测到系统：${BOLD}${OS_ID} ${OS_VER}${NC}"
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"

        case "$OS_ID" in
            ubuntu)
                echo -e "  ${GREEN}1${NC}) 中国大陆【阿里云】    mirrors.aliyun.com"
                echo -e "  ${GREEN}2${NC}) 中国大陆【腾讯云】    mirrors.tencent.com"
                echo -e "  ${GREEN}3${NC}) 中国大陆【清华】      mirrors.tuna.tsinghua.edu.cn"
                echo -e "  ${GREEN}4${NC}) 中国大陆【中科大】    mirrors.ustc.edu.cn"
                echo -e "  ${GREEN}5${NC}) 海外地区【官方源】    archive.ubuntu.com"
                echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
                echo -e "  ${RED}0${NC}) 返回"
                echo -e "  ${RED}00${NC}) 退出脚本"
                echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
                echo ""
                read -rp "  请选择 [0-5]: " CH
                case "$CH" in
                    1) mirror_apply_ubuntu "https://mirrors.aliyun.com/ubuntu" ;;
                    2) mirror_apply_ubuntu "https://mirrors.tencent.com/ubuntu" ;;
                    3) mirror_apply_ubuntu "https://mirrors.tuna.tsinghua.edu.cn/ubuntu" ;;
                    4) mirror_apply_ubuntu "https://mirrors.ustc.edu.cn/ubuntu" ;;
                    5) mirror_apply_ubuntu "http://archive.ubuntu.com/ubuntu" ;;
                    0) return ;;
                    00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            debian)
                echo -e "  ${GREEN}1${NC}) 中国大陆【阿里云】    mirrors.aliyun.com"
                echo -e "  ${GREEN}2${NC}) 中国大陆【腾讯云】    mirrors.tencent.com"
                echo -e "  ${GREEN}3${NC}) 中国大陆【清华】      mirrors.tuna.tsinghua.edu.cn"
                echo -e "  ${GREEN}4${NC}) 中国大陆【中科大】    mirrors.ustc.edu.cn"
                echo -e "  ${GREEN}5${NC}) 海外地区【官方源】    deb.debian.org"
                echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
                echo -e "  ${RED}0${NC}) 返回"
                echo -e "  ${RED}00${NC}) 退出脚本"
                echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
                echo ""
                read -rp "  请选择 [0-5]: " CH
                case "$CH" in
                    1) mirror_apply_debian "https://mirrors.aliyun.com/debian" ;;
                    2) mirror_apply_debian "https://mirrors.tencent.com/debian" ;;
                    3) mirror_apply_debian "https://mirrors.tuna.tsinghua.edu.cn/debian" ;;
                    4) mirror_apply_debian "https://mirrors.ustc.edu.cn/debian" ;;
                    5) mirror_apply_debian "http://deb.debian.org/debian" ;;
                    0) return ;;
                    00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            centos|rocky|rhel|almalinux)
                echo -e "  ${GREEN}1${NC}) 中国大陆【阿里云】"
                echo -e "  ${GREEN}2${NC}) 中国大陆【清华】"
                echo -e "  ${GREEN}3${NC}) 海外地区【默认】"
                echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
                echo -e "  ${RED}0${NC}) 返回"
                echo -e "  ${RED}00${NC}) 退出脚本"
                echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
                echo ""
                read -rp "  请选择 [0-3]: " CH
                case "$CH" in
                    1) mirror_apply_centos "cn" ;;
                    2) mirror_apply_centos "edu" ;;
                    3) mirror_apply_centos "intl" ;;
                    0) return ;;
                    00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            *)
                warn "暂不支持自动换源的系统：${OS_ID}"
                warn "请手动修改 /etc/apt/sources.list 或对应源文件"
                echo ""
                read -rp "  按 Enter 返回..." _
                return
                ;;
        esac

        [ "${CH:-x}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}


# ══════════════════════════════════════════════════════════
#  IPv4/IPv6 配置模块
# ══════════════════════════════════════════════════════════

ip_show_status() {
    print_header "IPv4 / IPv6 状态"

    # ── IPv4 状态 ──────────────────────────────────────────
    echo -e "  ${BOLD}IPv4：${NC}"
    local V4_ADDRS
    V4_ADDRS=$(ip -4 addr show scope global 2>/dev/null | grep "inet " | awk '{print $2}')
    if [ -n "$V4_ADDRS" ]; then
        while IFS= read -r addr; do
            echo -e "    ${GREEN}▸${NC} $addr"
        done <<< "$V4_ADDRS"
    else
        echo -e "    ${YELLOW}未检测到 IPv4 地址${NC}"
    fi

    # ── IPv6 状态 ──────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}IPv6：${NC}"
    local V6_DISABLED
    V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$V6_DISABLED" = "1" ]; then
        echo -e "    ${RED}▸ IPv6 已禁用${NC}"
    else
        local V6_ADDRS
        V6_ADDRS=$(ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print $2}')
        if [ -n "$V6_ADDRS" ]; then
            while IFS= read -r addr; do
                echo -e "    ${GREEN}▸${NC} $addr"
            done <<< "$V6_ADDRS"
        else
            echo -e "    ${YELLOW}▸ IPv6 已启用但无全局地址${NC}"
        fi
    fi

    # ── 优先级状态 ─────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}优先级策略：${NC}"
    local GAICONF="/etc/gai.conf"
    if grep -q "^precedence ::ffff:0:0/96  100" "$GAICONF" 2>/dev/null; then
        echo -e "    ${CYAN}▸ 当前优先：IPv4${NC}"
    else
        echo -e "    ${CYAN}▸ 当前优先：IPv6（系统默认）${NC}"
    fi

    # ── 默认路由 ───────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}默认路由：${NC}"
    ip -4 route show default 2>/dev/null | while IFS= read -r r; do
        echo -e "    ${GREEN}v4${NC} $r"
    done
    ip -6 route show default 2>/dev/null | while IFS= read -r r; do
        echo -e "    ${CYAN}v6${NC} $r"
    done
}

ip_prefer_v4() {
    print_header "设置 IPv4 优先"
    local GAICONF="/etc/gai.conf"

    # 备份
    cp "$GAICONF" "${GAICONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

    # 注释掉已有的 precedence ::ffff 行，再追加正确的
    sed -i '/^precedence ::ffff:0:0\/96/d' "$GAICONF" 2>/dev/null
    # 确保文件存在
    [ -f "$GAICONF" ] || touch "$GAICONF"
    echo "precedence ::ffff:0:0/96  100" >> "$GAICONF"

    info "已写入 IPv4 优先规则到 $GAICONF ✓"

    # 同时通过 sysctl 设置（影响内核层面）
    sysctl -w net.ipv4.conf.all.promote_secondaries=1 &>/dev/null

    echo ""
    warn "IPv4 优先已生效，部分程序需重启才能感知变化"
    echo ""
    echo -e "  验证（应显示 IPv4 连接）："
    echo -e "  ${DIM}curl -s --max-time 5 ip.sb${NC}"
    local RESULT; RESULT=$(curl -s --max-time 5 ip.sb 2>/dev/null)
    [ -n "$RESULT" ] && echo -e "  当前出口 IP：${BOLD}${RESULT}${NC}" || warn "无法连接 ip.sb 进行验证"
}

ip_disable_v6() {
    print_header "关闭 IPv6"
    warn "关闭 IPv6 后，仅 IPv6 的服务将无法访问！"
    echo ""
    read -rp "  确认关闭？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消"; return; }

    local SYSCTL_FILE="/etc/sysctl.conf"

    # 写入 sysctl
    for KEY in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
        if grep -q "^${KEY}" "$SYSCTL_FILE" 2>/dev/null; then
            sed -i "s|^${KEY}.*|${KEY} = 1|" "$SYSCTL_FILE"
        else
            echo "${KEY} = 1" >> "$SYSCTL_FILE"
        fi
    done

    sysctl -p "$SYSCTL_FILE" &>/dev/null
    info "IPv6 已通过 sysctl 禁用 ✓"

    # 立即生效（无需重启）
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null

    echo ""
    echo -e "  当前 IPv6 状态：${RED}${BOLD}已禁用${NC}"
    warn "如 SSH 监听了 IPv6，建议确认 SSH 配置正常后再断开连接"
}

ip_enable_v6() {
    print_header "开启 IPv6"
    local SYSCTL_FILE="/etc/sysctl.conf"

    # 移除或改为 0
    for KEY in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
        if grep -q "^${KEY}" "$SYSCTL_FILE" 2>/dev/null; then
            sed -i "s|^${KEY}.*|${KEY} = 0|" "$SYSCTL_FILE"
        else
            echo "${KEY} = 0" >> "$SYSCTL_FILE"
        fi
    done

    sysctl -p "$SYSCTL_FILE" &>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 &>/dev/null

    info "IPv6 已开启 ✓"
    echo ""

    # 检查是否拿到地址
    sleep 1
    local V6_ADDRS; V6_ADDRS=$(ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print $2}')
    if [ -n "$V6_ADDRS" ]; then
        echo -e "  检测到 IPv6 地址："
        while IFS= read -r addr; do
            echo -e "    ${GREEN}▸${NC} $addr"
        done <<< "$V6_ADDRS"
    else
        warn "已开启但暂未获取到 IPv6 地址，可能需要重启网络服务或等待 SLAAC"
        echo -e "  ${DIM}可尝试：systemctl restart networking 或 reboot${NC}"
    fi
}

ip_config_menu() {
    while true; do
        print_header "IPv4 / IPv6 配置"

        # 状态摘要
        local V6_DISABLED; V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
        local V6_STATUS; [ "$V6_DISABLED" = "1" ] && V6_STATUS="${RED}${BOLD}已禁用${NC}" || V6_STATUS="${GREEN}${BOLD}已启用${NC}"
        local V4_PREF="系统默认（IPv6优先）"
        grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null && V4_PREF="${CYAN}${BOLD}IPv4 优先${NC}"

        echo -e "  IPv6 状态：$V6_STATUS"
        echo -e "  优先级：$V4_PREF"
        echo ""
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo -e "  ${GREEN}1${NC}) 查看 IPv4 / IPv6 详细状态"
        echo -e "  ${GREEN}2${NC}) 设置 IPv4 优先"
        echo -e "  ${GREEN}3${NC}) 关闭 IPv6"
        echo -e "  ${GREEN}4${NC}) 开启 IPv6"
        echo -e "  ${RED}0${NC}) 返回"
        echo -e "  ${RED}00${NC}) 退出脚本"
        echo -e "  ${CYAN}$(printf '─%.0s' $(seq 1 38))${NC}"
        echo ""
        read -rp "  请选择 [0-4]: " CH

        case "$CH" in
            1) ip_show_status ;;
            2) ip_prefer_v4 ;;
            3) ip_disable_v6 ;;
            4) ip_enable_v6 ;;
            0) return ;;
            00) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && { echo ""; read -rp "  按 Enter 返回..." _; }
    done
}

# ══════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════
main_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)
        local F2B_STAT; F2B_STAT=$(f2b_status)

        clear
        echo ""
        box_top
        box_title "VPS 开荒脚本"
        box_line "  ··银趴火山帮··" "  ${DIM}··银趴火山帮··${NC}"
        box_sep
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}" \
                 "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}" \
                 "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        if [ "$F2B_STAT" = "running" ]; then
            box_line "  Fail2ban: running" "  Fail2ban: ${GREEN}${BOLD}running${NC}"
        elif [ "$F2B_STAT" = "stopped" ]; then
            box_line "  Fail2ban: stopped" "  Fail2ban: ${RED}${BOLD}stopped${NC}"
        else
            box_line "  Fail2ban: 未安装" "  Fail2ban: ${YELLOW}${BOLD}未安装${NC}"
        fi
        local FW_TYPE FW_STAT FW_COLOR
        FW_TYPE=$(fw_detect)
        if [ "$FW_TYPE" = "none" ]; then
            FW_STAT="未安装"; FW_COLOR="$YELLOW"
        elif [ "$(fw_running "$FW_TYPE")" = "active" ]; then
            FW_STAT="${FW_TYPE} active"; FW_COLOR="$GREEN"
        else
            FW_STAT="${FW_TYPE} inactive"; FW_COLOR="$RED"
        fi
        local BBR_CC; BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        local TC_RATE; TC_RATE=$(tc qdisc show dev "$(ip route | awk '/^default/{print $5}')" 2>/dev/null | grep -oP '(?:maxrate|rate) \K\S+' | head -1); [ -z "$TC_RATE" ] && TC_RATE="无限速"
        box_line "  BBR: ${BBR_CC}  |  限速: ${TC_RATE}" "  BBR: ${BOLD}${BBR_CC}${NC}  |  限速: ${BOLD}${TC_RATE}${NC}"
        box_line "  防火墙: ${FW_STAT}" "  防火墙: ${FW_COLOR}${BOLD}${FW_STAT}${NC}"
        box_sep
        box_line "  1) SSH 工具集"   "  ${GREEN}1${NC}) SSH 工具集"
        box_line "  2) Fail2ban 管理" "  ${GREEN}2${NC}) Fail2ban 管理"
        box_line "  3) BBR TCP 调优" "  ${GREEN}3${NC}) BBR TCP 调优"
        box_line "  4) 防火墙管理"   "  ${GREEN}4${NC}) 防火墙管理"
        box_line "  5) DNS 优化"     "  ${GREEN}5${NC}) DNS 优化"
        box_line "  6) 系统换源"     "  ${GREEN}6${NC}) 系统换源"
        box_line "  7) IPv4/IPv6 配置" "  ${GREEN}7${NC}) IPv4/IPv6 配置"
        box_line "  0) 退出"         "  ${RED}0${NC}) 退出"
        box_bot
        echo ""
        read -rp "  请选择功能 [0-7]: " CHOICE

        case "$CHOICE" in
            1) ssh_tools_menu ;;
            2) fail2ban_menu ;;
            3) bbr_menu ;;
            4) firewall_menu ;;
            5) dns_menu ;;
            6) mirror_menu ;;
            7) ip_config_menu ;;
            0) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
        # 子菜单返回后直接刷新主菜单，不需要按 Enter
        continue
    done
}

main_menu
