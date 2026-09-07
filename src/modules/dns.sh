# ══════════════════════════════════════════════════════════
#  DNS 优化模块
# ══════════════════════════════════════════════════════════

dns_show_current() {
    echo -e "  ${BOLD}当前 DNS 地址：${NC}"
    grep "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r line; do
        local IP; IP=$(echo "$line" | awk '{print $2}')
        if echo "$IP" | grep -q ":"; then
            echo -e "    ${YELLOW}$line${NC}  ${DIM}(IPv6)${NC}"
        else
            echo -e "    ${CYAN}$line${NC}  ${DIM}(IPv4)${NC}"
        fi
    done
}

# 检测网络协议支持
dns_detect_network() {
    local HAS_V4=false HAS_V6=false
    # 检测 IPv4 全局地址
    ip -4 addr show scope global 2>/dev/null | grep -q "inet " && HAS_V4=true
    # 检测 IPv6 全局地址
    local V6_DISABLED
    V6_DISABLED=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [ "$V6_DISABLED" != "1" ]; then
        ip -6 addr show scope global 2>/dev/null | grep -q "inet6" && HAS_V6=true
    fi
    echo "${HAS_V4}:${HAS_V6}"
}

dns_expected_nameservers() {
    local V4_LIST="$1" V6_LIST="$2" HAS_V6="$3"
    printf '%s\n' $V4_LIST
    [ "$HAS_V6" = "true" ] && [ -n "$V6_LIST" ] && printf '%s\n' $V6_LIST
}

dns_resolv_nameservers_match() {
    local RESOLV="$1" V4_LIST="$2" V6_LIST="$3" HAS_V6="$4" ACTUAL EXPECTED
    [ -r "$RESOLV" ] || return 1
    ACTUAL=$(awk '/^[[:space:]]*nameserver[[:space:]]+/ { print $2 }' "$RESOLV" 2>/dev/null)
    EXPECTED=$(dns_expected_nameservers "$V4_LIST" "$V6_LIST" "$HAS_V6")
    [ "$ACTUAL" = "$EXPECTED" ]
}

dns_resolvconf_configure() {
    local V4_LIST="$1" V6_LIST="$2" HAS_V6="$3"
    local CONF="${DNS_RESOLVCONF_CONFIG:-/etc/resolvconf.conf}" TMP ALL_DNS
    ALL_DNS="$V4_LIST"
    [ "$HAS_V6" = "true" ] && [ -n "$V6_LIST" ] && ALL_DNS="$ALL_DNS $V6_LIST"
    TMP=$(mktemp "${CONF}.vps-tools.XXXXXX") || return 1
    if [ -f "$CONF" ]; then
        awk '
            $0 == "# BEGIN VPS TOOLS DNS" { skip=1; next }
            $0 == "# END VPS TOOLS DNS" { skip=0; next }
            !skip { print }
        ' "$CONF" > "$TMP" || { rm -f "$TMP"; return 1; }
    fi
    {
        [ ! -s "$TMP" ] || printf '\n'
        printf '%s\n' '# BEGIN VPS TOOLS DNS'
        # Remove all interface/DHCP nameservers before adding the selected list.
        printf '%s\n' 'replace="${replace:-} nameserver/*/"'
        printf 'name_servers="%s"\n' "$ALL_DNS"
        printf '%s\n' '# END VPS TOOLS DNS'
    } >> "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 644 "$TMP" 2>/dev/null || true
    mv "$TMP" "$CONF" || { rm -f "$TMP"; return 1; }
}

dns_resolvconf_apply() {
    local RESOLV="$1" V4_LIST="$2" V6_LIST="$3" HAS_V6="$4"
    local RESOLVCONF_BIN="${DNS_RESOLVCONF_BIN:-resolvconf}"
    command -v "$RESOLVCONF_BIN" >/dev/null 2>&1 || return 1
    dns_resolvconf_configure "$V4_LIST" "$V6_LIST" "$HAS_V6" || return 1
    "$RESOLVCONF_BIN" -u || return 1
    dns_resolv_nameservers_match "$RESOLV" "$V4_LIST" "$V6_LIST" "$HAS_V6"
}

