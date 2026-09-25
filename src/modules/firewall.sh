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
        firewalld) svc_is_active firewalld && echo "active" || echo "inactive" ;;
        *) echo "none" ;;
    esac
}

# ── 放行常用端口（安装防火墙后调用）────────────────────────
fw_allow_common_ports() {
    local TYPE="$1"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    info "放行常用端口：SSH ${SSH_PORT} / HTTP 80 / HTTPS 443 ..."
    case "$TYPE" in
        ufw)
            ufw allow "${SSH_PORT}"/tcp 2>/dev/null || { error "无法放行 SSH ${SSH_PORT}/tcp"; return 1; }
            ufw allow 80/tcp 2>/dev/null || { error "无法放行 HTTP 80/tcp"; return 1; }
            ufw allow 443/tcp 2>/dev/null || { error "无法放行 HTTPS 443/tcp"; return 1; }
            info "SSH ${SSH_PORT} / HTTP 80 / HTTPS 443 已放行 ✓"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" 2>/dev/null || return 1
            firewall-cmd --permanent --add-port="80/tcp" 2>/dev/null || return 1
            firewall-cmd --permanent --add-port="443/tcp" 2>/dev/null || return 1
            firewall-cmd --reload 2>/dev/null || return 1
            info "firewalld 已放行 SSH ${SSH_PORT} / 80 / 443 ✓"
            ;;
    esac
}

# ── 安装防火墙 ────────────────────────────────────────────
fw_install() {
    local TYPE="$1"
    print_header "安装防火墙"
    info "正在更新软件包列表..."
    case "$TYPE" in
        ufw)
            if pkg_install ufw; then
                info "ufw 安装成功 ✓"
                safety_arm firewall_install || return 1
                fw_allow_common_ports "ufw" || { error "基础端口放行失败，未启用 ufw"; return 1; }
                if ufw --force enable >/dev/null 2>&1 && [ "$(fw_running ufw)" = active ]; then
                    info "ufw 已启用 ✓"
                else
                    error "ufw 启用失败"
                    return 1
                fi
                safety_confirm
            else
                error "安装失败，请检查网络或手动安装：apt/apk install ufw"
                return 1
            fi
            ;;
        firewalld)
            if pkg_install firewalld; then
                safety_arm firewall_install || return 1
                svc_enable firewalld
                svc_start firewalld || { error "firewalld 启动失败"; return 1; }
                [ "$(fw_running firewalld)" = active ] || { error "firewalld 未进入运行状态"; return 1; }
                info "firewalld 安装并启动成功 ✓"
                fw_allow_common_ports "firewalld" || { error "基础端口放行失败"; return 1; }
                safety_confirm
            else
                error "安装失败，请检查网络或手动安装"
                return 1
            fi
            ;;
    esac
}

# ══════════════════════════════════════════════════════════
#  UFW 子功能
# ══════════════════════════════════════════════════════════

ufw_show_rules() {
    print_header "防火墙规则 — ufw"
    menu_div
    ufw status numbered 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -qE '^\['; then
            echo -e "  ${GREEN}${line}${NC}"
        else
            echo -e "  ${line}"
        fi
    done
    menu_div
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
    while true; do
        print_header "删除端口规则 — ufw"
        ufw status numbered 2>/dev/null | grep -E '^\[' | while IFS= read -r line; do
            echo -e "  ${YELLOW}${line}${NC}"
        done
        echo ""
        menu_div
        echo -e "  ${DIM}输入编号删除，直接回车返回上级${NC}"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_read NUM "请输入规则编号: " || return 0
        [ "$NUM" = "0" ] && return 0
        [ -z "$NUM" ] && return
        if ! echo "$NUM" | grep -qE '^[0-9]+$'; then
            error "无效编号"; sleep 1; continue
        fi
        echo "y" | ufw delete "$NUM" 2>/dev/null && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
        sleep 1
    done
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
    while true; do
        print_header "删除 IP 规则 — ufw"
        ufw status numbered 2>/dev/null | grep -iE 'deny|allow' | grep -E '^\[' | while IFS= read -r line; do
            echo -e "  ${YELLOW}${line}${NC}"
        done
        echo ""
        menu_div
        echo -e "  ${DIM}输入编号删除，直接回车返回上级${NC}"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_read NUM "请输入规则编号: " || return 0
        [ "$NUM" = "0" ] && return 0
        [ -z "$NUM" ] && return
        echo "y" | ufw delete "$NUM" 2>/dev/null && info "规则 [$NUM] 已删除 ✓" || error "删除失败"
        sleep 1
    done
}

