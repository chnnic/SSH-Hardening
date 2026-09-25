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
    confirm_change_preview "IPv4 优先" "写入 gai.conf 地址优先级规则" "不关闭 IPv6" || { warn "已取消"; return; }
    safety_arm prefer_v4 || return 1

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
    audit_action "设置IPv4优先" SUCCESS
    safety_confirm
}

ip_prefer_v6() {
    print_header "设置 IPv6 优先"
    local GAICONF="/etc/gai.conf"
    confirm_change_preview "IPv6 优先" "移除脚本写入的 IPv4 优先规则" "恢复系统默认地址选择策略" || { warn "已取消"; return; }
    safety_arm prefer_v6 || return 1

    [ -f "$GAICONF" ] && cp "$GAICONF" "${GAICONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    [ -f "$GAICONF" ] || touch "$GAICONF"

    # 移除本脚本写入的 IPv4 优先规则，恢复 glibc 默认地址选择策略（IPv6 优先）。
    sed -i '/^precedence ::ffff:0:0\/96[[:space:]]\+100/d' "$GAICONF" 2>/dev/null

    info "已移除 IPv4 优先规则，恢复 IPv6 优先（系统默认）✓"
    echo ""
    warn "IPv6 优先已生效，部分程序需重启才能感知变化"
    echo ""
    echo -e "  验证（如网络可用，应显示 IPv6 连接）："
    echo -e "  ${DIM}curl -6 -s --max-time 5 ip.sb${NC}"
    local RESULT; RESULT=$(curl -6 -s --max-time 5 ip.sb 2>/dev/null)
    [ -n "$RESULT" ] && echo -e "  当前 IPv6 出口：${BOLD}${RESULT}${NC}" || warn "无法通过 IPv6 连接 ip.sb 进行验证"
    audit_action "设置IPv6优先" SUCCESS
    safety_confirm
}

ip_disable_v6() {
    print_header "关闭 IPv6"
    warn "关闭 IPv6 后，仅 IPv6 的服务将无法访问！"
    echo ""
    read -rp "  确认关闭？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
    confirm_change_preview "关闭 IPv6" "立即禁用所有接口 IPv6" "写入 sysctl 持久化配置" || { warn "已取消"; return; }
    safety_arm disable_v6 || return 1

    ip_apply_v6_state 1 || { error "IPv6 禁用失败，自动回滚计时器仍在运行"; return 1; }
    info "IPv6 已通过 sysctl 禁用 ✓"

    echo ""
    echo -e "  当前 IPv6 状态：${RED}${BOLD}已禁用${NC}"
    warn "如 SSH 监听了 IPv6，建议确认 SSH 配置正常后再断开连接"
    audit_action "关闭IPv6" SUCCESS
    safety_confirm
}

ip_enable_v6() {
    print_header "开启 IPv6"
    confirm_change_preview "开启 IPv6" "移除 IPv6 禁用状态" "地址获取取决于服务商和 SLAAC" || { warn "已取消"; return; }
    safety_arm enable_v6 || return 1

    ip_apply_v6_state 0 || { error "IPv6 开启失败，自动回滚计时器仍在运行"; return 1; }

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
    audit_action "开启IPv6" SUCCESS
    safety_confirm
}

ip_apply_v6_state() {
    local VALUE="$1" SYSCTL_FILE="/etc/sysctl.d/99-ipv6-disable.conf" TMP KEY
    ensure_sysctl || return 1
    mkdir -p /etc/sysctl.d || return 1
    TMP=$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX") || return 1
    for KEY in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
        printf '%s = %s\n' "$KEY" "$VALUE" >> "$TMP" || { rm -f "$TMP"; return 1; }
    done
    chmod 644 "$TMP" 2>/dev/null || true
    mv "$TMP" "$SYSCTL_FILE" || { rm -f "$TMP"; return 1; }
    sysctl -p "$SYSCTL_FILE" &>/dev/null || return 1
    for KEY in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
        [ "$(sysctl -n "$KEY" 2>/dev/null)" = "$VALUE" ] || return 1
    done
}

ip_source_probe() {
    case "$1" in
        4) echo "1.1.1.1" ;;
        6) echo "2606:4700:4700::1111" ;;
        *) return 1 ;;
    esac
}

ip_source_default_iface() {
    local family="$1" probe route
    probe=$(ip_source_probe "$family") || return 1
    route=$(ip "-$family" route get "$probe" 2>/dev/null | head -1) || return 1
    awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<< "$route"
}

