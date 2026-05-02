#!/bin/bash

# ============================================================
#  SSH 管理脚本
#  功能：公钥管理 / 登录方式设置 / 端口修改
# ============================================================

SSHD_CONFIG="/etc/ssh/sshd_config"
AUTH_KEYS="$HOME/.ssh/authorized_keys"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
title()   { echo -e "\n${BOLD}${CYAN}$1${NC}"; echo -e "${CYAN}$(echo "$1" | sed 's/./-/g')${NC}"; }

# ── 权限检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR]${NC} 请使用 root 权限运行：sudo bash $0"
    exit 1
fi

# ── 通用工具函数 ──────────────────────────────────────────

# 读取当前配置值
get_config() {
    grep -E "^[[:space:]]*$1[[:space:]]" "$SSHD_CONFIG" 2>/dev/null \
        | tail -1 | awk '{print $2}'
}

# 设置配置项（存在则替换，不存在则追加）
set_config() {
    local KEY="$1" VALUE="$2"
    if grep -qE "^#?[[:space:]]*${KEY}[[:space:]]" "$SSHD_CONFIG"; then
        sed -i "s|^#\?[[:space:]]*${KEY}[[:space:]].*|${KEY} ${VALUE}|" "$SSHD_CONFIG"
    else
        echo "${KEY} ${VALUE}" >> "$SSHD_CONFIG"
    fi
}

# 备份配置
backup_config() {
    local BACKUP="$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SSHD_CONFIG" "$BACKUP"
    info "配置已备份到：$BACKUP"
}

# 语法检查 + 重启
apply_and_restart() {
    if ! sshd -t 2>/dev/null; then
        error "配置文件语法错误，已取消应用，请检查 $SSHD_CONFIG"
        return 1
    fi
    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        info "SSH 服务已重启 ✓"
    else
        error "SSH 服务重启失败，请手动执行：systemctl restart ssh"
        return 1
    fi
}

# 列出所有有效公钥（带序号）
list_keys() {
    if [ ! -f "$AUTH_KEYS" ] || ! grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null; then
        echo -e "  ${YELLOW}（暂无公钥）${NC}"
        return 1
    fi
    local i=1
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
            # 取密钥类型、指纹注释
            local TYPE COMMENT FINGER
            TYPE=$(echo "$line" | awk '{print $1}')
            COMMENT=$(echo "$line" | awk '{print $3}')
            FINGER=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || echo "无法计算")
            echo -e "  ${GREEN}[$i]${NC} ${BOLD}$TYPE${NC} ${BLUE}$FINGER${NC} ${YELLOW}$COMMENT${NC}"
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"
    return 0
}

# 防火墙放行端口
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
    [ "$UFW_ACTIVE" = true ]       && ufw allow "$PORT"/tcp && info "ufw 已放行 $PORT ✓"
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

# ── 1. 显示公钥 ───────────────────────────────────────────
show_keys() {
    title " 当前 SSH 公钥列表"
    list_keys
    echo ""
}

# ── 2. 添加公钥 ───────────────────────────────────────────
add_key() {
    title " 添加 SSH 公钥"
    echo -e "  请粘贴公钥内容（以 ssh-ed25519 / ssh-rsa 等开头）"
    echo -e "  粘贴后按 ${BOLD}Enter${NC}，再按 ${BOLD}Ctrl+D${NC} 完成："
    echo ""
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)

    if [ -z "$PUBKEY_INPUT" ]; then
        warn "未输入任何内容，已取消。"
        return
    fi
    if ! echo "$PUBKEY_INPUT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
        error "公钥格式不正确，请确认复制完整（应以密钥类型开头）。"
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

# ── 3. 删除公钥 ───────────────────────────────────────────
delete_key() {
    title " 删除 SSH 公钥"

    if ! list_keys; then
        return
    fi

    echo ""
    read -rp "请输入要删除的公钥编号（直接回车取消）: " DEL_NUM

    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"
        return
    fi

    # 提取第 N 行有效公钥
    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) '; then
            if [ "$i" -eq "$DEL_NUM" ]; then
                TARGET_LINE="$line"
                break
            fi
            i=$((i+1))
        fi
    done < "$AUTH_KEYS"

    if [ -z "$TARGET_LINE" ]; then
        error "编号 $DEL_NUM 不存在。"
        return
    fi

    echo ""
    warn "即将删除以下公钥："
    echo -e "  ${RED}$(echo "$TARGET_LINE" | awk '{print $1, $3}')${NC}"
    read -rp "确认删除？(yes/no): " CONFIRM
    [ "$CONFIRM" != "yes" ] && { warn "已取消。"; return; }

    # 用固定字符串匹配删除该行
    grep -vF "$TARGET_LINE" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    info "公钥已删除 ✓"
}