ufw_quick_allow() {
    print_header "一键放行常用端口 — ufw"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT"
    echo -e "  ${GREEN}HTTP${NC}  : 80"
    echo -e "  ${GREEN}HTTPS${NC} : 443"
    echo ""
    read -rp "  确认放行？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
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
        menu_div
        if [ "$STATUS" = "active" ]; then
            menu_item "1" "关闭防火墙" "$YELLOW"
        else
            menu_item "1" "开启防火墙"
        fi
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行 IP" "7" "删除 IP 规则"
        menu_item "8" "一键放行常用端口"
        menu_pair "u" "安装 / 更新" "9" "卸载 ufw" "$CYAN" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-9 / u]: ' || return 0

        case "$CH" in 1|3|4|5|6|7|8) safety_arm ufw || continue ;; esac

        case "$CH" in
            u|U)
                print_header "安装/更新 ufw"
                info "正在更新 ufw..."
                pkg_install ufw
                local NEW_VER; NEW_VER=$(ufw version 2>/dev/null | head -1)
                info "当前版本：${NEW_VER:-未知} ✓"
                sleep 1; continue
                ;;
            1)
                if [ "$STATUS" = "active" ]; then
                    ufw --force disable && info "防火墙已关闭 ✓"
                else
                    ufw --force enable  && info "防火墙已开启 ✓"
                fi
                audit_action "切换ufw状态" SUCCESS
                ;;
            2) ufw_show_rules ;;
            3) ufw_add_port ;;
            4) ufw_del_port ;;
            5) ufw_block_ip ;;
            6) ufw_allow_ip ;;
            7) ufw_del_ip ;;
            8) ufw_quick_allow ;;
            9)
                warn "即将卸载 ufw，所有规则将清除"
                read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
                [ -z "${CONFIRM}" ] && CONFIRM="y"
    if echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then
                    # 完整清理：禁用 → 重置规则 → 卸载 → 清残留
                    warn "即将卸载 ufw 并清理其规则（默认策略与其它规则不受影响）"
                    sleep 1
                    ufw --force disable 2>/dev/null
                    ufw --force reset 2>/dev/null
                    pkg_remove ufw
                    # 清理残留文件（防止重装时读到旧配置）
                    rm -rf /etc/ufw /lib/ufw /usr/share/ufw 2>/dev/null
                    clear_iptables_residue  # 清理 iptables 残留规则
                    info "ufw 已完整卸载 ✓（仅清理 ufw 自身规则，SSH 仍可连接）"
                    return
                else
                    warn "已取消"
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        case "$CH" in 1|3|4|5|6|7|8) safety_confirm ;; esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

# ══════════════════════════════════════════════════════════
#  Firewalld 子功能
# ══════════════════════════════════════════════════════════

fwd_show_rules() {
    print_header "防火墙规则 — firewalld"
    local ZONE; ZONE=$(firewall-cmd --get-default-zone 2>/dev/null)
    echo -e "  默认 Zone：${BOLD}${ZONE}${NC}"
    menu_div
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
    menu_div
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
    while true; do
        print_header "删除 IP 规则 — firewalld"
        echo -e "  当前 Rich Rules："
        local RULES; RULES=$(firewall-cmd --list-rich-rules 2>/dev/null)
        if [ -z "$RULES" ]; then
            echo -e "  ${YELLOW}暂无 IP 规则${NC}"
            echo ""
            ui_pause
            return
        fi
        local i=1
        while IFS= read -r r; do
            echo -e "  ${YELLOW}[$i]${NC} $r"
            i=$((i+1))
        done <<< "$RULES"
        echo ""
        menu_div
        echo -e "  ${DIM}输入 IP 地址删除，直接回车返回上级${NC}"
        read -rp "  请输入 IP: " IP
        [ -z "$IP" ] && return
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' reject" 2>/dev/null
        firewall-cmd --permanent --remove-rich-rule="rule family='ipv4' source address='${IP}' accept" 2>/dev/null
        firewall-cmd --reload 2>/dev/null && info "IP $IP 相关规则已删除 ✓" || error "删除失败"
        sleep 1
    done
}