ip_source_current() {
    local family="$1" probe route
    probe=$(ip_source_probe "$family") || return 1
    route=$(ip "-$family" route get "$probe" 2>/dev/null | head -1) || return 1
    awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<< "$route"
}

ip_source_addresses() {
    local family="$1" iface="$2" kind
    [ "$family" = "4" ] && kind="inet" || kind="inet6"
    ip "-$family" -o addr show dev "$iface" scope global 2>/dev/null | awk -v kind="$kind" '
        $3 == kind && $0 !~ /(^|[[:space:]])(tentative|dadfailed|deprecated|temporary)([[:space:]]|$)/ {
            sub(/\/.*/, "", $4)
            if (!seen[$4]++) print $4
        }
    '
}

ip_source_default_route() {
    local family="$1"
    ip "-$family" route show default 2>/dev/null
}

ip_source_route_replace() {
    local family="$1" route_line="$2" selected="$3" token skip_next=0
    local tokens=() output=()
    read -r -a tokens <<< "$route_line"
    [ "${#tokens[@]}" -gt 0 ] && [ "${tokens[0]}" = "default" ] || return 1
    for token in "${tokens[@]}"; do
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0
            continue
        fi
        case "$token" in
            src|expires)
                skip_next=1
                ;;
            *) output+=("$token") ;;
        esac
    done
    ip "-$family" route replace "${output[@]}" src "$selected"
}

ip_source_route_restore() {
    local family="$1" route_line="$2" token skip_next=0
    local tokens=() output=()
    read -r -a tokens <<< "$route_line"
    [ "${#tokens[@]}" -gt 0 ] && [ "${tokens[0]}" = "default" ] || return 1
    for token in "${tokens[@]}"; do
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0
            continue
        fi
        case "$token" in
            expires) skip_next=1 ;;
            *) output+=("$token") ;;
        esac
    done
    ip "-$family" route replace "${output[@]}"
}

ip_source_safety_arm() {
    local family="$1" route_line="$2" script token skip_next=0
    local tokens=() output=()
    cancel_safety_timer
    read -r -a tokens <<< "$route_line"
    [ "${#tokens[@]}" -gt 0 ] || return 1
    for token in "${tokens[@]}"; do
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0
            continue
        fi
        case "$token" in
            expires) skip_next=1 ;;
            *) output+=("$token") ;;
        esac
    done
    mkdir -p "$VPS_DATA_DIR" || return 1
    script="$VPS_DATA_DIR/rollback_ip_source_$$_$(date +%s)_${RANDOM}.sh"
    {
        echo '#!/bin/bash'
        echo 'sleep 180'
        printf 'ip -%q route replace' "$family"
        for token in "${output[@]}"; do printf ' %q' "$token"; done
        echo ' >/dev/null 2>&1'
        printf 'logger -t vps-tools %q\n' "未确认连接，已自动恢复 IPv${family} 首选源地址"
        printf 'rm -f %q\n' "$script"
    } > "$script" || { rm -f "$script"; return 1; }
    chmod 700 "$script" || { rm -f "$script"; return 1; }
    nohup bash "$script" >/dev/null 2>&1 &
    SAFETY_PID=$!
    SAFETY_SCRIPT="$script"
    audit_action "启动防断联保护 IPv${family} 源地址切换" SUCCESS
    warn "防断联保护已启动：180 秒内未确认将自动恢复原默认路由。"
}

