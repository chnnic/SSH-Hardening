# ══════════════════════════════════════════════════════════
#  脚本自我管理模块

# ── DDNS 主菜单 ───────────────────────────────────────────


# ══════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════
# ── 后台版本检测 ────────────────────────────────────────
self_check_update() {
    local REMOTE_VER
    REMOTE_VER=$(curl -fsSL --max-time 5 "$SCRIPT_URL" 2>/dev/null \
        | grep -oE 'VPS 开荒脚本 V[0-9]+[.][0-9]+[.][0-9]+|VPS 开荒脚本 V[0-9]+[.][0-9]+' \
        | head -1 | grep -oE 'V[0-9]+[.][0-9]+([.][0-9]+)?')
    [ -z "$REMOTE_VER" ] && return
    local CUR_VER
    CUR_VER=$(grep -oE 'VPS 开荒脚本 V[0-9]+[.][0-9]+[.][0-9]+|VPS 开荒脚本 V[0-9]+[.][0-9]+' "$0" 2>/dev/null \
        | head -1 | grep -oE 'V[0-9]+[.][0-9]+([.][0-9]+)?')
    [ -z "$CUR_VER" ] && return
    if [ "$REMOTE_VER" = "$CUR_VER" ]; then
        rm -f /tmp/.vps_new_version 2>/dev/null
        return
    fi
    echo "$REMOTE_VER" > /tmp/.vps_new_version 2>/dev/null
}

show_cli_help() {
    cat <<'EOF'
VPS 开荒脚本 CLI

用法:
  bash SSH-Hardening.sh [命令]

常用命令:
  --help                 显示此帮助
  --ssh-menu             SSH 工具集
  --fail2ban-menu        Fail2ban 管理
  --bbr-menu             BBR TCP 调优
  --bbr-reconcile-tc     按已保存状态恢复 tc 限速（内部入口）
  --firewall-menu        防火墙管理
  --dns-menu             DNS 优化
  --ddns-menu            DDNS 菜单（Cloudflare / 华为云 DNS）
  --ddns-install         安装 / 配置 DDNS
  --ddns-run             立即更新 DDNS
  --ddns-status          查看 DDNS 状态
  --ddns-log             查看 DDNS 日志
  --ddns-link            用 DDNS 域名替换分享链接地址
  --mirror-menu          系统换源
  --ip-menu              IPv4 / IPv6 配置
  --caddy-menu           Caddy 管理
  --nft-menu             NFT 转发
  --time-menu            时间与时区
  --https-time-sync      立即执行 HTTPS 时间同步
  --swap-menu            Swap 管理
  --system-toolbox-menu  安全与诊断
  --stun-test            STUN / UDP / NAT 检测
  --hostname-menu        修改系统 hostname
  --docker-menu          Docker 管理
  --software-menu        软件与重装
  --self-manage-menu     脚本管理
  --monitor-home         监控告警中心
  --monitor-config       监控告警配置
  --config-backup-menu   配置备份
  --config-transfer-menu 配置迁移
  --rollback-center-menu 回滚中心
  --nft-refresh-ddns     NFT DDNS 刷新内部入口
  --monitor-alert        监控告警内部入口
EOF
}