# ── 4. 登录方式设置 ───────────────────────────────────────
set_login_mode() {
    title " 登录方式设置"

    local CURRENT_PWD CURRENT_PUBKEY CURRENT_ROOT
    CURRENT_PWD=$(get_config "PasswordAuthentication")
    CURRENT_PUBKEY=$(get_config "PubkeyAuthentication")
    CURRENT_ROOT=$(get_config "PermitRootLogin")

    echo -e "  当前配置："
    echo -e "  PasswordAuthentication : ${BOLD}${CURRENT_PWD:-未设置}${NC}"
    echo -e "  PubkeyAuthentication   : ${BOLD}${CURRENT_PUBKEY:-未设置}${NC}"
    echo -e "  PermitRootLogin        : ${BOLD}${CURRENT_ROOT:-未设置}${NC}"
    echo ""
    echo -e "  请选择登录方式："
    echo -e "  ${GREEN}1${NC}) 仅密钥登录（禁用密码）  ${YELLOW}[推荐]${NC}"
    echo -e "  ${GREEN}2${NC}) 密码 + 密钥均可登录"
    echo -e "  ${GREEN}3${NC}) 仅密码登录（禁用密钥）  ${RED}[不推荐]${NC}"
    echo -e "  ${GREEN}4${NC}) 返回主菜单"
    echo ""
    read -rp "请选择 [1-4]: " MODE

    case "$MODE" in
        1)
            if ! list_keys > /dev/null 2>&1; then
                warn "当前没有公钥！启用仅密钥登录前请先添加公钥，否则将被锁定！"
                read -rp "仍要继续？(yes/no): " FORCE
                [ "$FORCE" != "yes" ] && { warn "已取消。"; return; }
            fi
            backup_config
            set_config "PasswordAuthentication" "no"
            set_config "PubkeyAuthentication"   "yes"
            set_config "PermitRootLogin"        "prohibit-password"
            apply_and_restart && info "已切换为：仅密钥登录 ✓"
            ;;
        2)
            backup_config
            set_config "PasswordAuthentication" "yes"
            set_config "PubkeyAuthentication"   "yes"
            set_config "PermitRootLogin"        "yes"
            apply_and_restart && info "已切换为：密码 + 密钥均可登录 ✓"
            ;;
        3)
            warn "仅密码登录安全性较低，建议配合强密码使用！"
            read -rp "确认切换？(yes/no): " CONFIRM
            [ "$CONFIRM" != "yes" ] && { warn "已取消。"; return; }
            backup_config
            set_config "PasswordAuthentication" "yes"
            set_config "PubkeyAuthentication"   "no"
            set_config "PermitRootLogin"        "yes"
            apply_and_restart && info "已切换为：仅密码登录 ✓"
            ;;
        4|*) return ;;
    esac
}

# ── 5. 修改 SSH 端口 ──────────────────────────────────────
change_port() {
    title " 修改 SSH 端口"

    local CURRENT_PORT
    CURRENT_PORT=$(get_config "Port")
    echo -e "  当前端口：${BOLD}${CURRENT_PORT:-22}${NC}"
    echo ""
    read -rp "请输入新端口号（直接回车取消）: " INPUT_PORT

    [ -z "$INPUT_PORT" ] && { warn "已取消。"; return; }

    if ! echo "$INPUT_PORT" | grep -qE '^[0-9]+$' || [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        error "无效端口号：$INPUT_PORT（请输入 1-65535）"
        return
    fi

    if [ "$INPUT_PORT" = "${CURRENT_PORT:-22}" ]; then
        warn "端口未变化，无需修改。"
        return
    fi

    backup_config
    set_config "Port" "$INPUT_PORT"

    if ! sshd -t 2>/dev/null; then
        error "配置语法错误，已取消。"
        return
    fi

    firewall_allow_port "$INPUT_PORT"
    apply_and_restart

    echo ""
    warn "⚠️  请【保持当前连接不断开】，新开终端测试新端口："
    echo -e "     ${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    echo ""
    warn "确认登录成功后再关闭当前会话！"
}

# ══════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════
main_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}╔══════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║       SSH 管理工具               ║${NC}"
        echo -e "${BOLD}${CYAN}╚══════════════════════════════════╝${NC}"

        # 状态摘要
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|ssh-dss) ' "$AUTH_KEYS" 2>/dev/null || echo 0)

        echo -e "  端口：${BOLD}${CUR_PORT:-22}${NC}  |  密码登录：${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证：${BOLD}${CUR_PUBKEY:-未设置}${NC}  |  公钥数：${BOLD}${KEYCOUNT}${NC}"
        echo -e "${CYAN}──────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1${NC}) 查看已有公钥"
        echo -e "  ${GREEN}2${NC}) 添加公钥"
        echo -e "  ${GREEN}3${NC}) 删除公钥"
        echo -e "  ${GREEN}4${NC}) 设置登录方式（密码 / 密钥）"
        echo -e "  ${GREEN}5${NC}) 修改 SSH 端口"
        echo -e "  ${RED}0${NC}) 退出"
        echo -e "${CYAN}──────────────────────────────────────${NC}"
        read -rp "请选择功能 [0-5]: " CHOICE
        echo ""

        case "$CHOICE" in
            1) show_keys ;;
            2) add_key ;;
            3) delete_key ;;
            4) set_login_mode ;;
            5) change_port ;;
            0) echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac

        echo ""
        read -rp "按 Enter 返回主菜单..." _
    done
}

main_menu