ip_source_verify() {
    local family="$1" selected="$2" probe actual endpoint public_ip
    probe=$(ip_source_probe "$family") || return 1
    actual=$(ip_source_current "$family" 2>/dev/null || true)
    [ "$actual" = "$selected" ] || return 1
    if [ "$family" = "4" ]; then
        endpoint="https://api.ipify.org"
    else
        endpoint="https://api64.ipify.org"
    fi
    public_ip=$(curl "-$family" --interface "$selected" -fsS --max-time 8 "$endpoint" 2>/dev/null) || return 1
    public_ip=${public_ip//$'\r'/}
    public_ip=${public_ip//$'\n'/}
    [ -n "$public_ip" ] || return 1
    IP_SOURCE_PUBLIC_IP="$public_ip"
}

ip_source_switch_family() {
    local family="$1" label iface current routes route_count route_line selected choice public_ip
    local addresses=() addr index=0
    [ "$family" = "4" ] && label="IPv4" || label="IPv6"
    iface=$(ip_source_default_iface "$family" 2>/dev/null || true)
    [ -n "$iface" ] || { error "未检测到 ${label} 默认出口网卡"; return 1; }
    routes=$(ip_source_default_route "$family" "$iface")
    route_count=$(awk 'NF {count++} END {print count+0}' <<< "$routes")
    if [ "$route_count" -ne 1 ] || grep -qw nexthop <<< "$routes"; then
        error "检测到多个或 ECMP ${label} 默认路由，已拒绝修改"
        echo -e "  ${DIM}此功能仅适用于单默认路由、同网卡多地址环境${NC}"
        return 1
    fi
    route_line=$(head -1 <<< "$routes")
    while IFS= read -r addr; do [ -n "$addr" ] && addresses+=("$addr"); done < <(ip_source_addresses "$family" "$iface")
    if [ "${#addresses[@]}" -lt 2 ]; then
        error "${iface} 上只有 ${#addresses[@]} 个可切换的稳定 ${label} 地址"
        return 1
    fi
    current=$(ip_source_current "$family" 2>/dev/null || true)

    print_header "${label} 多 IP 出口切换"
    echo -e "  网卡：${BOLD}${iface}${NC}"
    echo -e "  当前出口源地址：${BOLD}${current:-未知}${NC}"
    echo -e "  ${DIM}仅修改运行时默认路由，网络服务或 VPS 重启后可能恢复系统配置。${NC}"
    echo ""
    menu_div
    for addr in "${addresses[@]}"; do
        index=$((index + 1))
        if [ "$addr" = "$current" ]; then
            printf '  %2d) %-42s %b\n' "$index" "$addr" "${GREEN}当前${NC}"
        else
            printf '  %2d) %s\n' "$index" "$addr"
        fi
    done
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    menu_read choice "选择地址 [0-${#addresses[@]}]: " || return 0
    [ "$choice" = "0" ] && return 0
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#addresses[@]}" ] \
        || { warn "无效选项"; return 1; }
    selected=${addresses[$((choice - 1))]}
    [ "$selected" != "$current" ] || { info "该地址已经是当前出口源地址"; return 0; }

    confirm_change_preview "切换 ${label} 出口源地址" \
        "网卡：${iface}" "当前：${current:-自动选择}" "切换为：${selected}" \
        "仅修改运行时默认路由，不写入网络配置文件" || { warn "已取消"; return 0; }
    ip_source_safety_arm "$family" "$route_line" || { error "无法启动路由自动回滚保护"; return 1; }
    if ! ip_source_route_replace "$family" "$route_line" "$selected"; then
        cancel_safety_timer
        error "默认路由源地址切换失败"
        return 1
    fi
    if ! ip_source_verify "$family" "$selected"; then
        ip_source_route_restore "$family" "$route_line" >/dev/null 2>&1 || true
        cancel_safety_timer
        error "新源地址无法完成路由或 HTTPS 出口验证，已恢复原默认路由"
        return 1
    fi
    public_ip="$IP_SOURCE_PUBLIC_IP"
    info "${label} 首选源地址已切换为 ${selected} ✓"
    echo -e "  公网出口：${BOLD}${public_ip}${NC}"
    audit_action "切换${label}出口源地址 ${iface} ${selected}" SUCCESS
    safety_confirm
}

ip_source_switch_menu() {
    while true; do
        print_header "多 IP 出口切换"
        echo -e "  IPv4 当前源地址：${BOLD}$(ip_source_current 4 2>/dev/null || echo 未检测到)${NC}"
        echo -e "  IPv6 当前源地址：${BOLD}$(ip_source_current 6 2>/dev/null || echo 未检测到)${NC}"
        echo ""
        menu_div
        menu_pair "1" "切换 IPv4 出口地址" "2" "切换 IPv6 出口地址"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-2]: ' || return 0
        case "$CH" in
            1) ip_source_switch_family 4; ui_pause ;;
            2) ip_source_switch_family 6; ui_pause ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
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
        menu_div
        menu_item "1" "查看 IPv4 / IPv6 状态"
        menu_pair "2" "设置 IPv4 优先" "3" "设置 IPv6 优先"
        menu_pair "4" "关闭 IPv6" "5" "开启 IPv6"
        menu_item "6" "多 IP 出口切换（运行时）"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-6]: ' || return 0

        case "$CH" in
            1) ip_show_status ;;
            2) ip_prefer_v4 ;;
            3) ip_prefer_v6 ;;
            4) ip_disable_v6 ;;
            5) ip_enable_v6 ;;
            6) ip_source_switch_menu; continue ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}