main_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(ssh_key_count)
        local F2B_STAT; F2B_STAT=$(f2b_status)

        safe_clear
        echo ""
        volcano_art_banner
        echo ""
        box_top
        app_header_line
        app_subtitle_line
        echo -e "  ${DIM}SSH · BBR · DDNS · Caddy · Firewall · NFT · Monitor${NC}"
        box_sep
        # 收集状态数据
        local FW_TYPE FW_STAT FW_STATE
        FW_TYPE=$(fw_detect)
        if [ "$FW_TYPE" = "none" ]; then
            FW_STAT="未安装"; FW_STATE="unknown"
        elif [ "$(fw_running "$FW_TYPE")" = "active" ]; then
            FW_STAT="${FW_TYPE} 运行中"; FW_STATE="active"
        else
            FW_STAT="${FW_TYPE} 已停止"; FW_STATE="inactive"
        fi
        local BBR_CC; BBR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved >/dev/null 2>&1 || true
        local TC_RATE TC_DEV TC_BIN
        TC_DEV=$(default_iface)
        TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
        TC_RATE=$(bbr_tc_rate_display "$TC_DEV" "$TC_BIN")
        [ "$TC_RATE" = "未设置" ] && TC_RATE="无限速"
        local CADDY_ST; CADDY_ST=$(caddy_status)
        local CADDY_LABEL
        case "$CADDY_ST" in
            running)       CADDY_LABEL="运行中" ;;
            stopped)       CADDY_LABEL="已停止" ;;
            not_installed) CADDY_LABEL="未安装" ;;
        esac
        local DDNS_ST; DDNS_ST=$(ddns_status)
        local DDNS_LABEL DOCKER_ST DOCKER_LABEL DOCKER_STATE
        case "$DDNS_ST" in
            running)       DDNS_LABEL="运行中" ;;
            stopped)       DDNS_LABEL="已停止" ;;
            not_installed) DDNS_LABEL="未安装" ;;
        esac
        DOCKER_ST=$(docker_status)
        case "$DOCKER_ST" in
            running) DOCKER_LABEL="运行中"; DOCKER_STATE="active" ;;
            stopped) DOCKER_LABEL="已停止"; DOCKER_STATE="inactive" ;;
            *) DOCKER_LABEL="未安装"; DOCKER_STATE="unknown" ;;
        esac
        local SYS_TIME SYS_TZ
        SYS_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        SYS_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || date '+%Z')

        # 状态仪表盘
        local AUTH_LABEL AUTH_STATE CADDY_STATE DDNS_STATE BBR_STATE F2B_LABEL F2B_STATE
        if [ "$CUR_PWD" = "no" ] && [ "$CUR_PUBKEY" = "yes" ]; then AUTH_LABEL="仅密钥"; AUTH_STATE="active"
        elif [ "$CUR_PWD" = "yes" ]; then AUTH_LABEL="允许密码"; AUTH_STATE="warning"
        else AUTH_LABEL="未确认"; AUTH_STATE="unknown"; fi
        [ "$CADDY_ST" = "running" ] && CADDY_STATE="active" || CADDY_STATE="$CADDY_ST"
        [ "$DDNS_ST" = "running" ] && DDNS_STATE="active" || DDNS_STATE="$DDNS_ST"
        [ "$BBR_CC" = "bbr" ] && BBR_STATE="active" || BBR_STATE="unknown"
        case "$F2B_STAT" in
            running) F2B_LABEL="运行中"; F2B_STATE="active" ;;
            stopped) F2B_LABEL="已停止"; F2B_STATE="inactive" ;;
            *) F2B_LABEL="未安装"; F2B_STATE="unknown" ;;
        esac

        menu_group "系统概览"
        status_pair "SSH" "${CUR_PORT:-22} · ${KEYCOUNT} 公钥" "active" "认证" "$AUTH_LABEL" "$AUTH_STATE"
        status_pair "BBR" "$BBR_CC · $TC_RATE" "$BBR_STATE" "Fail2ban" "$F2B_LABEL" "$F2B_STATE"
        status_pair "防火墙" "$FW_STAT" "$FW_STATE" "Caddy" "$CADDY_LABEL" "$CADDY_STATE"
        status_pair "DDNS" "$DDNS_LABEL" "$DDNS_STATE" "Docker" "$DOCKER_LABEL" "$DOCKER_STATE"
        status_pair "时间" "$SYS_TIME" "active"
        ui_hint "时区 $SYS_TZ"
        # 更新提示
        if [ -f /tmp/.vps_new_version ]; then
            local NEW_VER; NEW_VER=$(cat /tmp/.vps_new_version 2>/dev/null)
            [ -n "$NEW_VER" ] && echo -e "  ${YELLOW}${BOLD}! 新版本 ${NEW_VER} 可用${NC}  ${DIM}输入 m 后选择 2 更新${NC}"
        fi
        box_sep
        menu_group "安全与网络"
        menu_pair "1" "SSH 工具集" "2" "Fail2ban 管理"
        menu_pair "3" "BBR TCP 调优" "4" "防火墙管理"
        menu_pair "5" "DNS 优化" "6" "DDNS"
        echo ""
        menu_group "系统与服务"
        menu_pair "7" "系统换源" "8" "IPv4 / IPv6"
        menu_pair "9" "Caddy 管理" "n" "NFT 转发"
        menu_pair "t" "时间与时区" "s" "Swap 管理"
        menu_pair "h" "安全与诊断" "a" "软件与重装"
        menu_pair "d" "Docker 管理" "m" "脚本管理"
        menu_pair "g" "监控告警中心" "" "" "$CYAN" "$CYAN"
        echo ""
        menu_item "0" "退出脚本" "$RED"
        box_bot
        echo ""
        read -rp "$(ui_prompt '选择功能 [0-9 / n / t / s / h / a / d / m / g]: ')" CHOICE
        audit_action "主菜单选择 $CHOICE" INFO

        case "$CHOICE" in
            1) ssh_tools_menu ;;
            2) fail2ban_menu ;;
            3) bbr_menu ;;
            4) firewall_menu ;;
            5) dns_menu ;;
            6) ddns_menu ;;
            7) mirror_menu ;;
            8) ip_config_menu ;;
            9) caddy_menu ;;
            n|N) nft_menu ;;
            t|T) timesync_menu ;;
            s|S) swap_menu ;;
            h|H) system_toolbox_menu ;;
            a|A) software_reinstall_menu ;;
            d|D) docker_menu ;;
            m|M) self_manage_menu ;;
            g|G) monitor_alert_home_menu ;;
            0) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项，请重新输入。"; sleep 1 ;;
        esac
        continue
    done
}