dns_write() {
    local V4_LIST="$1"
    local V6_LIST="$2"
    local HAS_V6="$3"  # 是否写入 v6 DNS
    local RESOLV="/etc/resolv.conf" ALL_DNS="$V4_LIST" BACKEND="static" CON
    [ "$HAS_V6" = "true" ] && [ -n "$V6_LIST" ] && ALL_DNS="$ALL_DNS $V6_LIST"
    confirm_change_preview "DNS 配置" "当前：$(awk '/^nameserver/ {printf "%s ", $2}' "$RESOLV" 2>/dev/null)" "目标：$ALL_DNS" || { warn "已取消"; return; }
    safety_arm dns || return 1

    if command -v resolvectl >/dev/null 2>&1 && { svc_is_active systemd-resolved || { [ -L "$RESOLV" ] && readlink "$RESOLV" | grep -q 'systemd/resolve'; }; }; then
        BACKEND="systemd-resolved"
        mkdir -p /etc/systemd/resolved.conf.d || return 1
        if ! {
            echo "[Resolve]"
            echo "DNS=$ALL_DNS"
            echo "FallbackDNS="
        } > /etc/systemd/resolved.conf.d/99-vps-tools.conf; then
            error "无法写入 systemd-resolved 配置"
            return 1
        fi
        svc_restart systemd-resolved || { error "systemd-resolved 重启失败"; return 1; }
    elif command -v nmcli >/dev/null 2>&1 && svc_is_active NetworkManager; then
        BACKEND="NetworkManager"
        local NM_COUNT=0
        while IFS= read -r CON; do
            [ -n "$CON" ] || continue
            NM_COUNT=$((NM_COUNT + 1))
            nmcli connection modify "$CON" ipv4.ignore-auto-dns yes ipv4.dns "$V4_LIST" 2>/dev/null \
                || { error "NetworkManager IPv4 DNS 写入失败：$CON"; return 1; }
            if [ "$HAS_V6" = true ] && [ -n "$V6_LIST" ]; then
                nmcli connection modify "$CON" ipv6.ignore-auto-dns yes ipv6.dns "$V6_LIST" 2>/dev/null \
                    || { error "NetworkManager IPv6 DNS 写入失败：$CON"; return 1; }
            else
                nmcli connection modify "$CON" ipv6.ignore-auto-dns yes ipv6.dns "" 2>/dev/null \
                    || { error "NetworkManager IPv6 自动 DNS 清理失败：$CON"; return 1; }
            fi
        done < <(nmcli -g NAME connection show --active 2>/dev/null)
        [ "$NM_COUNT" -gt 0 ] || { error "NetworkManager 没有活动连接"; return 1; }
        nmcli device reapply "$(default_iface)" 2>/dev/null || svc_restart NetworkManager \
            || { error "NetworkManager DNS 应用失败"; return 1; }
    elif command -v resolvconf >/dev/null 2>&1; then
        if resolvconf --version 2>/dev/null | grep -qi openresolv || [ -f /etc/resolvconf.conf ]; then
            BACKEND="openresolv"
            dns_resolvconf_apply "$RESOLV" "$V4_LIST" "$V6_LIST" "$HAS_V6" \
                || { error "openresolv DNS 覆盖失败"; return 1; }
        else
            BACKEND="resolvconf exclusive"
            dns_expected_nameservers "$V4_LIST" "$V6_LIST" "$HAS_V6" \
                | sed 's/^/nameserver /' \
                | resolvconf -a vps-tools -x \
                || { error "resolvconf 独占 DNS 覆盖失败"; return 1; }
        fi
    else
        chattr -i "$RESOLV" 2>/dev/null || true
        cp -a "$RESOLV" "${RESOLV}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        local OTHER
        OTHER=$(grep -v "^nameserver" "$RESOLV" 2>/dev/null)
        if ! {
            [ -n "$OTHER" ] && echo "$OTHER"
            for ip in $ALL_DNS; do echo "nameserver $ip"; done
        } > "$RESOLV"; then
            error "无法写入 $RESOLV"
            return 1
        fi
    fi

    if { [ "$BACKEND" = "openresolv" ] || [ "$BACKEND" = "resolvconf exclusive" ]; } \
        && ! dns_resolv_nameservers_match "$RESOLV" "$V4_LIST" "$V6_LIST" "$HAS_V6"; then
        error "DNS 后端未按目标覆盖，实际配置未改变"
        audit_action "DNS更新失败，后端 $BACKEND 未覆盖旧 nameserver" FAILED
        return 1
    fi

    local DNS_OK=false
    if command -v getent >/dev/null 2>&1; then getent hosts github.com >/dev/null 2>&1 && DNS_OK=true
    elif command -v nslookup >/dev/null 2>&1; then nslookup github.com >/dev/null 2>&1 && DNS_OK=true
    else ping -c 1 -W 3 github.com >/dev/null 2>&1 && DNS_OK=true
    fi
    if [ "$DNS_OK" != true ]; then
        error "DNS 解析测试失败，保留自动回滚计时器"
        audit_action "DNS更新失败，后端 $BACKEND" FAILED
        return 1
    fi
    info "DNS 已通过 $BACKEND 持久化更新 ✓"
    audit_action "更新DNS，后端 $BACKEND" SUCCESS
    echo ""
    echo -e "  ${BOLD}更新后：${NC}"
    grep "^nameserver" "$RESOLV" | while read -r line; do
        local IP; IP=$(echo "$line" | awk '{print $2}')
        echo "$IP" | grep -q ":"             && echo -e "    ${YELLOW}$line${NC}  ${DIM}(IPv6)${NC}"             || echo -e "    ${CYAN}$line${NC}  ${DIM}(IPv4)${NC}"
    done
    safety_confirm
}