fwd_quick_allow() {
    print_header "一键放行常用端口 — firewalld"
    local SSH_PORT; SSH_PORT=$(get_config "Port"); SSH_PORT="${SSH_PORT:-22}"
    echo -e "  将放行以下端口："
    echo -e "  ${GREEN}SSH${NC}   : $SSH_PORT/tcp"
    echo -e "  ${GREEN}HTTP${NC}  : 80/tcp"
    echo -e "  ${GREEN}HTTPS${NC} : 443/tcp"
    echo ""
    read -rp "  确认放行？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
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
        menu_div
        if [ "$STATUS" = "active" ]; then
            menu_item "1" "关闭防火墙" "$YELLOW"
        else
            menu_item "1" "开启防火墙"
        fi
        menu_pair "2" "查看规则" "3" "添加端口"
        menu_pair "4" "删除端口" "5" "拉黑 IP"
        menu_pair "6" "放行 IP" "7" "删除 IP 规则"
        menu_item "8" "一键放行常用端口"
        menu_item "9" "卸载 firewalld" "$YELLOW"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-9]: ' || return 0

        case "$CH" in 1|3|4|5|6|7|8) safety_arm firewalld || continue ;; esac

        case "$CH" in
            1)
                if [ "$STATUS" = "active" ]; then
                    svc_stop firewalld && info "防火墙已关闭 ✓"
                else
                    svc_start firewalld && info "防火墙已开启 ✓"
                fi
                audit_action "切换firewalld状态" SUCCESS
                ;;
            2) fwd_show_rules ;;
            3) fwd_add_port ;;
            4) fwd_del_port ;;
            5) fwd_block_ip ;;
            6) fwd_allow_ip ;;
            7) fwd_del_ip ;;
            8) fwd_quick_allow ;;
            9)
                warn "即将卸载 firewalld，所有规则将清除"
                read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
                [ -z "${CONFIRM}" ] && CONFIRM="y"
    if echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then
                    svc_stop firewalld
                    svc_disable firewalld
                    pkg_remove firewalld
                    # 清理残留配置
                    rm -rf /etc/firewalld/zones /etc/firewalld/services 2>/dev/null
                    clear_iptables_residue  # 清理 iptables 残留规则
                    info "firewalld 已完整卸载 ✓（仅清理 firewalld 自身规则）"
                    return
                else
                    warn "已取消"
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        case "$CH" in 1|3|4|5|6|7|8) safety_confirm ;; esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

# ══════════════════════════════════════════════════════════
#  防火墙总入口
# ══════════════════════════════════════════════════════════
firewall_menu() {
    while true; do
        local FW_TYPE; FW_TYPE=$(fw_detect)

        if [ "$FW_TYPE" = "none" ]; then
            print_header "防火墙管理"
            warn "未检测到已安装的防火墙！"
            echo ""
            menu_div
            echo -e "  请选择要安装的防火墙："
            menu_item "1" "ufw  ${DIM}Ubuntu / Debian 推荐${NC}"
            menu_item "2" "firewalld  ${DIM}Rocky / Fedora 推荐${NC}"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            menu_div
            echo ""
            menu_read CH '选择防火墙 [0-2]: ' || return 0
            case "$CH" in
                1) fw_install "ufw";       ui_continue ;;
                2) fw_install "firewalld"; ui_continue ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi

        # 已安装：直接进子菜单，子菜单按 0 返回后退出 firewall_menu
        case "$FW_TYPE" in
            ufw)       ufw_menu ;;
            firewalld) fwd_menu ;;
        esac
        # 子菜单返回后（按 0 或卸载后）直接返回主菜单
        return
    done
}