# 测试模式只加载函数，不启动菜单或后台任务。
if [ "${VPS_TOOLS_TEST_MODE:-0}" = "1" ]; then
    # shellcheck disable=SC2317 # exit fallback is used when the script is executed instead of sourced
    return 0 2>/dev/null || exit 0
fi

# CLI 处理：systemd timer 调用 DDNS 刷新（非交互）
case "${1:-}" in
    --help|-h|help)
        show_cli_help
        exit 0
        ;;
    --ssh-menu)
        ssh_tools_menu
        exit $?
        ;;
    --fail2ban-menu)
        fail2ban_menu
        exit $?
        ;;
    --bbr-menu)
        bbr_menu
        exit $?
        ;;
    --bbr-reconcile-tc)
        bbr_tc_reconcile_saved
        exit $?
        ;;
    --firewall-menu)
        firewall_menu
        exit $?
        ;;
    --dns-menu)
        dns_menu
        exit $?
        ;;
    --nft-refresh-ddns)
        nft_refresh_ddns
        exit $?
        ;;
    --monitor-alert)
        monitor_alert_check
        exit $?
        ;;
    --ddns-menu)
        ddns_menu
        exit $?
        ;;
    --ddns-install)
        ddns_install
        exit $?
        ;;
    --ddns-run)
        ddns_run_now
        exit $?
        ;;
    --ddns-status)
        ddns_status
        exit $?
        ;;
    --ddns-log)
        ddns_view_logs
        exit $?
        ;;
    --ddns-link)
        ddns_share_link_tool
        exit $?
        ;;
    --mirror-menu)
        mirror_menu
        exit $?
        ;;
    --ip-menu)
        ip_config_menu
        exit $?
        ;;
    --caddy-menu)
        caddy_menu
        exit $?
        ;;
    --nft-menu)
        nft_menu
        exit $?
        ;;
    --time-menu)
        timesync_menu
        exit $?
        ;;
    --https-time-sync)
        ts_sync_https
        exit $?
        ;;
    --https-time-sync-run)
        ts_https_scheduled_run
        exit $?
        ;;
    --swap-menu)
        swap_menu
        exit $?
        ;;
    --system-toolbox-menu)
        system_toolbox_menu
        exit $?
        ;;
    --stun-test)
        stun_nat_quick
        exit $?
        ;;
    --hostname-menu)
        system_hostname_apply
        exit $?
        ;;
    --docker-menu)
        docker_menu
        exit $?
        ;;
    --software-menu)
        software_reinstall_menu
        exit $?
        ;;
    --self-manage-menu)
        self_manage_menu
        exit $?
        ;;
    --monitor-home)
        monitor_alert_home_menu
        exit $?
        ;;
    --monitor-config)
        monitor_alert_config_menu
        exit $?
        ;;
    --config-backup-menu)
        config_backup_menu
        exit $?
        ;;
    --config-transfer-menu)
        config_transfer_menu
        exit $?
        ;;
    --rollback-center-menu)
        rollback_center_menu
        exit $?
        ;;
esac

self_check_first_run
# 后台检测新版本（不阻塞主菜单）
self_check_update &
main_menu