dns_menu() {
    while true; do
        print_header "DNS 优化"
        dns_show_current
        echo ""

        # 检测网络协议
        local NET_INFO; NET_INFO=$(dns_detect_network)
        local HAS_V4; HAS_V4=$(echo "$NET_INFO" | cut -d: -f1)
        local HAS_V6; HAS_V6=$(echo "$NET_INFO" | cut -d: -f2)

        # 显示当前网络状态
        local V4_LABEL V6_LABEL
        [ "$HAS_V4" = "true" ] && V4_LABEL="${GREEN}有 IPv4${NC}" || V4_LABEL="${YELLOW}无 IPv4${NC}"
        [ "$HAS_V6" = "true" ] && V6_LABEL="${GREEN}有 IPv6${NC}" || V6_LABEL="${DIM}无 IPv6${NC}"
        echo -e "  网络：$V4_LABEL  $V6_LABEL"
        [ "$HAS_V6" = "true" ] || echo -e "  ${DIM}（未检测到 IPv6，仅显示 IPv4 DNS 选项）${NC}"
        echo ""

        menu_div
        echo -e "  ${BOLD}国外 DNS：${NC}"
        if [ "$HAS_V6" = "true" ]; then
            menu_item "1" "Cloudflare  ${DIM}v4 1.1.1.1 / 1.0.0.1${NC}"
            echo -e "             v6: 2606:4700:4700::1111"
            menu_item "2" "Google  ${DIM}v4 8.8.8.8 / 8.8.4.4${NC}"
            echo -e "             v6: 2001:4860:4860::8888"
            menu_item "3" "混合推荐  ${DIM}Cloudflare + Google 双栈${NC}"
        else
            menu_item "1" "Cloudflare  ${DIM}1.1.1.1 / 1.0.0.1${NC}"
            menu_item "2" "Google  ${DIM}8.8.8.8 / 8.8.4.4${NC}"
            menu_item "3" "混合推荐  ${DIM}1.1.1.1 + 8.8.8.8${NC}"
        fi
        menu_div
        echo -e "  ${BOLD}国内 DNS：${NC}"
        if [ "$HAS_V6" = "true" ]; then
            menu_item "4" "阿里云  ${DIM}v4 223.5.5.5 / 223.6.6.6${NC}"
            echo -e "             v6: 2400:3200::1"
            menu_item "5" "腾讯 DNSPod  ${DIM}119.29.29.29 / 183.60.83.19${NC}"
            menu_item "6" "114 DNS  ${DIM}114.114.114.114 / 114.114.115.115${NC}"
        else
            menu_item "4" "阿里云  ${DIM}223.5.5.5 / 223.6.6.6${NC}"
            menu_item "5" "腾讯 DNSPod  ${DIM}119.29.29.29 / 183.60.83.19${NC}"
            menu_item "6" "114 DNS  ${DIM}114.114.114.114 / 114.114.115.115${NC}"
        fi
        menu_div
        menu_item "7" "手动编辑 DNS 配置"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择 DNS [0-7]: ')" CH

        case "$CH" in
            1) dns_write "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001" "$HAS_V6" ;;
            2) dns_write "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844" "$HAS_V6" ;;
            3) dns_write "1.1.1.1 8.8.8.8" "2606:4700:4700::1111 2001:4860:4860::8888" "$HAS_V6" ;;
            4) dns_write "223.5.5.5 223.6.6.6" "2400:3200::1 2400:3200:baba::1" "$HAS_V6" ;;
            5) dns_write "119.29.29.29 183.60.83.19" "" "$HAS_V6" ;;
            6) dns_write "114.114.114.114 114.114.115.115" "" "$HAS_V6" ;;
            7)
                warn "即将用 $(get_editor) 编辑 /etc/resolv.conf"
                confirm_change_preview "手动编辑 DNS" "文件：/etc/resolv.conf" "保存后将立即影响域名解析" || { warn "已取消"; continue; }
                safety_arm dns_manual || return 1
                chattr -i /etc/resolv.conf 2>/dev/null
                ui_continue
                open_editor /etc/resolv.conf
                local MANUAL_DNS_OK=false
                if command -v getent >/dev/null 2>&1 && getent hosts github.com >/dev/null 2>&1; then
                    MANUAL_DNS_OK=true
                elif command -v nslookup >/dev/null 2>&1 && nslookup github.com >/dev/null 2>&1; then
                    MANUAL_DNS_OK=true
                elif ping -c 1 -W 3 github.com >/dev/null 2>&1; then
                    MANUAL_DNS_OK=true
                fi
                if [ "$MANUAL_DNS_OK" = true ]; then
                    info "DNS 配置已保存并通过解析测试"
                    audit_action "手动编辑DNS配置" SUCCESS
                    safety_confirm
                else
                    error "DNS 解析测试失败，自动回滚计时器仍在运行"
                    audit_action "手动编辑DNS配置失败" FAILED
                fi
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}
