#!/bin/bash

# ============================================================
#  SSH 管理脚本
#  功能：公钥管理 / 生成密钥 / 登录方式设置 / 端口修改
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
box_top() { printf "${BOLD}${CYAN}╔"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "╗${NC}\n"; }
box_bot() { printf "${BOLD}${CYAN}╚"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "╝${NC}\n"; }
box_sep() { printf "${BOLD}${CYAN}╠"; printf '═%.0s' $(seq 1 $((BOX_W-2))); printf "╣${NC}\n"; }

# 居中标题行（只传纯文本，自动居中）
box_title() {
    local TEXT="$1"
    local LEN; LEN=$(vis_len "$TEXT")
    local INNER=$((BOX_W - 2))
    local PAD_TOTAL=$(( INNER - LEN ))
    local PAD_L=$(( PAD_TOTAL / 2 ))
    local PAD_R=$(( PAD_TOTAL - PAD_L ))
    printf "${BOLD}${CYAN}║${NC}"
    printf '%*s' "$PAD_L" ''
    printf "${BOLD}${CYAN}%s${NC}" "$TEXT"
    printf '%*s' "$PAD_R" ''
    printf "${BOLD}${CYAN}║${NC}\n"
}

# 普通内容行：PLAIN=纯文本(算宽度)  COLORED=带色码(显示用)
# 用法: box_line "纯文本" "带色码文本"
box_line() {
    local PLAIN="$1"
    local COLORED="${2:-$1}"
    local LEN; LEN=$(vis_len "$PLAIN")
    local INNER=$((BOX_W - 2))
    local PAD=$(( INNER - LEN ))
    [ "$PAD" -lt 0 ] && PAD=0
    printf "${BOLD}${CYAN}║${NC}"
    echo -ne "$COLORED"
    printf '%*s' "$PAD" ''
    printf "${BOLD}${CYAN}║${NC}\n"
}

# 空行
box_empty() {
    printf "${BOLD}${CYAN}║${NC}"
    printf '%*s' "$((BOX_W-2))" ''
    printf "${BOLD}${CYAN}║${NC}\n"
}

# 统一标题栏
print_header() {
    clear
    echo ""
    box_top
    box_title "SSH 管理工具"
    box_line "  银趴火山帮" "  ${DIM}银趴火山帮${NC}"
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
        RULES=$(iptables -L INPUT --line-numbers 2>/dev/null \
            | grep -v "^Chain\|^num\|^$\|ACCEPT.*all.*anywhere.*anywhere" | wc -l)
        [ "$RULES" -gt 0 ] && IPTABLES_ACTIVE=true
    fi

    if [ "$UFW_ACTIVE" = false ] && [ "$FIREWALLD_ACTIVE" = false ] && [ "$IPTABLES_ACTIVE" = false ]; then
        info "未检测到活跃防火墙，跳过端口放行"
        return
    fi

    info "检测到防火墙，放行端口 $PORT ..."
    [ "$UFW_ACTIVE" = true ] && ufw allow "$PORT"/tcp && info "ufw 已放行 $PORT ✓"
    if [ "$FIREWALLD_ACTIVE" = true ]; then
        firewall-cmd --permanent --add-port="$PORT"/tcp && firewall-cmd --reload
        info "firewalld 已放行 $PORT ✓"
    fi
    if [ "$IPTABLES_ACTIVE" = true ]; then
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        [ -f /etc/iptables/rules.v4 ] && iptables-save > /etc/iptables/rules.v4
        info "iptables 已放行 $PORT ✓"
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
        0|*) return ;;
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
#  主菜单
# ══════════════════════════════════════════════════════════
main_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)

        clear
        echo ""
        box_top
        box_title "SSH 管理工具"
        box_line "  银趴火山帮" "  ${DIM}银趴火山帮${NC}"
        box_sep
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}" \
                 "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}" \
                 "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        box_sep
        box_line "  1) 查看已有公钥" "  ${GREEN}1${NC}) 查看已有公钥"
        box_line "  2) 添加公钥"     "  ${GREEN}2${NC}) 添加公钥"
        box_line "  3) 删除公钥"     "  ${GREEN}3${NC}) 删除公钥"
        box_line "  4) 生成密钥对"   "  ${GREEN}4${NC}) 生成密钥对"
        box_line "  5) 设置登录方式" "  ${GREEN}5${NC}) 设置登录方式"
        box_line "  6) 修改 SSH 端口" "  ${GREEN}6${NC}) 修改 SSH 端口"
        box_line "  0) 退出"         "  ${RED}0${NC}) 退出"
        box_bot
        echo ""
        read -rp "  请选择功能 [0-6]: " CHOICE

        case "$CHOICE" in
            1) show_keys ;;
            2) add_key ;;
            3) delete_key ;;
            4) generate_key ;;
            5) set_login_mode ;;
            6) change_port ;;
            0) clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1; continue ;;
        esac

        echo ""
        read -rp "  按 Enter 返回主菜单..." _
    done
}

main_menu
