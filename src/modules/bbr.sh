# ══════════════════════════════════════════════════════════
#  BBR TCP 调优模块
# ══════════════════════════════════════════════════════════

SERVICE_TC="/etc/systemd/system/tc-fq.service"
SERVICE_TC_INIT="/etc/init.d/tc-fq"
TC_HELPER="/usr/local/libexec/vps-tools-tc-fq"
TC_STATE_FILE="/var/lib/vps-tools/tc-fq.state"
TC_BACKUP_DIR="/var/lib/vps-tools/tc-backups"
SERVICE_CWND="/etc/systemd/system/initcwnd.service"
SERVICE_CWND_INIT="/etc/init.d/initcwnd"
CWND_HELPER="/usr/local/libexec/vps-tools-initcwnd"
CWND_STATE_FILE="/var/lib/vps-tools/initcwnd.state"
SYSCTL_FILE="/etc/sysctl.d/99-vps-bbr.conf"
BBR_BASELINE_FILE="/var/lib/vps-tools/bbr-sysctl-baseline.conf"
BBR_PROC_SYS="/proc/sys"
BBR_PROC_NET="/proc/net"
BBR_SYSCTL_DIRS="/etc/sysctl.d:/run/sysctl.d:/usr/local/lib/sysctl.d:/usr/lib/sysctl.d:/lib/sysctl.d"
BBR_SYSCTL_MAIN="/etc/sysctl.conf"

bbr_default_ipv6_iface() {
    local DEV
    DEV=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    [ -n "$DEV" ] || DEV=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || DEV=""
    printf '%s\n' "$DEV"
}

bbr_scene_keys() {
    local IPV6_IFACE
    IPV6_IFACE=$(bbr_default_ipv6_iface)
    IPV6_IFACE=$(printf '%s' "$IPV6_IFACE" | tr '.' '/')
    printf '%s\n' \
        net.ipv4.ip_forward \
        net.ipv6.conf.all.forwarding \
        net.core.somaxconn \
        net.core.netdev_max_backlog \
        net.ipv4.tcp_max_syn_backlog \
        net.netfilter.nf_conntrack_max \
        net.netfilter.nf_conntrack_tcp_timeout_established \
        net.netfilter.nf_conntrack_tcp_timeout_time_wait \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_max_tw_buckets \
        net.ipv6.conf.default.accept_ra \
        fs.file-max
    if [ -n "$IPV6_IFACE" ]; then printf 'net.ipv6.conf.%s.accept_ra\n' "$IPV6_IFACE"; fi
}

bbr_retired_keys() {
    printf '%s\n' \
        vm.min_free_kbytes \
        net.ipv4.tcp_mem \
        net.ipv4.tcp_adv_win_scale \
        net.ipv4.tcp_fastopen_blackhole_timeout_sec \
        net.ipv4.tcp_ecn \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_tw_reuse \
        net.ipv4.tcp_fin_timeout \
        net.ipv4.tcp_keepalive_time
}

bbr_managed_keys() {
    printf '%s\n' \
        vm.swappiness \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_mtu_probing \
        net.ipv4.tcp_ecn \
        net.ipv4.tcp_ecn_fallback \
        net.ipv4.udp_rmem_min \
        net.ipv4.udp_wmem_min
    bbr_scene_keys
}

bbr_runtime_snapshot() {
    local DEST="$1" EXTRA_CONFIG="${2:-}" SCOPE="${3:-all}" DIR TMP KEY VALUE CAPTURED=0
    DIR=$(dirname "$DEST")
    mkdir -p "$DIR" 2>/dev/null || return 1
    TMP=$(mktemp "${DEST}.tmp.XXXXXX") || return 1
    {
        echo "# VPS TOOLS BBR sysctl runtime snapshot"
        echo "# captured: $(date '+%Y-%m-%d %H:%M:%S')"
        while IFS= read -r KEY; do
            [ -n "$KEY" ] || continue
            # 旧安装已管理但未留下基线的键，不能把当前调优值冒充原值。
            if [ "$SCOPE" = baseline ] && [ -f "$SYSCTL_FILE" ] && bbr_config_has_key "$(cat "$SYSCTL_FILE")" "$KEY"; then
                continue
            fi
            if VALUE=$(sysctl -n "$KEY" 2>/dev/null); then
                printf '%s = %s\n' "$KEY" "$VALUE"
                CAPTURED=$(( CAPTURED + 1 ))
            fi
        done < <({ [ "$SCOPE" = config ] || bbr_managed_keys; bbr_config_keys "$EXTRA_CONFIG"; } | awk '!seen[$0]++')
    } > "$TMP"
    if [ "$CAPTURED" -eq 0 ] && [ "$SCOPE" != baseline ]; then
        rm -f "$TMP"
        return 1
    fi
    chmod 600 "$TMP" 2>/dev/null || true
    mv "$TMP" "$DEST" || { rm -f "$TMP"; return 1; }
}

bbr_ensure_baseline() {
    if [ ! -s "$BBR_BASELINE_FILE" ]; then
        bbr_runtime_snapshot "$BBR_BASELINE_FILE" "" baseline || {
            error "无法保存 BBR 应用前运行参数基线"
            return 1
        }
        return 0
    fi

    local TMP KEY VALUE ADDED=0
    TMP=$(mktemp "${BBR_BASELINE_FILE}.tmp.XXXXXX") || return 1
    cp "$BBR_BASELINE_FILE" "$TMP" || { rm -f "$TMP"; return 1; }
    while IFS= read -r KEY; do
        [ -n "$KEY" ] || continue
        if ! bbr_baseline_value "$KEY" >/dev/null 2>&1 && VALUE=$(sysctl -n "$KEY" 2>/dev/null); then
            if [ -f "$SYSCTL_FILE" ] && bbr_config_has_key "$(cat "$SYSCTL_FILE")" "$KEY"; then
                continue
            fi
            printf '%s = %s\n' "$KEY" "$VALUE" >> "$TMP"
            ADDED=$(( ADDED + 1 ))
        fi
    done < <(bbr_managed_keys)
    if [ "$ADDED" -eq 0 ]; then
        rm -f "$TMP"
        return 0
    fi
    chmod 600 "$TMP" && mv "$TMP" "$BBR_BASELINE_FILE" || {
        rm -f "$TMP"
        error "无法保存 BBR 应用前运行参数基线"
        return 1
    }
}

bbr_baseline_value() {
    local KEY="$1"
    [ -f "$BBR_BASELINE_FILE" ] || return 1
    awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            print
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$BBR_BASELINE_FILE"
}

bbr_restore_baseline_key() {
    local KEY="$1" VALUE
    VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null || true)
    [ -n "$VALUE" ] || { warn "基线中没有 ${KEY}，保持当前运行值"; return 1; }
    sysctl -w "${KEY}=${VALUE}" >/dev/null 2>&1 || {
        warn "无法恢复基线参数：${KEY}"
        return 1
    }
}

bbr_restore_runtime_snapshot() {
    local SNAPSHOT="$1" KEY VALUE FAILED=0 CONFIG GUARD_FAILED=0
    [ -f "$SNAPSHOT" ] || return 1
    CONFIG=$(cat "$SNAPSHOT")
    # 恢复混合的接口转发值时，任何接口 forwarding=1 都可能清理整个
    # namespace 的 RA 路由。临时保护原来接受 RA 的接口，最后再恢复原值。
    if printf '%s\n' "$CONFIG" | grep -qE '^net\.ipv6\.conf\.[^ ]+\.forwarding[[:space:]]*=[[:space:]]*1[[:space:]]*$'; then
        while IFS='=' read -r KEY VALUE; do
            KEY=$(printf '%s' "$KEY" | bbr_sysctl_normalize)
            VALUE=$(printf '%s' "$VALUE" | bbr_sysctl_normalize)
            case "$KEY:$VALUE" in
                net.ipv6.conf.*.accept_ra:1)
                    bbr_sysctl_write_verified "$KEY" 2 || GUARD_FAILED=1 ;;
            esac
        done <<< "$CONFIG"
    fi
    while IFS='=' read -r KEY VALUE; do
        KEY=$(printf '%s' "$KEY" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        VALUE=$(printf '%s' "$VALUE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$KEY" in ""|\#*) continue ;; esac
        if [ "$GUARD_FAILED" = 1 ]; then
            case "$KEY:$VALUE" in net.ipv6.conf.*.forwarding:1) FAILED=1; continue ;; esac
        fi
        bbr_sysctl_write_verified "$KEY" "$VALUE" || FAILED=1
    done < <(bbr_runtime_plan "$CONFIG")
    bbr_verify_runtime "$CONFIG" || FAILED=1
    return "$FAILED"
}

# IPv6 accept_ra=2 必须先于转发；全局转发先于 default/接口转发；
# accept_ra=0/1 和其他被连带修改的值最后恢复。持久化使用相同顺序。
bbr_runtime_plan() {
    printf '%s\n' "$1" | awk -F= -v keep="${2:-runtime}" '
        function rank(key) {
            if(key ~ /^net\.ipv6\.conf\..+\.accept_ra$/ && values[key]+0 == 2) return 0
            if(key ~ /^(net\.ipv4\.ip_forward|net\.ipv[46]\.conf\.all\.forwarding)$/) return 1
            if(key ~ /^net\.ipv[46]\.conf\.default\.forwarding$/) return 2
            if(key ~ /^net\.ipv[46]\.conf\..+\.forwarding$/) return 3
            return 4
        }
        {raw[NR]=$0}
        /^[[:space:]]*[#;]/ || !/=/ {next}
        {key=$1; gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
         if(!first) first=NR
         keys[NR]=key; last[key]=NR
         if(!(key in values)) order[++n]=key
         value=$0; sub(/^[^=]*=/, "", value); values[key]=value}
        END {
            if(keep == "config") {
                if(!first) first=NR+1
                for(i=1;i<first;i++) print raw[i]
                for(p=0;p<=4;p++) for(i=first;i<=NR;i++) {
                    if(keys[i] != "") {
                        if(last[keys[i]]==i && rank(keys[i])==p) print raw[i]
                    } else if(p==4) print raw[i]
                }
            } else {
                for(p=0;p<=4;p++) for(i=1;i<=n;i++)
                    if(rank(order[i])==p) print order[i] " = " values[order[i]]
            }
        }
    '
}

bbr_verify_runtime() {
    local CONFIG="$1" KEY VALUE ACTUAL FAILED=0
    while IFS='=' read -r KEY VALUE; do
        KEY=$(printf '%s' "$KEY" | bbr_sysctl_normalize)
        VALUE=$(printf '%s' "$VALUE" | bbr_sysctl_normalize)
        [ -n "$KEY" ] || continue
        if ! ACTUAL=$(sysctl -n "$KEY" 2>/dev/null); then
            error "最终状态不可读：${KEY}"
            FAILED=1
        elif [ "$(printf '%s\n' "$ACTUAL" | bbr_sysctl_normalize)" != "$VALUE" ]; then
            error "最终状态不一致：${KEY}（可能被其他参数重置）"
            FAILED=1
        fi
    done < <(bbr_runtime_plan "$CONFIG")
    return "$FAILED"
}

# 只扩展有全局转发副作用的事务，不让独立 TCP 开关触碰其他运行参数。
# 用 proc 路径枚举接口，再按 procps 规则转回键，兼容 eth0.100 等名字。
bbr_forwarding_affected_keys() {
    local CONFIG="$1" PATHNAME IPV4=0 IPV6=0 KEY
    while IFS= read -r KEY; do
        case "$KEY" in
            net.ipv4.ip_forward|net.ipv4.conf.all.forwarding) IPV4=1 ;;
            net.ipv6.conf.*.forwarding) IPV6=1 ;;
        esac
    done < <(bbr_config_keys "$CONFIG")
    if [ "$IPV4" = 1 ]; then
        for PATHNAME in "$BBR_PROC_SYS"/net/ipv4/conf/*/forwarding "$BBR_PROC_SYS"/net/ipv4/conf/all/accept_redirects; do
            [ -f "$PATHNAME" ] || continue
            # ip_forward 与 conf/all/forwarding 是同一内核值，避免重复管理别名。
            [ "$PATHNAME" != "$BBR_PROC_SYS/net/ipv4/conf/all/forwarding" ] || continue
            printf '%s\n' "${PATHNAME#"$BBR_PROC_SYS"/}" | tr '/.' './'
        done
    fi
    if [ "$IPV6" = 1 ]; then
        for PATHNAME in "$BBR_PROC_SYS"/net/ipv6/conf/*/forwarding "$BBR_PROC_SYS"/net/ipv6/conf/*/force_forwarding "$BBR_PROC_SYS"/net/ipv6/conf/*/accept_ra; do
            [ -f "$PATHNAME" ] || continue
            printf '%s\n' "${PATHNAME#"$BBR_PROC_SYS"/}" | tr '/.' './'
        done
    fi
}

bbr_ensure_flock() {
    command -v flock >/dev/null 2>&1 && return 0
    warn "BBR 安全事务需要 flock，正在安装 util-linux..."
    pkg_install util-linux || true
    command -v flock >/dev/null 2>&1 && return 0
    error "缺少 flock，已取消应用；请安装发行版的 util-linux/flock 包后重试"
    return 1
}

bbr_config_has_key() {
    local CONFIG="$1" KEY="$2"
    printf '%s\n' "$CONFIG" | awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs == key) found=1
        }
        END { exit !found }
    '
}

bbr_config_value() {
    local CONFIG="$1" KEY="$2"
    printf '%s\n' "$CONFIG" | awk -F= -v key="$KEY" '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
        }
        lhs == key {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            value=$0
            found=1
        }
        END { if (!found) exit 1; print value }
    '
}

bbr_config_keys() {
    printf '%s\n' "$1" | awk -F= '
        {
            lhs=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", lhs)
            if (lhs ~ /^[[:alnum:]_.\/-]+$/) print lhs
        }
    '
}

bbr_config_dynamic_scene_keys() {
    bbr_config_keys "$1" | awk '/^net\.ipv6\.conf\..+\.accept_ra$/ { print }'
}

# sysctl 的点号/斜杠语义与 procps 一致（接口名中的点以斜杠表示）。
bbr_sysctl_path() {
    local KEY="$1"
    case "$KEY" in
        *.*) case "${KEY%%.*}" in */*) ;; *) KEY=$(printf '%s' "$KEY" | tr './' '/.') ;; esac ;;
    esac
    printf '%s/%s\n' "$BBR_PROC_SYS" "$KEY"
}

bbr_sysctl_normalize() {
    awk '{$1=$1; print}'
}

bbr_sysctl_write_verified() {
    local KEY="$1" VALUE="$2" ACTUAL DETAIL PATHNAME
    PATHNAME=$(bbr_sysctl_path "$KEY")
    if [ ! -w "$PATHNAME" ]; then
        error "参数无写入权限或只读：${KEY}"
        return 1
    fi
    # IPv6 即使重复写入 forwarding=1 也可能清掉 RA 路由，避免无意义重写。
    case "$KEY" in
        net.ipv6.conf.*.forwarding)
            ACTUAL=$(sysctl -n "$KEY" 2>/dev/null) || return 1
            [ "$(printf '%s\n' "$ACTUAL" | bbr_sysctl_normalize)" != "$VALUE" ] || return 0 ;;
    esac
    if ! DETAIL=$(LC_ALL=C sysctl -w "${KEY}=${VALUE}" 2>&1); then
        case "$DETAIL" in
            *'permission denied'*|*'Permission denied'*|*'Operation not permitted'*|*'Read-only file system'*)
                error "参数无写入权限或只读：${KEY}" ;;
            *) error "参数写入失败：${KEY} (${DETAIL})" ;;
        esac
        return 1
    fi
    if ! ACTUAL=$(sysctl -n "$KEY" 2>/dev/null); then
        error "参数写入后无法回读：${KEY}"
        return 1
    fi
    if [ "$(printf '%s\n' "$ACTUAL" | bbr_sysctl_normalize)" != "$(printf '%s\n' "$VALUE" | bbr_sysctl_normalize)" ]; then
        error "参数回读不一致：${KEY}，期望 ${VALUE}，实际 ${ACTUAL}"
        return 1
    fi
}

bbr_tcp_keys() {
    case "$1" in
        TFO) echo net.ipv4.tcp_fastopen ;;
        MTU) echo net.ipv4.tcp_mtu_probing ;;
        ECN) printf '%s\n' net.ipv4.tcp_ecn net.ipv4.tcp_ecn_fallback ;;
        *) return 1 ;;
    esac
}

# 偏好与 sysctl 原子保存于同一文件；system 标记阻止预设重新接管。
bbr_tcp_config() {
    local CURRENT="${1:-}" GROUP KEY VALUE
    if [ "$#" -eq 0 ] && [ -f "$SYSCTL_FILE" ]; then CURRENT=$(cat "$SYSCTL_FILE"); fi
    for GROUP in TFO MTU ECN; do
        if printf '%s\n' "$CURRENT" | grep -qx "# VPS_TOOLS_TCP_${GROUP}=system"; then
            echo "# VPS_TOOLS_TCP_${GROUP}=system"
            continue
        fi
        if [ "$GROUP" = ECN ] && ! printf '%s\n' "$CURRENT" | grep -qx '# VPS_TOOLS_TCP_ECN=managed'; then
            echo '# VPS_TOOLS_TCP_ECN=system'
            continue
        fi
        echo "# VPS_TOOLS_TCP_${GROUP}=managed"
        for KEY in $(bbr_tcp_keys "$GROUP"); do
            VALUE=$(bbr_config_value "$CURRENT" "$KEY" 2>/dev/null || true)
            if [ -z "$VALUE" ]; then
                case "$GROUP" in TFO) VALUE=3 ;; MTU) VALUE=1 ;; ECN) continue ;; esac
            fi
            printf '%s = %s\n' "$KEY" "$VALUE"
        done
    done
}

bbr_tcp_without_group() {
    local CONFIG="$1" GROUP="$2" KEYS
    KEYS=$(bbr_tcp_keys "$GROUP") || return 1
    printf '%s\n' "$CONFIG" | awk -v keys="${KEYS//$'\n'/,}" -v group="$GROUP" '
        BEGIN { n=split(keys, a, ","); for(i=1;i<=n;i++) drop[a[i]]=1 }
        $0 ~ "^# VPS_TOOLS_TCP_" group "=" {next}
        { key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key) }
        !(key in drop) { print }
    '
}

bbr_tcp_set() {
    local GROUP="$1" MODE="$2" CONFIG="" ORIGINAL_CONFIG RESTORE="" KEYS KEY VALUE
    KEYS=$(bbr_tcp_keys "$GROUP") || return 1
    case "$MODE" in on|off|system) ;; *) return 1 ;; esac
    [ ! -f "$SYSCTL_FILE" ] || CONFIG=$(cat "$SYSCTL_FILE")
    ORIGINAL_CONFIG="$CONFIG"
    # 恢复时缺少已管理键的基线必须停止，不能猜测内核默认值。
    if [ "$MODE" = system ]; then
        for KEY in $KEYS; do
            if bbr_config_has_key "$CONFIG" "$KEY"; then
                VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null) || {
                    error "缺少 ${KEY} 的首次基线，无法恢复原值"
                    return 1
                }
                RESTORE="${RESTORE}${KEY} = ${VALUE}"$'\n'
            fi
        done
    fi
    CONFIG=$(bbr_tcp_without_group "$CONFIG" "$GROUP") || return 1
    if [ "$MODE" = system ]; then
        CONFIG="${CONFIG}"$'\n'"# VPS_TOOLS_TCP_${GROUP}=system"
    else
        CONFIG="${CONFIG}"$'\n'"# VPS_TOOLS_TCP_${GROUP}=managed"
        for KEY in $KEYS; do
            VALUE=0
            if [ "$MODE" = on ]; then
                case "$GROUP" in TFO) VALUE=3 ;; *) VALUE=1 ;; esac
            fi
            [ "$KEY" != net.ipv4.tcp_ecn_fallback ] || VALUE=1
            CONFIG="${CONFIG}"$'\n'"${KEY} = ${VALUE}"
        done
    fi
    bbr_apply_sysctl "$CONFIG" preserve "$RESTORE" "$KEYS" "$KEYS" "$ORIGINAL_CONFIG"
}

bbr_tcp_status() {
    local GROUP KEY CURRENT SAVED BASE CONFIG=""
    [ ! -f "$SYSCTL_FILE" ] || CONFIG=$(cat "$SYSCTL_FILE")
    for GROUP in TFO ECN MTU; do
        for KEY in $(bbr_tcp_keys "$GROUP"); do
            CURRENT=$(sysctl -n "$KEY" 2>/dev/null || echo 不支持或不可读)
            SAVED=$(bbr_config_value "$CONFIG" "$KEY" 2>/dev/null || echo 跟随系统)
            BASE=$(bbr_baseline_value "$KEY" 2>/dev/null || echo 未记录)
            printf '  %s\n    当前: %s · 已保存: %s · 首次基线: %s\n' "$KEY" "$CURRENT" "$SAVED" "$BASE"
        done
    done
}

bbr_tcp_menu() {
    local CH ACTION GROUP MODE
    while true; do
        print_header "TCP 增强"
        bbr_tcp_status
        echo ""
        echo "  TFO 需要应用配合；MTU=1 在检测到黑洞后启动探测。"
        echo "  ECN 效果取决于内核、对端和链路；启用时同时开启 fallback。"
        echo "  恢复原值会退出本工具管理，后续预设仍保留此选择。"
        menu_item "1" "TCP Fast Open"
        menu_item "2" "ECN + fallback"
        menu_item "3" "MTU 黑洞探测"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        read -rp "$(ui_prompt '选择 [0-3]: ')" CH || return 0
        case "$CH" in
            1) GROUP=TFO ;; 2) GROUP=ECN ;; 3) GROUP=MTU ;;
            0) return ;; 00) exit 0 ;; *) continue ;;
        esac
        menu_item "1" "启用"
        menu_item "2" "关闭"
        menu_item "3" "恢复首次基线并退出管理"
        menu_item "0" "取消"
        read -rp "$(ui_prompt '选择操作 [0-3]: ')" ACTION || return 0
        case "$ACTION" in 1) MODE=on ;; 2) MODE=off ;; 3) MODE=system ;; *) continue ;; esac
        bbr_tcp_set "$GROUP" "$MODE" || warn "TCP 增强未应用，请查看上方原因"
        ui_pause
    done
}

# ── 状态显示 ──────────────────────────────────────────────
bbr_print_status() {
    local DEV TC_BIN RATE
    DEV=$(default_iface)
    TC_BIN=$(command -v tc 2>/dev/null || true)
    RATE="未设置"
    [ -z "$TC_BIN" ] || RATE=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
    local BBR; BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local CWND
    CWND=$(ip -4 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
    [ -n "$CWND" ] || CWND=$(ip -6 route show default 2>/dev/null | grep -oE 'initcwnd [0-9]+' | head -1 | awk '{print $2}')
    [ -z "$CWND" ] && CWND="10（默认）"

    # 读取缓冲区大小
    local RMEM_MAX WMEM_MAX RMEM_MB WMEM_MB
    RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    WMEM_MAX=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    RMEM_MB=$(( RMEM_MAX / 1048576 ))
    WMEM_MB=$(( WMEM_MAX / 1048576 ))

    # tcp_rmem / tcp_wmem 的 max 字段
    local TCP_RMEM_MAX TCP_WMEM_MAX TCP_RMEM_MB TCP_WMEM_MB
    TCP_RMEM_MAX=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print $3}')
    TCP_WMEM_MAX=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    TCP_RMEM_MB=$(( ${TCP_RMEM_MAX:-0} / 1048576 ))
    TCP_WMEM_MB=$(( ${TCP_WMEM_MAX:-0} / 1048576 ))

    echo -e "  ${CYAN}网卡${NC} ${BOLD}$DEV${NC}  ${CYAN}CC${NC} ${BOLD}$BBR${NC}  ${CYAN}cwnd${NC} ${BOLD}$CWND${NC}  ${CYAN}限速${NC} ${BOLD}$RATE${NC}"
    # 检测缓冲区是否超过物理内存四分之一（显示警告）
    local MEM_TOTAL_MB
    MEM_TOTAL_MB=$(bbr_physical_memory_mb)
    local RMEM_COLOR WMEM_COLOR
    RMEM_COLOR="$BOLD"
    WMEM_COLOR="$BOLD"
    if [ "${MEM_TOTAL_MB:-0}" -gt 0 ]; then
        [ "$RMEM_MB" -gt $(( MEM_TOTAL_MB / 4 )) ] && RMEM_COLOR="${YELLOW}${BOLD}"
        [ "$WMEM_MB" -gt $(( MEM_TOTAL_MB / 4 )) ] && WMEM_COLOR="${YELLOW}${BOLD}"
    fi
    echo -e "  ${CYAN}缓冲${NC} rmem ${RMEM_COLOR}${RMEM_MB}MB${NC}  wmem ${WMEM_COLOR}${WMEM_MB}MB${NC}  tcp_r ${BOLD}${TCP_RMEM_MB}MB${NC}  tcp_w ${BOLD}${TCP_WMEM_MB}MB${NC}  ${DIM}物理内存 ${MEM_TOTAL_MB}MB${NC}"
}

# ── 备份 sysctl ───────────────────────────────────────────
bbr_backup_sysctl() {
    local BAK CURRENT_CONFIG=""
    BAK="${SYSCTL_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    [ -e "$BAK" ] && BAK="${BAK}.$$"
    [ ! -f "$SYSCTL_FILE" ] || CURRENT_CONFIG=$(cat "$SYSCTL_FILE")
    if bbr_runtime_snapshot "$BAK" "$CURRENT_CONFIG" && bbr_tcp_config | awk '/^# VPS_TOOLS_TCP_/' >> "$BAK"; then
        info "已备份当前运行参数至：$BAK"
    else
        error "BBR 运行参数备份失败"
        return 1
    fi
}

# ── 还原 sysctl ───────────────────────────────────────────
bbr_restore_sysctl() {
    print_header "还原 TCP sysctl 配置"

    local LIST_FILE
    LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/vps_bbr_bak.XXXXXX") || { error "无法创建备份列表"; return 1; }
    ls -t "${SYSCTL_FILE}.bak."* 2>/dev/null > "$LIST_FILE"

    if [ ! -s "$LIST_FILE" ]; then
        rm -f "$LIST_FILE"
        warn "未找到任何备份文件"
        return
    fi

    local i=1
    while IFS= read -r f; do
        # stat 兼容：BusyBox stat 用 -c '%y'，但格式有差异，改用 ls -l 更通用
        local FDATE
        FDATE=$(ls -l "$f" 2>/dev/null | awk '{print $6, $7}')
        echo -e "  ${GREEN}[$i]${NC} $(basename "$f")  ${DIM}${FDATE}${NC}"
        i=$(( i + 1 ))
    done < "$LIST_FILE"

    local TOTAL=$(( i - 1 ))
    echo -e "  ${YELLOW}[d]${NC} 清除全部备份"
    echo -e "  ${RED}[0]${NC} 返回"
    echo ""
    read -rp "$(ui_prompt '选择备份编号: ')" CH

    case "$CH" in
        0) rm -f "$LIST_FILE"; return ;;
        00) rm -f "$LIST_FILE"; safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        d|D)
            read -rp "  确认清除全部 ${TOTAL} 个备份？(Y/n，默认Y): " C
            [ -z "$C" ] && C="y"
            if echo "$C" | grep -qiE '^y(es)?$'; then
                rm -f "${SYSCTL_FILE}.bak."*
                info "已清除全部备份 ✓"
            else
                warn "已取消"
            fi
            ;;
        *)
            # 纯数字且在范围内
            if echo "$CH" | grep -qE '^[0-9]+$' && [ "$CH" -ge 1 ] && [ "$CH" -le "$TOTAL" ]; then
                local T CONFIG RESTORE="" GROUP KEY VALUE
                T=$(sed -n "${CH}p" "$LIST_FILE")
                CONFIG=$(cat "$T")
                # 快照恢复运行值，同时保留“跟随系统”的退出管理偏好。
                for GROUP in TFO ECN MTU; do
                    if printf '%s\n' "$CONFIG" | grep -qx "# VPS_TOOLS_TCP_${GROUP}=system"; then
                        for KEY in $(bbr_tcp_keys "$GROUP"); do
                            if VALUE=$(bbr_config_value "$CONFIG" "$KEY" 2>/dev/null); then
                                RESTORE="${RESTORE}${KEY} = ${VALUE}"$'\n'
                            fi
                        done
                        CONFIG=$(bbr_tcp_without_group "$CONFIG" "$GROUP")$'\n'"# VPS_TOOLS_TCP_${GROUP}=system"
                    fi
                done
                if bbr_apply_sysctl "$CONFIG" baseline "$RESTORE"; then
                    info "已还原运行参数：$(basename "$T") ✓"
                else
                    error "还原未完全成功，请查看上方失败参数"
                fi
            else
                error "无效选项"
            fi
            ;;
    esac
    rm -f "$LIST_FILE"
}

# ── 应用 sysctl ───────────────────────────────────────────
bbr_apply_sysctl() (
    local CONFIG="$1" STALE_MODE="${2:-ask}" RESTORE="${3:-}" REQUIRED="${4:-}" APPLY_ONLY="${5:-}"
    local TX_SNAPSHOT="" TMP_FILE="" TX_DIRTY=0 KEY VALUE LINE OLD="" STALE="" ANSWER
    local SKIPPED=0 RUNTIME="" PATHNAME SNAPSHOT_CONFIG FILTERED_RESTORE=""
    ensure_sysctl || return 1
    bbr_ensure_flock || return 1
    mkdir -p "$(dirname "$SYSCTL_FILE")" || return 1
    # 持有固定 inode 的内核锁；不删除锁文件，SIGKILL/重启也不会留下死锁。
    # 旧版目录锁没有所有者信息，不能擅自认定旧进程已经退出。
    local TX_LOCK="${SYSCTL_FILE}.lock"
    if [ -d "$TX_LOCK" ]; then
        error "检测到旧版 BBR 目录锁 ${TX_LOCK}；确认旧版进程已退出后，请手动 rmdir 此空目录再重试"
        return 1
    fi
    exec 9>>"$TX_LOCK" || { error "无法打开 BBR 事务锁：${TX_LOCK}"; return 1; }
    flock -n 9 || { error "另一个 BBR 参数事务正在运行，或当前文件系统不支持 flock（${TX_LOCK}）"; return 1; }
    trap '
        if [ "$TX_DIRTY" = 1 ]; then
            if bbr_restore_runtime_snapshot "$TX_SNAPSHOT"; then
                warn "本次运行参数修改已回滚，原持久化配置保留"
            else
                error "部分运行参数回滚失败，请检查；快照保留于 ${TX_SNAPSHOT}"
                TX_SNAPSHOT=""
            fi
        fi
        [ -z "$TMP_FILE" ] || rm -f "$TMP_FILE"
        [ -z "$TX_SNAPSHOT" ] || rm -f "$TX_SNAPSHOT"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    [ ! -f "$SYSCTL_FILE" ] || OLD=$(cat "$SYSCTL_FILE")
    if [ "$#" -ge 6 ] && [ "$OLD" != "$6" ]; then
        error "配置已被其他操作更新，请重试本次操作"
        return 1
    fi
    bbr_ensure_baseline || return 1

    # 已接管的 ECN 必须成对保持，换预设/内核后也不能只应用一半。
    if printf '%s\n' "$CONFIG" | grep -qx '# VPS_TOOLS_TCP_ECN=managed'; then
        if [ -z "$APPLY_ONLY" ] || printf '%s\n' "$APPLY_ONLY" | grep -qx net.ipv4.tcp_ecn; then
            for KEY in $(bbr_tcp_keys ECN); do
                bbr_config_has_key "$CONFIG" "$KEY" || { error "ECN 配置不完整：缺少 ${KEY}"; return 1; }
            done
            REQUIRED="${REQUIRED}"$'\n'"$(bbr_tcp_keys ECN)"
        fi
    fi

    # 先收集恢复项，暂不修改内核；所有恢复也属于本次事务。
    if [ "$STALE_MODE" != preserve ]; then
        for KEY in $(bbr_retired_keys); do
            if bbr_config_has_key "$OLD" "$KEY" && ! bbr_config_has_key "$CONFIG" "$KEY"; then
                bbr_config_has_key "$RESTORE" "$KEY" && continue
                if VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null); then
                    RESTORE="${RESTORE}${KEY} = ${VALUE}"$'\n'
                else
                    warn "旧参数 ${KEY} 缺少首次基线，保留运行值；新配置不再持久化"
                fi
            fi
        done
        while IFS= read -r KEY; do
            if bbr_config_has_key "$OLD" "$KEY" && ! bbr_config_has_key "$CONFIG" "$KEY"; then
                STALE="${STALE}${KEY}"$'\n'
            fi
        done < <({ bbr_scene_keys; bbr_config_dynamic_scene_keys "$OLD"; } | awk '!seen[$0]++')
        if [ -n "$STALE" ]; then
            warn "新预设不再管理以下场景参数："
            printf '%s' "$STALE"
            printf '%s' "$STALE" | grep -q 'forward' && warn "恢复转发参数可能影响路由/NAT"
            ANSWER=n
            if [ "$STALE_MODE" = baseline ]; then
                ANSWER=y
            else
                read -rp "  恢复这些参数到首次基线？(y/N): " ANSWER || ANSWER=n
            fi
            if printf '%s\n' "$ANSWER" | grep -qiE '^y(es)?$'; then
                for KEY in $STALE; do
                    if VALUE=$(bbr_baseline_value "$KEY" 2>/dev/null); then
                        RESTORE="${RESTORE}${KEY} = ${VALUE}"$'\n'
                    else
                        warn "参数 ${KEY} 缺少首次基线，保留运行值"
                    fi
                done
            fi
        fi
    fi

    # 恢复项也要检测存在性；旧内核参数/已删除接口可退出管理，但权限
    # 错误及用户明确要求的增强参数仍必须失败，不能伪装成“不支持”。
    while IFS='=' read -r KEY VALUE; do
        KEY=$(printf '%s' "$KEY" | bbr_sysctl_normalize)
        VALUE=$(printf '%s' "$VALUE" | bbr_sysctl_normalize)
        [ -n "$KEY" ] || continue
        if [ ! -e "$(bbr_sysctl_path "$KEY")" ]; then
            if printf '%s\n' "$REQUIRED" | grep -Fqx "$KEY"; then
                error "内核不支持所选增强参数：${KEY}"
                return 1
            fi
            warn "旧恢复项已不存在，跳过：${KEY}"
            continue
        fi
        FILTERED_RESTORE="${FILTERED_RESTORE}${KEY} = ${VALUE}"$'\n'
    done < <(bbr_runtime_plan "$RESTORE")
    RESTORE="$FILTERED_RESTORE"

    # 先验证并完成暂存文件，再写入运行参数。
    TMP_FILE=$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX") || { error "无法暂存 sysctl 配置"; return 1; }
    while IFS= read -r LINE; do
        case "$LINE" in
            *[![:space:]]*) ;;
            *) printf '%s\n' "$LINE" >> "$TMP_FILE" || return 1; continue ;;
        esac
        if printf '%s\n' "$LINE" | grep -qE '^[[:space:]]*[#;]'; then
            printf '%s\n' "$LINE" >> "$TMP_FILE" || return 1
            continue
        fi
        KEY=$(printf '%s' "${LINE%%=*}" | bbr_sysctl_normalize)
        VALUE=$(printf '%s' "${LINE#*=}" | bbr_sysctl_normalize)
        if [ "$LINE" = "${LINE#*=}" ] || ! printf '%s\n' "$KEY" | grep -qE '^[[:alnum:]_-]+([./][[:alnum:]_-]+)+$' || [ -z "$VALUE" ]; then
            error "无效的 sysctl 配置行：${LINE}"
            return 1
        fi
        if [ -n "$APPLY_ONLY" ] && ! printf '%s\n' "$APPLY_ONLY" | grep -Fqx "$KEY"; then
            printf '%s\n' "$LINE" >> "$TMP_FILE" || return 1
            continue
        fi
        PATHNAME=$(bbr_sysctl_path "$KEY")
        if [ ! -e "$PATHNAME" ]; then
            case "$KEY" in
                net.core.default_qdisc|net.ipv4.tcp_congestion_control)
                    error "内核不支持核心参数：${KEY}"; return 1 ;;
            esac
            if printf '%s\n' "$REQUIRED" | grep -Fqx "$KEY"; then
                error "内核不支持所选增强参数：${KEY}"
                return 1
            fi
            warn "内核不支持，跳过参数：${KEY}"
            printf '# skipped unsupported: %s\n' "$LINE" >> "$TMP_FILE" || return 1
            SKIPPED=$(( SKIPPED + 1 ))
            continue
        fi
        printf '%s = %s\n' "$KEY" "$VALUE" >> "$TMP_FILE" || return 1
        RUNTIME="${RUNTIME}${KEY} = ${VALUE}"$'\n'
    done <<< "$CONFIG"
    RUNTIME=$(bbr_runtime_plan "${RESTORE}${RUNTIME}")
    CONFIG=$(bbr_runtime_plan "$(cat "$TMP_FILE")" config) || return 1
    printf '%s\n' "$CONFIG" > "$TMP_FILE" || return 1
    chmod 644 "$TMP_FILE" || return 1
    TX_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/vps-bbr-transaction.XXXXXX") || return 1
    SNAPSHOT_CONFIG="$RUNTIME"
    while IFS= read -r KEY; do
        [ -n "$KEY" ] || continue
        SNAPSHOT_CONFIG="${SNAPSHOT_CONFIG}"$'\n'"${KEY} = snapshot-only"
    done < <(bbr_forwarding_affected_keys "$RUNTIME")
    if [ -n "$RUNTIME" ]; then
        bbr_runtime_snapshot "$TX_SNAPSHOT" "$SNAPSHOT_CONFIG" config || { error "无法保存运行快照"; return 1; }
    fi

    # 每个待写参数都必须有可读的旧值，才能保证失败时可恢复。
    while IFS= read -r KEY; do
        [ -n "$KEY" ] || continue
        if ! bbr_config_value "$(cat "$TX_SNAPSHOT")" "$KEY" >/dev/null; then
            error "无法读取 ${KEY} 的旧值，取消事务"
            return 1
        fi
    done < <(bbr_config_keys "$SNAPSHOT_CONFIG" | awk '!seen[$0]++')

    TX_DIRTY=1
    while IFS='=' read -r KEY VALUE; do
        KEY=$(printf '%s' "$KEY" | bbr_sysctl_normalize)
        VALUE=$(printf '%s' "$VALUE" | bbr_sysctl_normalize)
        [ -n "$KEY" ] || continue
        bbr_sysctl_write_verified "$KEY" "$VALUE" || return 1
    done <<< "$RUNTIME"
    bbr_verify_runtime "$RUNTIME" || return 1
    # rename 是提交点；信号不能落在提交与清除回滚标记之间。
    trap '' INT TERM HUP
    if ! mv "$TMP_FILE" "$SYSCTL_FILE"; then
        error "无法保存 ${SYSCTL_FILE}"
        return 1
    fi
    TMP_FILE=""
    TX_DIRTY=0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    flock -u 9
    exec 9>&-
    [ "$SKIPPED" -eq 0 ] || warn "共跳过 ${SKIPPED} 个内核不存在的参数，已注释保存"
    [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved || true
    info "sysctl 配置已验证并保存到 ${SYSCTL_FILE} ✓"
)

# ── 应用 tc 限速 ──────────────────────────────────────────
bbr_tc_qdisc_type() {
    awk 'NR==1 { print $2 }' <<< "$1"
}

bbr_tc_qdisc_handle() {
    awk 'NR==1 { print $3 }' <<< "$1"
}

bbr_tc_root_line() {
    awk '
        $1 == "qdisc" {
            for (i = 4; i <= NF; i++) {
                if ($i == "root") { print; exit }
            }
        }
    ' <<< "$1"
}

bbr_tc_qdisc_safe_to_replace() {
    case "$1" in
        ""|mq|fq|fq_codel|noqueue|pfifo_fast) return 0 ;;
        *) return 1 ;;
    esac
}

bbr_tc_current_rate() {
    local DEV="$1" TC_BIN="$2" RATE
    RATE=$("$TC_BIN" class show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null | grep -oE 'rate [^ ]+' | head -1 | awk '{print $2}')
    [ -z "$RATE" ] && RATE=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null | grep -oE 'maxrate [^ ]+' | head -1 | awk '{print $2}')
    printf '%s\n' "$RATE"
}

bbr_tc_owned_rate() {
    local DEV="$1" TC_BIN="$2" RATE QDISCS CLASSES
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    RATE=$(printf '%s\n' "$CLASSES" | awk '
        $1 == "class" && $2 == "htb" && $3 == "1:10" {
            for (i = 1; i < NF; i++) if ($i == "rate") { print $(i + 1); exit }
        }
    ')
    if [ -z "$RATE" ]; then
        QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
        RATE=$(printf '%s\n' "$QDISCS" | awk '
            $1 == "qdisc" && $2 == "fq" && $3 == "100:" {
                for (i = 1; i < NF; i++) if ($i == "maxrate") { print $(i + 1); exit }
            }
        ')
    fi
    printf '%s\n' "$RATE"
}

bbr_tc_saved_values() {
    local DEV RATE BURST_KB FORCE
    DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    RATE=$(bbr_state_value "$TC_STATE_FILE" RATE 2>/dev/null || true)
    BURST_KB=$(bbr_state_value "$TC_STATE_FILE" BURST_KB 2>/dev/null || true)
    FORCE=$(bbr_state_value "$TC_STATE_FILE" FORCE 2>/dev/null || true)
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    echo "$RATE" | grep -qE '^[0-9]+$' || return 1
    echo "$BURST_KB" | grep -qE '^[0-9]+$' || return 1
    [ "$RATE" -gt 0 ] && [ "$BURST_KB" -gt 0 ] || return 1
    case "$FORCE" in 0|1) : ;; *) FORCE=0 ;; esac
    printf '%s %s %s %s\n' "$DEV" "$RATE" "$BURST_KB" "$FORCE"
}

bbr_tc_saved_rate_display() {
    local CURRENT_DEV="$1" SAVED_VALUES SAVED_DEV SAVED_RATE
    SAVED_VALUES=$(bbr_tc_saved_values) || return 1
    SAVED_DEV=${SAVED_VALUES%% *}
    SAVED_RATE=${SAVED_VALUES#* }
    SAVED_RATE=${SAVED_RATE%% *}
    if [ "$SAVED_DEV" = "$CURRENT_DEV" ]; then
        printf '%sMbit（已保存，未生效）\n' "$SAVED_RATE"
    else
        printf '%sMbit（保存于 %s，当前未生效）\n' "$SAVED_RATE" "$SAVED_DEV"
    fi
}

bbr_tc_rate_display() {
    local DEV="$1" TC_BIN="$2" RATE QDISCS LINE TYPE SAVED_RATE
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        RATE=$(bbr_tc_owned_rate "$DEV" "$TC_BIN")
        if [ -n "$RATE" ]; then
            printf '%s\n' "$RATE"
        else
            SAVED_RATE=$(bbr_tc_saved_rate_display "$DEV" 2>/dev/null || true)
            if [ -n "$SAVED_RATE" ]; then
                SAVED_RATE=${SAVED_RATE%%（*}
                printf '%s（已生效，速率读取异常）\n' "$SAVED_RATE"
            else
                printf '已生效（速率读取异常）\n'
            fi
        fi
        return
    fi
    RATE=$(bbr_tc_current_rate "$DEV" "$TC_BIN")
    if [ -z "$RATE" ]; then
        SAVED_RATE=$(bbr_tc_saved_rate_display "$DEV" 2>/dev/null || true)
        [ -z "$SAVED_RATE" ] && echo "未设置" || echo "$SAVED_RATE"
        return
    fi
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$LINE")
    if ! bbr_tc_is_owned "$DEV" "$TC_BIN" \
        && ! bbr_tc_is_legacy_owned "$DEV" "$TC_BIN" \
        && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        printf '%s（外部 %s）\n' "$RATE" "${TYPE:-未知}"
    else
        printf '%s\n' "$RATE"
    fi
}

bbr_tc_snapshot_foreign() {
    local DEV="$1" TC_BIN="$2" TMP SNAPSHOT STAMP
    echo "$DEV" | grep -qE '^[[:alnum:]_.-]{1,15}$' || return 1
    mkdir -p "$TC_BACKUP_DIR" 2>/dev/null || return 1
    chmod 700 "$TC_BACKUP_DIR" 2>/dev/null || true
    STAMP=$(date '+%Y%m%d_%H%M%S')
    SNAPSHOT="$TC_BACKUP_DIR/${DEV}_${STAMP}_$$.txt"
    TMP="${SNAPSHOT}.tmp"
    {
        printf 'VPS TOOLS foreign tc snapshot\n'
        printf 'Captured: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'Device: %s\n\n' "$DEV"
        printf '[qdisc]\n'
        "$TC_BIN" qdisc show dev "$DEV" 2>&1 || true
        printf '\n[class]\n'
        "$TC_BIN" class show dev "$DEV" 2>&1 || true
        printf '\n[filter]\n'
        "$TC_BIN" filter show dev "$DEV" 2>&1 || true
        printf '\n[qdisc-json]\n'
        "$TC_BIN" -j qdisc show dev "$DEV" 2>&1 || true
        printf '\n[class-json]\n'
        "$TC_BIN" -j class show dev "$DEV" 2>&1 || true
        printf '\n[filter-json]\n'
        "$TC_BIN" -j filter show dev "$DEV" 2>&1 || true
    } > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 600 "$TMP" && mv "$TMP" "$SNAPSHOT" || { rm -f "$TMP"; return 1; }
    printf '%s\n' "$SNAPSHOT"
}

bbr_tc_force_confirm() {
    local DEV="$1" RATE="$2" TC_BIN="$3" QDISCS CLASSES FILTERS CONFIRM
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    FILTERS=$("$TC_BIN" filter show dev "$DEV" 2>/dev/null || true)
    echo ""
    menu_div
    warn "强制接管会删除 ${DEV} 的全部 root qdisc、子 class 和 filter"
    warn "现有 QoS 无法通用自动恢复；重启后本工具仍会覆盖外部 qdisc"
    echo -e "  ${DIM}目标限速：${RATE} Mbps${NC}"
    echo -e "  ${DIM}当前 qdisc：${NC}"
    printf '%s\n' "$QDISCS" | sed 's/^/    /'
    [ -z "$CLASSES" ] || { echo -e "  ${DIM}当前 class：${NC}"; printf '%s\n' "$CLASSES" | sed 's/^/    /'; }
    [ -z "$FILTERS" ] || { echo -e "  ${DIM}当前 filter：${NC}"; printf '%s\n' "$FILTERS" | sed 's/^/    /'; }
    menu_div
    echo ""
    read -rp "  输入 FORCE ${DEV} 确认强制覆盖: " CONFIRM
    if [ "$CONFIRM" != "FORCE ${DEV}" ]; then
        warn "确认词不匹配，已取消强制覆盖"
        return 1
    fi
    return 0
}

bbr_tc_remove_confirm() {
    local DEV="$1" TC_BIN="$2" QDISCS CLASSES FILTERS CONFIRM
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null || true)
    FILTERS=$("$TC_BIN" filter show dev "$DEV" 2>/dev/null || true)
    echo ""
    menu_div
    warn "检测到 ${DEV} 仍有非本工具管理的 root qdisc"
    warn "删除会清除该 root qdisc 的全部子 class 和 filter；clsact 不受影响"
    echo -e "  ${DIM}当前 qdisc：${NC}"
    printf '%s\n' "$QDISCS" | sed 's/^/    /'
    [ -z "$CLASSES" ] || { echo -e "  ${DIM}当前 class：${NC}"; printf '%s\n' "$CLASSES" | sed 's/^/    /'; }
    [ -z "$FILTERS" ] || { echo -e "  ${DIM}当前 filter：${NC}"; printf '%s\n' "$FILTERS" | sed 's/^/    /'; }
    menu_div
    echo ""
    read -rp "  输入 DELETE ${DEV} 确认删除外部限速: " CONFIRM
    if [ "$CONFIRM" != "DELETE ${DEV}" ]; then
        warn "确认词不匹配，外部 qdisc 已保留"
        return 1
    fi
    return 0
}

bbr_state_value() {
    local FILE="$1" KEY="$2"
    [ -f "$FILE" ] || return 1
    awk -F= -v key="$KEY" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$FILE"
}

bbr_tc_topology_matches() {
    local DEV="$1" TC_BIN="$2" QDISCS CLASSES
    QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null) || return 1
    CLASSES=$("$TC_BIN" class show dev "$DEV" 2>/dev/null) || return 1
    printf '%s\n' "$QDISCS" | awk '
        $1 == "qdisc" && $2 == "htb" && $3 == "1:" {
            for (i = 4; i <= NF; i++) if ($i == "root") root = 1
        }
        $1 == "qdisc" && $2 == "fq" && $3 == "100:" {
            for (i = 4; i < NF; i++) if ($i == "parent" && $(i + 1) == "1:10") leaf = 1
        }
        END { exit !(root && leaf) }
    ' || return 1
    printf '%s\n' "$CLASSES" | awk '
        $1 == "class" && $2 == "htb" && $3 == "1:10" { found = 1 }
        END { exit !found }
    '
}

bbr_tc_managed_artifact() {
    if [ -f "$SERVICE_TC" ] && grep -qE \
        '^Description=(VPS TOOLS TC egress shaping|TC egress shaping .+htb shape \+ fq pacing for BBR)' \
        "$SERVICE_TC" 2>/dev/null; then
        return 0
    fi
    if [ -f "$TC_HELPER" ] && grep -qF 'STATE=/var/lib/vps-tools/tc-fq.state' "$TC_HELPER" 2>/dev/null; then
        return 0
    fi
    [ -f "$SERVICE_TC_INIT" ] \
        && grep -qE 'VPS TOOLS network tuning|vps-tools-tc-fq' "$SERVICE_TC_INIT" 2>/dev/null
}

bbr_tc_is_owned() {
    local DEV="$1" TC_BIN="$2" STATE_DEV
    STATE_DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    [ "$STATE_DEV" = "$DEV" ] || return 1
    bbr_tc_topology_matches "$DEV" "$TC_BIN"
}

bbr_tc_is_legacy_owned() {
    local DEV="$1" TC_BIN="$2"
    bbr_tc_managed_artifact || return 1
    bbr_tc_topology_matches "$DEV" "$TC_BIN"
}

bbr_tc_restore_owned() {
    if [ -x "$TC_HELPER" ] && "$TC_HELPER" apply >/dev/null 2>&1; then
        return 0
    fi
    if systemd_available && [ -f "$SERVICE_TC" ]; then
        systemctl restart tc-fq >/dev/null 2>&1 && return 0
    elif command -v rc-service >/dev/null 2>&1 && [ -f "$SERVICE_TC_INIT" ]; then
        rc-service tc-fq restart >/dev/null 2>&1 && return 0
    elif command -v service >/dev/null 2>&1 && [ -f "$SERVICE_TC_INIT" ]; then
        service tc-fq restart >/dev/null 2>&1 && return 0
    fi
    return 1
}

bbr_tc_persistence_current() {
    [ -x "$TC_HELPER" ] \
        && grep -qxF '# VPS_TOOLS_TC_HELPER_VERSION=2' "$TC_HELPER" 2>/dev/null
}

bbr_tc_reconcile_saved() {
    local CURRENT_DEV SAVED_VALUES SAVED_REST SAVED_DEV SAVED_RATE SAVED_BURST SAVED_FORCE TC_BIN
    [ "${VPS_TOOLS_TEST_MODE:-0}" != 1 ] || return 2
    [ "${BBR_TUNE_TEST_MODE:-0}" != 1 ] || return 2
    SAVED_VALUES=$(bbr_tc_saved_values) || return 2
    SAVED_DEV=${SAVED_VALUES%% *}
    SAVED_REST=${SAVED_VALUES#* }
    SAVED_RATE=${SAVED_REST%% *}
    SAVED_REST=${SAVED_REST#* }
    SAVED_BURST=${SAVED_REST%% *}
    SAVED_FORCE=${SAVED_REST##* }
    CURRENT_DEV=$(default_iface)
    if [ "$SAVED_DEV" != "$CURRENT_DEV" ]; then
        warn "已保存 ${SAVED_DEV} 的 ${SAVED_RATE}Mbps 限速，但当前默认网卡为 ${CURRENT_DEV:-未知}，未自动迁移"
        return 1
    fi
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$TC_BIN" ] || { warn "已保存 ${SAVED_RATE}Mbps 限速，但 tc 命令不可用"; return 1; }
    if bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
        bbr_tc_persistence_current && return 0
        if bbr_tc_write_persistence "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$SAVED_FORCE" \
            && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
            info "检测到旧版 tc 持久化配置，已自动升级 ✓"
            return 0
        fi
        warn "tc 限速当前有效，但持久化配置升级失败"
        return 1
    fi
    if bbr_tc_persistence_current \
        && bbr_tc_restore_owned \
        && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
        info "检测到已保存的 ${SAVED_RATE}Mbps 限速未生效，已自动恢复 ✓"
        return 0
    fi
    if bbr_tc_apply_runtime "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$TC_BIN" "$SAVED_FORCE"; then
        if bbr_tc_write_persistence "$SAVED_DEV" "$SAVED_RATE" "$SAVED_BURST" "$SAVED_FORCE" \
            && bbr_tc_is_owned "$SAVED_DEV" "$TC_BIN"; then
            info "检测到已保存的 ${SAVED_RATE}Mbps 限速未生效，已自动恢复并升级持久化配置 ✓"
            return 0
        fi
        warn "tc 限速已恢复运行，但持久化配置更新失败"
        return 1
    fi
    warn "已保存 ${SAVED_RATE}Mbps 限速，但自动恢复失败"
    echo -e "  ${DIM}可检查：${TC_HELPER} apply && tc -s qdisc show dev ${SAVED_DEV}${NC}"
    return 1
}

bbr_tc_apply_runtime() {
    local DEV="$1" RATE="$2" BURST_KB="$3" TC_BIN="$4" FORCE="${5:-0}"
    local QDISCS LINE TYPE WAS_OWNED=0 FORCED_FOREIGN=0 SNAPSHOT="" ROOT_ACTION=add
    if ! QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null); then
        error "无法读取 ${DEV} 的当前 tc 配置，已拒绝修改"
        return 1
    fi
    LINE=$(bbr_tc_root_line "$QDISCS")
    TYPE=$(bbr_tc_qdisc_type "$LINE")
    if bbr_tc_is_owned "$DEV" "$TC_BIN"; then
        WAS_OWNED=1
    elif bbr_tc_is_legacy_owned "$DEV" "$TC_BIN"; then
        WAS_OWNED=1
        info "识别到旧版 VPS Tools tc 限速规则，将自动迁移"
    fi
    if [ "$WAS_OWNED" -eq 0 ] && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
        if [ "$FORCE" != 1 ]; then
            error "检测到非本工具管理的 root qdisc：${TYPE:-未知}，需要强制确认"
            echo -e "  ${DIM}默认不会覆盖；确认后可由本工具强制接管${NC}"
            return 2
        fi
        SNAPSHOT=$(bbr_tc_snapshot_foreign "$DEV" "$TC_BIN") || {
            error "无法保存现有 tc 诊断快照，已拒绝强制覆盖"
            return 1
        }
        FORCED_FOREIGN=1
        warn "已保存现有 tc 诊断快照：${SNAPSHOT}"
    fi

    if [ -n "$LINE" ]; then
        if [ "$WAS_OWNED" -eq 0 ] && [ "$FORCED_FOREIGN" -eq 0 ]; then
            # mq/noqueue 等内核默认 qdisc 不能可靠 del，replace 可原子接管 root。
            ROOT_ACTION=replace
        elif ! "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null; then
            error "无法删除 ${DEV} 的现有 root qdisc"
            return 1
        fi
    fi

    if ! "$TC_BIN" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 2>/dev/null; then
        error "无法在 ${DEV} 安装 HTB root qdisc（内核可能缺 sch_htb 模块）"
        if [ "$WAS_OWNED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "旧 tc 限速规则自动恢复失败"
        elif [ "$FORCED_FOREIGN" -eq 1 ]; then
            warn "外部 qdisc 已删除且无法通用自动恢复，请按原管理工具重建"
            warn "删除前诊断快照：${SNAPSHOT}"
        fi
        return 1
    fi
    if ! "$TC_BIN" class add dev "$DEV" parent 1: classid 1:10 htb \
                rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" 2>/dev/null \
        || ! "$TC_BIN" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit" 2>/dev/null; then
        error "tc 规则应用失败（内核可能缺 sch_htb / sch_fq 模块）"
        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || true
        if [ "$WAS_OWNED" -eq 1 ]; then
            bbr_tc_restore_owned || warn "旧 tc 限速规则自动恢复失败"
        elif [ "$FORCED_FOREIGN" -eq 1 ]; then
            warn "外部 qdisc 已删除且无法通用自动恢复，请按原管理工具重建"
            warn "删除前诊断快照：${SNAPSHOT}"
        fi
        return 1
    fi
    [ "$FORCED_FOREIGN" -eq 0 ] || warn "已强制接管 ${DEV} 的 root qdisc"
    return 0
}

bbr_tc_write_persistence() {
    local DEV="$1" RATE="$2" BURST_KB="$3" FORCE="${4:-0}" TMP
    mkdir -p "$(dirname "$TC_HELPER")" "$(dirname "$TC_STATE_FILE")" 2>/dev/null || {
        error "无法创建 tc 持久化目录"
        return 1
    }
    TMP=$(mktemp "${TC_STATE_FILE}.tmp.XXXXXX") || return 1
    printf 'DEV=%s\nRATE=%s\nBURST_KB=%s\nFORCE=%s\n' "$DEV" "$RATE" "$BURST_KB" "$FORCE" > "$TMP" || {
        rm -f "$TMP"
        return 1
    }
    chmod 600 "$TMP" && mv "$TMP" "$TC_STATE_FILE" || { rm -f "$TMP"; return 1; }

    TMP=$(mktemp "${TC_HELPER}.tmp.XXXXXX") || return 1
    cat > "$TMP" << 'TC_HELPER_EOF'
#!/bin/sh
# VPS_TOOLS_TC_HELPER_VERSION=2
STATE=/var/lib/vps-tools/tc-fq.state
state_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE"; }
DEV=$(state_value DEV)
RATE=$(state_value RATE)
BURST_KB=$(state_value BURST_KB)
FORCE=$(state_value FORCE)
[ "$FORCE" = 1 ] || FORCE=0
TC=$(command -v tc 2>/dev/null || echo /sbin/tc)
[ -n "$DEV" ] && echo "$RATE" | grep -qE '^[0-9]+$' && echo "$BURST_KB" | grep -qE '^[0-9]+$' || exit 1
QDISCS=$("$TC" qdisc show dev "$DEV" 2>/dev/null)
CLASSES=$("$TC" class show dev "$DEV" 2>/dev/null)
LINE=$(printf '%s\n' "$QDISCS" | awk '$1 == "qdisc" { for (i=4; i<=NF; i++) if ($i == "root") { print; exit } }')
TYPE=$(printf '%s\n' "$LINE" | awk 'NR==1 { print $2 }')
OWNED=0
if printf '%s\n' "$QDISCS" | awk '
    $1 == "qdisc" && $2 == "htb" && $3 == "1:" { for (i=4; i<=NF; i++) if ($i == "root") root=1 }
    $1 == "qdisc" && $2 == "fq" && $3 == "100:" { for (i=4; i<NF; i++) if ($i == "parent" && $(i+1) == "1:10") leaf=1 }
    END { exit !(root && leaf) }
' && printf '%s\n' "$CLASSES" | awk '$1 == "class" && $2 == "htb" && $3 == "1:10" { found=1 } END { exit !found }'; then
    OWNED=1
fi
if [ "${1:-apply}" = remove ]; then
    [ "$OWNED" -eq 0 ] || "$TC" qdisc del dev "$DEV" root
    exit $?
fi
if [ "${1:-apply}" = status ]; then
    [ "$OWNED" -eq 1 ]
    exit $?
fi
ROOT_ACTION=add
case "$TYPE" in
    ""|mq|fq|fq_codel|noqueue|pfifo_fast) ROOT_ACTION=replace ;;
    htb) [ "$OWNED" -eq 1 ] || [ "$FORCE" -eq 1 ] || exit 1 ;;
    *) [ "$FORCE" -eq 1 ] || exit 1 ;;
esac
if [ "$OWNED" -eq 1 ] || { [ -n "$LINE" ] && [ "$ROOT_ACTION" != replace ]; }; then
    "$TC" qdisc del dev "$DEV" root 2>/dev/null || exit 1
fi
"$TC" qdisc "$ROOT_ACTION" dev "$DEV" root handle 1: htb default 10 && \
"$TC" class add dev "$DEV" parent 1: classid 1:10 htb rate "${RATE}mbit" ceil "${RATE}mbit" burst "${BURST_KB}kb" cburst "${BURST_KB}kb" && \
"$TC" qdisc add dev "$DEV" parent 1:10 handle 100: fq maxrate "${RATE}mbit"
TC_HELPER_EOF
    chmod 700 "$TMP" && mv "$TMP" "$TC_HELPER" || { rm -f "$TMP"; return 1; }

    if systemd_available; then
        TMP=$(mktemp "${SERVICE_TC}.tmp.XXXXXX") || return 1
        cat > "$TMP" << EOF
[Unit]
Description=VPS TOOLS TC egress shaping
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${TC_HELPER} apply
ExecStop=${TC_HELPER} remove
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        mv "$TMP" "$SERVICE_TC" || { rm -f "$TMP"; return 1; }
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable tc-fq --quiet >/dev/null 2>&1 \
            && systemctl restart tc-fq >/dev/null 2>&1 || {
                error "tc 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" openrc || return 1
        rc-update add tc-fq default >/dev/null 2>&1 \
            && rc-service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_TC_INIT" "$TC_HELPER" sysv || return 1
        update-rc.d tc-fq defaults >/dev/null 2>&1 \
            && service tc-fq restart >/dev/null 2>&1 || {
                error "tc 已立即生效，但 SysV 持久化失败"
                return 1
            }
    else
        error "tc 已立即生效，但未检测到支持的服务管理器，无法设置开机恢复"
        return 1
    fi
}

bbr_write_init_script() {
    local DEST="$1" HELPER="$2" MODE="$3" TMP
    TMP=$(mktemp "${DEST}.tmp.XXXXXX") || return 1
    if [ "$MODE" = openrc ]; then
        cat > "$TMP" << EOF
#!/sbin/openrc-run
description="VPS TOOLS network tuning"
depend() { need net; }
start() { ebegin "Applying VPS TOOLS network tuning"; ${HELPER} apply; eend \$?; }
stop() { ebegin "Stopping VPS TOOLS network tuning"; ${HELPER} remove; eend \$?; }
status() { ${HELPER} status; }
EOF
    else
        cat > "$TMP" << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $(basename "$DEST")
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: VPS TOOLS network tuning
### END INIT INFO
case "\${1:-start}" in
    start|restart) ${HELPER} apply ;;
    stop) ${HELPER} remove ;;
    status) ${HELPER} status ;;
    *) echo "Usage: \$0 {start|stop|restart|status}" >&2; exit 2 ;;
esac
EOF
    fi
    chmod 755 "$TMP" && mv "$TMP" "$DEST" || { rm -f "$TMP"; return 1; }
}

bbr_apply_tc() {
    local RATE="$1" FORCE="${2:-0}" APPLY_RC
    local DEV; DEV=$(default_iface)
    [ -z "$DEV" ] && { error "无法确定默认出口网卡"; return 1; }
    local TC_BIN
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    [ -x "$TC_BIN" ] || { error "tc 命令不可用，请先安装 iproute2"; return 1; }

    # burst/cburst 随速率缩放（约 8ms 量级，≈ RATE KB），下限 32KB。
    # 固定 burst 会在高速率下令牌饥饿，导致跑不满设定速率。
    local BURST_KB=$RATE
    [ "$BURST_KB" -lt 32 ] && BURST_KB=32

    bbr_tc_apply_runtime "$DEV" "$RATE" "$BURST_KB" "$TC_BIN" "$FORCE"
    APPLY_RC=$?
    [ "$APPLY_RC" -eq 0 ] || return "$APPLY_RC"
    bbr_tc_write_persistence "$DEV" "$RATE" "$BURST_KB" "$FORCE" || {
        error "tc 已立即生效，但持久化配置未完成"
        return 1
    }
    info "tc 限速已应用：${RATE}Mbps（htb 聚合整形 + fq pacing，burst ${BURST_KB}KB）✓"
    return 0
}

bbr_remove_tc() {
    local FORCE="${1:-0}" TC_BIN DEV FAILED=0 FOREIGN=0 QDISCS LINE TYPE SNAPSHOT=""
    TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
    DEV=$(bbr_state_value "$TC_STATE_FILE" DEV 2>/dev/null || true)
    [ -n "$DEV" ] || DEV=$(default_iface)
    if [ -x "$TC_BIN" ] && [ -n "$DEV" ]; then
        if bbr_tc_is_owned "$DEV" "$TC_BIN" || bbr_tc_is_legacy_owned "$DEV" "$TC_BIN"; then
            "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || FAILED=1
        else
            QDISCS=$("$TC_BIN" qdisc show dev "$DEV" 2>/dev/null || true)
            LINE=$(bbr_tc_root_line "$QDISCS")
            TYPE=$(bbr_tc_qdisc_type "$LINE")
            if [ -n "$LINE" ] && ! bbr_tc_qdisc_safe_to_replace "$TYPE"; then
                if [ "$FORCE" = 1 ]; then
                    SNAPSHOT=$(bbr_tc_snapshot_foreign "$DEV" "$TC_BIN") || FAILED=1
                    if [ "$FAILED" -eq 0 ]; then
                        warn "已保存外部 tc 诊断快照：${SNAPSHOT}"
                        "$TC_BIN" qdisc del dev "$DEV" root 2>/dev/null || FAILED=1
                    fi
                else
                    FOREIGN=1
                fi
            fi
        fi
    fi

    if systemd_available; then
        systemctl disable --now tc-fq >/dev/null 2>&1 || true
        rm -f "$SERVICE_TC"
        systemctl daemon-reload >/dev/null 2>&1 || FAILED=1
    elif command -v rc-update >/dev/null 2>&1; then
        rc-service tc-fq stop >/dev/null 2>&1 || true
        rc-update del tc-fq default >/dev/null 2>&1 || true
    elif command -v update-rc.d >/dev/null 2>&1; then
        service tc-fq stop >/dev/null 2>&1 || true
        update-rc.d -f tc-fq remove >/dev/null 2>&1 || true
    fi
    rm -f "$SERVICE_TC_INIT" "$TC_HELPER" "$TC_STATE_FILE"
    if [ "$FAILED" -ne 0 ]; then
        error "取消 tc 限速时发生错误"
        return 1
    fi
    if [ "$FOREIGN" -eq 1 ]; then
        warn "本工具的 tc 持久化已取消，但外部 root qdisc ${TYPE:-未知} 仍在生效"
        return 2
    fi
    [ "$FORCE" != 1 ] || info "外部 root qdisc 已删除 ✓"
    info "已取消本工具管理的 tc 限速 ✓"
}

# ── 生成 sysctl 配置内容 ──────────────────────────────────
bbr_physical_memory_mb() {
    local MEM_KB
    MEM_KB=$(awk '/MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)
    case "$MEM_KB" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo $(( MEM_KB / 1024 )) ;;
    esac
}

bbr_effective_memory_mb() {
    local REQUESTED_MB="$1" ACTUAL_MB="${2:-}"
    [ -n "$ACTUAL_MB" ] || ACTUAL_MB=$(bbr_physical_memory_mb)
    case "$REQUESTED_MB" in ''|*[!0-9]*) return 1 ;; esac
    case "$ACTUAL_MB" in ''|*[!0-9]*) ACTUAL_MB=0 ;; esac
    if [ "$ACTUAL_MB" -gt 0 ] && [ "$REQUESTED_MB" -gt "$ACTUAL_MB" ]; then
        echo "$ACTUAL_MB"
    else
        echo "$REQUESTED_MB"
    fi
}

bbr_buffer_cap_bytes() {
    local MEM_MB="$1"
    case "$MEM_MB" in ''|*[!0-9]*) return 1 ;; esac
    [ "$MEM_MB" -gt 0 ] || return 1
    echo $(( MEM_MB * 1048576 / 4 ))
}

bbr_conntrack_max_for_memory() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -lt 1024 ]; then
        echo 131072
    elif [ "$MEM_MB" -lt 2048 ]; then
        echo 262144
    elif [ "$MEM_MB" -lt 4096 ]; then
        echo 524288
    else
        echo 1048576
    fi
}

bbr_generate_config() {
    local RMEM=$1 WMEM=$2 NOTSENT=$3 SWAPPINESS=$4 \
          PROFILE_NAME="${5:-default}" ENABLE_FORWARD="${6:-0}"
    local TCP_CONFIG
    if [ "$#" -ge 7 ]; then
        TCP_CONFIG=$(bbr_tcp_config "$7") || return 1
    else
        TCP_CONFIG=$(bbr_tcp_config) || return 1
    fi
    cat << EOF
# BBR TCP 调优配置 — 生成时间：$(date)
# 预设：${PROFILE_NAME}
# ── 内存管理 ──
vm.swappiness = ${SWAPPINESS}

# ── BBR 核心 ──
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── 缓冲区 ──
net.core.rmem_max = ${RMEM}
net.core.wmem_max = ${WMEM}
net.ipv4.tcp_rmem = 4096 131072 ${RMEM}
net.ipv4.tcp_wmem = 4096 16384 ${WMEM}
net.ipv4.tcp_notsent_lowat = ${NOTSENT}

# ── 连接质量 ──
${TCP_CONFIG}

# ── UDP 缓冲（QUIC / Hysteria2 / TUIC 代理）──
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF

    # 场景预设的并发参数不依赖内核转发，用户态代理同样受益。
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            cat << EOF

# ── 代理并发 ──
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_max_tw_buckets = 500000
fs.file-max = 1048576
EOF
            ;;
    esac

    if [ "$ENABLE_FORWARD" = 1 ]; then
        local IPV6_IFACE
        IPV6_IFACE=$(bbr_default_ipv6_iface)
        IPV6_IFACE=$(printf '%s' "$IPV6_IFACE" | tr '.' '/')
        cat << EOF

# ── 内核路由 / NAT ──
net.ipv6.conf.default.accept_ra = 2
EOF
        if [ -n "$IPV6_IFACE" ]; then
            cat << EOF
net.ipv6.conf.${IPV6_IFACE}.accept_ra = 2
EOF
        fi
        printf '%s\n' 'net.ipv4.ip_forward = 1' 'net.ipv6.conf.all.forwarding = 1'
    fi

    if [ "$ENABLE_FORWARD" = 1 ] && [ "$PROFILE_NAME" = "relay" ]; then
        local MEM_MB CONNTRACK_MAX
        MEM_MB=$(bbr_physical_memory_mb)
        CONNTRACK_MAX=$(bbr_conntrack_max_for_memory "$MEM_MB")
        cat << EOF

# ── conntrack（按物理内存分档）──
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF
    fi
}

# ── 确认并应用参数 ────────────────────────────────────────
bbr_preflight() {
    ensure_sysctl || return 1
    if ! has_sysctl_write; then
        error "当前容器无 sysctl 写入权限，无法应用配置"
        echo -e "  ${DIM}需要宿主机开启 privileged 模式或 sysctl 白名单${NC}"
        return 1
    fi
    bbr_check_kernel || return 1
}

# ── 检测常见代理 service 的 LimitNOFILE，偏低则提示写 drop-in ──
# fs.file-max 只是系统总上限，单进程 fd 上限由 systemd 的 LimitNOFILE 决定。
bbr_check_limitnofile() {
    command -v systemctl >/dev/null 2>&1 || return 0   # 非 systemd 跳过
    local SVCS="xray sing-box hysteria hysteria-server tuic v2ray trojan trojan-go mihomo clash"
    local svc found=0
    for svc in $SVCS; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service" || continue
        found=1
        local CUR
        CUR=$(systemctl show -p LimitNOFILE --value "${svc}.service" 2>/dev/null)
        # 默认值通常为 1024 / 524288；低于 1048576 视为偏低
        if [ -n "$CUR" ] && [ "$CUR" -lt 1048576 ] 2>/dev/null; then
            echo ""
            warn "检测到代理服务 ${svc}.service 的 LimitNOFILE=${CUR} 偏低"
            echo -e "  ${DIM}fs.file-max 已抬高，但单进程 fd 上限受 systemd LimitNOFILE 限制${NC}"
            read -rp "  是否为 ${svc} 写入 LimitNOFILE=1048576 的 drop-in？(y/N，默认N): " DOLN
            [ -z "$DOLN" ] && DOLN="n"
            if echo "$DOLN" | grep -qiE '^y(es)?$'; then
                local DROPDIR="/etc/systemd/system/${svc}.service.d"
                mkdir -p "$DROPDIR" 2>/dev/null
                printf '[Service]\nLimitNOFILE=1048576\n' > "${DROPDIR}/99-nofile.conf"
                systemctl daemon-reload 2>/dev/null
                info "已写入 ${DROPDIR}/99-nofile.conf，重启 ${svc} 后生效：systemctl restart ${svc}"
            fi
        fi
    done
    [ "$found" -eq 0 ] && return 0
}

bbr_kernel_forwarding_confirm() {
    local ANSWER
    read -rp "  是否启用内核 IPv4/IPv6 转发？仅路由或 NAT 需要 (y/N，默认N): " ANSWER
    [ -z "$ANSWER" ] && ANSWER="n"
    echo "$ANSWER" | grep -qiE '^y(es)?$'
}

bbr_confirm_apply() {
    local RMEM=$1 WMEM=$2 NOTSENT=$3 SWAP=$4 \
          LABEL_MODE=$5 LABEL_BUF=$6 PROFILE_NAME="${7:-default}" ENABLE_FORWARD=0

    bbr_preflight || return 1
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            echo ""
            bbr_kernel_forwarding_confirm && ENABLE_FORWARD=1
            ;;
    esac

    echo ""
    echo -e "  ${YELLOW}── 配置摘要 ──────────────────────────────${NC}"
    echo -e "  模式         : ${BOLD}$LABEL_MODE${NC}"
    echo -e "  缓冲区       : ${BOLD}${LABEL_BUF}MB${NC}  (rmem/wmem max)"
    echo -e "  TCP min/default  : ${BOLD}接收 4KB/128KB · 发送 4KB/16KB${NC}"
    echo -e "  全局 TCP 内存    : ${BOLD}由内核自动管理${NC}"
    echo -e "  swappiness   : ${BOLD}${SWAP}${NC}"
    case "$PROFILE_NAME" in
        relay|landing|line_landing)
            [ "$ENABLE_FORWARD" = 1 ] \
                && echo -e "  内核转发     : ${BOLD}启用${NC}" \
                || echo -e "  内核转发     : ${BOLD}不修改${NC}"
            ;;
    esac
    echo -e "  ${YELLOW}──────────────────────────────────────────${NC}"
    echo ""

    # 先提示备份（默认Y）
    if [ -f "$SYSCTL_FILE" ]; then
        read -rp "  备份当前 sysctl 配置？(Y/n，默认Y): " DO_BAK
        [ -z "$DO_BAK" ] && DO_BAK="y"
        if echo "$DO_BAK" | grep -qiE '^y(es)?$' && ! bbr_backup_sysctl; then
            error "无法安全备份，已取消应用"
            return 1
        fi
        echo ""
    fi
    read -rp "  确认应用以上配置？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    local CONFIG ORIGINAL_CONFIG=""
    [ ! -f "$SYSCTL_FILE" ] || ORIGINAL_CONFIG=$(cat "$SYSCTL_FILE")
    CONFIG=$(bbr_generate_config "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" "$PROFILE_NAME" "$ENABLE_FORWARD" "$ORIGINAL_CONFIG") || return 1
    [ "$ENABLE_FORWARD" != 1 ] \
        || ensure_conntrack_module \
        || warn "无法预加载 nf_conntrack，将按内核实际支持情况应用"
    bbr_apply_sysctl "$CONFIG" ask '' '' '' "$ORIGINAL_CONFIG" || {
        error "BBR TCP 调优配置应用失败"
        return 1
    }
    # 场景预设（转发机）额外检测代理 service 的 fd 上限
    case "$PROFILE_NAME" in
        relay|landing|line_landing) bbr_check_limitnofile ;;
    esac
    echo ""
    info "BBR TCP 调优配置完成 ✓"
    warn "建议配合限速设置使用，避免 Retr 爆炸"
    return 0
}

# ── 自动计算模式：根据 BDP 推导缓冲区 ───────────────────
bbr_bdp_mb() {
    awk -v bw="$1" -v lat="$2" 'BEGIN { printf "%.2f", bw * lat / 8000 }'
}

bbr_buffer_target_mb() {
    local BW_MBPS="$1" LAT_MS="$2"
    printf '%s\n' $(( (BW_MBPS * LAT_MS * 3 + 15999) / 16000 ))
}

bbr_auto_calc() {
    local MEM_MB=$1 LAT_MS=$2 BW_MBPS=$3 MEM_LBL=$4 LAT_LBL=$5 BW_LBL=$6
    local ACTUAL_MEM_MB EFFECTIVE_MEM_MB
    ACTUAL_MEM_MB=$(bbr_physical_memory_mb)
    EFFECTIVE_MEM_MB=$(bbr_effective_memory_mb "$MEM_MB" "$ACTUAL_MEM_MB") || return 1
    if [ "$EFFECTIVE_MEM_MB" -lt "$MEM_MB" ]; then
        warn "所选内存 ${MEM_MB}MB 超过实际内存 ${ACTUAL_MEM_MB}MB，按实际内存计算"
        MEM_LBL="${MEM_LBL}，按实际 ${ACTUAL_MEM_MB}MB"
    fi
    MEM_MB=$EFFECTIVE_MEM_MB

    local BDP_MB BUF_CALC
    BDP_MB=$(bbr_bdp_mb "$BW_MBPS" "$LAT_MS")
    BUF_CALC=$(bbr_buffer_target_mb "$BW_MBPS" "$LAT_MS")

    local RMEM WMEM NOTSENT
    if   [ "$BUF_CALC" -le 10 ];  then RMEM=12582912;   NOTSENT=131072
    elif [ "$BUF_CALC" -le 20 ];  then RMEM=20971520;   NOTSENT=131072
    elif [ "$BUF_CALC" -le 32 ];  then RMEM=33554432;   NOTSENT=262144
    elif [ "$BUF_CALC" -le 40 ];  then RMEM=41943040;   NOTSENT=262144
    elif [ "$BUF_CALC" -le 64 ];  then RMEM=67108864;   NOTSENT=524288
    elif [ "$BUF_CALC" -le 128 ]; then RMEM=134217728;  NOTSENT=524288
    elif [ "$BUF_CALC" -le 256 ]; then RMEM=268435456;  NOTSENT=1048576
    elif [ "$BUF_CALC" -le 512 ]; then RMEM=536870912;  NOTSENT=2097152
    else                                RMEM=1073741824; NOTSENT=2097152
    fi
    WMEM=$RMEM

    local BUFFER_CAP
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "缓冲区 $(( RMEM / 1048576 ))MB 超过实际内存 ${MEM_MB}MB 的 25%，自动降级"
        RMEM=$BUFFER_CAP
        WMEM=$BUFFER_CAP
    fi

    local SWAP=5
    [ "$MEM_MB" -le 1536 ] && SWAP=10

    local BUF_MB=$(( RMEM / 1048576 ))
    echo ""
    echo -e "  BDP 估算：${BOLD}${BDP_MB}MB${NC}  →  推荐缓冲区：${BOLD}${BUF_MB}MB${NC}"
    echo -e "  内存：${MEM_LBL}  延迟：${LAT_LBL}  带宽：${BW_LBL}"

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" \
        "自动计算（${MEM_LBL} / ${LAT_LBL} / ${BW_LBL}）" "$BUF_MB"
}

# ── 手动选择缓冲区模式 ────────────────────────────────────
# ── 自动模式：带宽子菜单 ─────────────────────────────────
bbr_menu_bandwidth() {
    local MEM_MB=$1 LAT_MS=$2 MEM_LBL=$3 LAT_LBL=$4
    print_header "BBR 自动配置 — 选择带宽"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}  延迟：${BOLD}${LAT_LBL}${NC}"
    echo ""
    menu_pair "1" "100 Mbps" "2" "200 Mbps"
    menu_pair "3" "500 Mbps" "4" "1 Gbps"
    menu_pair "5" "2 Gbps" "6" "5 Gbps"
    menu_item "7" "10 Gbps"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择带宽 [0-7]: ')" CH
    case "$CH" in
        1) bbr_auto_calc "$MEM_MB" "$LAT_MS" 100   "$MEM_LBL" "$LAT_LBL" "100Mbps" ;;
        2) bbr_auto_calc "$MEM_MB" "$LAT_MS" 200   "$MEM_LBL" "$LAT_LBL" "200Mbps" ;;
        3) bbr_auto_calc "$MEM_MB" "$LAT_MS" 500   "$MEM_LBL" "$LAT_LBL" "500Mbps" ;;
        4) bbr_auto_calc "$MEM_MB" "$LAT_MS" 1024  "$MEM_LBL" "$LAT_LBL" "1Gbps" ;;
        5) bbr_auto_calc "$MEM_MB" "$LAT_MS" 2048  "$MEM_LBL" "$LAT_LBL" "2Gbps" ;;
        6) bbr_auto_calc "$MEM_MB" "$LAT_MS" 5120  "$MEM_LBL" "$LAT_LBL" "5Gbps" ;;
        7) bbr_auto_calc "$MEM_MB" "$LAT_MS" 10240 "$MEM_LBL" "$LAT_LBL" "10Gbps" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：延迟子菜单 ─────────────────────────────────
bbr_menu_latency() {
    local MEM_MB=$1 MEM_LBL=$2
    print_header "BBR 自动配置 — 选择延迟"
    echo -e "  内存：${BOLD}${MEM_LBL}${NC}"
    echo ""
    menu_item "1" "100ms 以内  ${DIM}国内 / 亚洲${NC}"
    menu_item "2" "100-200ms  ${DIM}跨国线路${NC}"
    menu_item "3" "200ms 以上  ${DIM}跨洲长距离${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择延迟 [0-3]: ')" CH
    case "$CH" in
        1) bbr_menu_bandwidth "$MEM_MB" 50  "$MEM_LBL" "100ms以内" ;;
        2) bbr_menu_bandwidth "$MEM_MB" 150 "$MEM_LBL" "100-200ms" ;;
        3) bbr_menu_bandwidth "$MEM_MB" 250 "$MEM_LBL" "200ms以上" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 自动模式：内存子菜单 ─────────────────────────────────
bbr_menu_auto() {
    # 自动检测系统内存并标注推荐档位
    local SYS_MEM_MB
    SYS_MEM_MB=$(bbr_physical_memory_mb)

    print_header "BBR 自动配置 — 选择内存"
    echo -e "  系统检测内存：${BOLD}${SYS_MEM_MB}MB${NC}"
    echo ""
    menu_pair "1" "512 MB" "2" "1 GB"
    menu_pair "3" "2 GB" "4" "4 GB"
    menu_pair "5" "8 GB" "6" "16 GB+"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    read -rp "$(ui_prompt '选择内存 [0-6]: ')" CH
    local SELECTED_MB SELECTED_LABEL EFFECTIVE_MB
    case "$CH" in
        1) SELECTED_MB=512;   SELECTED_LABEL="512MB" ;;
        2) SELECTED_MB=1024;  SELECTED_LABEL="1GB" ;;
        3) SELECTED_MB=2048;  SELECTED_LABEL="2GB" ;;
        4) SELECTED_MB=4096;  SELECTED_LABEL="4GB" ;;
        5) SELECTED_MB=8192;  SELECTED_LABEL="8GB" ;;
        6) SELECTED_MB=16384; SELECTED_LABEL="16GB+" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    EFFECTIVE_MB=$(bbr_effective_memory_mb "$SELECTED_MB" "$SYS_MEM_MB") || return 1
    if [ "$EFFECTIVE_MB" -lt "$SELECTED_MB" ]; then
        warn "所选内存 ${SELECTED_LABEL} 超过实际内存 ${SYS_MEM_MB}MB，后续按实际内存计算"
        SELECTED_LABEL="${SELECTED_LABEL}（实际 ${SYS_MEM_MB}MB）"
    fi
    bbr_menu_latency "$EFFECTIVE_MB" "$SELECTED_LABEL"
}

# ── 手动模式：内存子菜单 ─────────────────────────────────
bbr_menu_manual() {
    # 自动检测系统内存
    local MEM_MB
    MEM_MB=$(bbr_physical_memory_mb)
    [ "$MEM_MB" -gt 0 ] || { error "无法读取物理内存"; return 1; }

    # ── 第一层：选择用途 ──
    print_header "BBR 手动配置 — 选择用途"
    echo -e "  检测到系统内存：${BOLD}${MEM_MB}MB${NC}"
    echo ""
    menu_div
    echo -e "  ${BOLD}请选择 VPS 用途（决定并发与队列参数）${NC}"
    echo ""
    menu_item "1" "中转机  ${DIM}双向转发 / 大并发${NC}"
    menu_item "2" "落地机  ${DIM}跨境上行 / 大缓冲${NC}"
    menu_item "3" "线路落地机  ${DIM}低延迟优先${NC}"
    menu_item "4" "通用单机  ${DIM}网页 / SSH / 服务${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择用途 [0-4]: ')" SCENE
    local PROFILE SCENE_LABEL
    case "$SCENE" in
        1) PROFILE="relay";        SCENE_LABEL="中转机" ;;
        2) PROFILE="landing";      SCENE_LABEL="落地机" ;;
        3) PROFILE="line_landing"; SCENE_LABEL="线路落地机" ;;
        4) PROFILE="default";      SCENE_LABEL="通用单机" ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # ── 第二层：根据场景给出推荐档位提示 + 缓冲区选择 ──
    local RECOMMEND
    case "$PROFILE" in
        relay)
            # 中转机：中等缓冲足够，并发为主
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 4 (32MB) 或 5 (40MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 7 (128MB)"
            else                              RECOMMEND="推荐 8 (256MB)"
            fi ;;
        landing)
            # 落地机：大缓冲吃满带宽
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 6 (64MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 7 (128MB)"
            elif [ "$MEM_MB" -le 4096 ]; then RECOMMEND="推荐 8 (256MB)"
            elif [ "$MEM_MB" -le 8192 ]; then RECOMMEND="推荐 9 (512MB)"
            else                              RECOMMEND="推荐 9 (512MB) 或 10 (1024MB)"
            fi ;;
        line_landing)
            # 线路落地机：低延迟优先，缓冲不用大
            if   [ "$MEM_MB" -le 1024 ]; then RECOMMEND="推荐 3 (20MB) 或 4 (32MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 4 (32MB) 或 6 (64MB)"
            else                              RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            fi ;;
        default)
            if   [ "$MEM_MB" -le 768 ];  then RECOMMEND="推荐 2 (16MB) 或 3 (20MB)"
            elif [ "$MEM_MB" -le 2048 ]; then RECOMMEND="推荐 4 (32MB) 或 6 (64MB)"
            else                              RECOMMEND="推荐 6 (64MB) 或 7 (128MB)"
            fi ;;
    esac

    print_header "BBR 手动配置 — ${SCENE_LABEL} · 选择缓冲区"
    echo -e "  场景：${BOLD}${SCENE_LABEL}${NC}    内存：${BOLD}${MEM_MB}MB${NC}"
    echo -e "  ${YELLOW}${RECOMMEND}${NC}"
    echo ""
    menu_div
    menu_pair "1" "12 MB · 低带宽" "2" "16 MB · 小内存"
    menu_pair "3" "20 MB · 中低带宽" "4" "32 MB · 跨境推荐"
    menu_pair "5" "40 MB · 1G" "6" "64 MB · 1G+"
    menu_pair "7" "128 MB · 2G" "8" "256 MB · 5G"
    menu_pair "9" "512 MB · 10G" "10" "1024 MB · 极限"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择缓冲区 [0-10]: ')" CH

    local RMEM WMEM BUF_LBL
    case "$CH" in
        1)  RMEM=12582912;   BUF_LBL=12   ;;
        2)  RMEM=16777216;   BUF_LBL=16   ;;
        3)  RMEM=20971520;   BUF_LBL=20   ;;
        4)  RMEM=33554432;   BUF_LBL=32   ;;
        5)  RMEM=41943040;   BUF_LBL=40   ;;
        6)  RMEM=67108864;   BUF_LBL=64   ;;
        7)  RMEM=134217728;  BUF_LBL=128  ;;
        8)  RMEM=268435456;  BUF_LBL=256  ;;
        9)  RMEM=536870912;  BUF_LBL=512  ;;
        10) RMEM=1073741824; BUF_LBL=1024 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac
    WMEM=$RMEM

    local BUFFER_CAP
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "缓冲区 ${BUF_LBL}MB 超过物理内存 ${MEM_MB}MB 的 25%，高并发时可能造成内存压力"
        read -rp "  是否继续？(y/N，默认N): " GO
        [ -z "$GO" ] && GO="n"
        echo "$GO" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    fi

    # ── 根据场景调整待发送队列 ──
    local NOTSENT
    case "$PROFILE" in
        relay)
            # 中转机：NOTSENT 小（降低单连接延迟）
            NOTSENT=262144
            ;;
        landing)
            # 落地机：NOTSENT 大（高吞吐）
            NOTSENT=2097152
            ;;
        line_landing)
            # 线路落地机：NOTSENT 极小（响应优先）
            NOTSENT=131072
            ;;
        default)
            # 通用：跟着缓冲区档位走
            if   [ "$BUF_LBL" -le 32 ];  then NOTSENT=262144
            elif [ "$BUF_LBL" -le 64 ];  then NOTSENT=524288
            elif [ "$BUF_LBL" -le 256 ]; then NOTSENT=1048576
            else                              NOTSENT=2097152
            fi ;;
    esac

    local SWAP=5
    [ "$MEM_MB" -le 1536 ] && SWAP=10
    # 中转机额外抬高 swappiness（容忍多进程）
    [ "$PROFILE" = "relay" ] && SWAP=10

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" \
        "${SCENE_LABEL}（内存 ${MEM_MB}MB）" "$BUF_LBL" "$PROFILE"
}

# ── tc 限速菜单 ───────────────────────────────────────────
bbr_menu_tc() {
    print_header "限速设置（tc）"

    if is_openvz; then
        echo ""
        warn "检测到当前运行于 ${BOLD}OpenVZ 容器${NC} 中"
        warn "OpenVZ 共享内核，tc 流量控制通常被宿主机限制，无法正常使用"
        echo ""
        echo -e "  ${DIM}如需限速，请联系 VPS 提供商在宿主机层面配置${NC}"
        echo ""
        ui_pause
        return
    fi

    local DEV QDISCS ROOT_LINE
    DEV=$(default_iface)
    QDISCS=$(tc qdisc show dev "$DEV" 2>/dev/null || true)
    ROOT_LINE=$(bbr_tc_root_line "$QDISCS")
    local QTYPE; QTYPE=$(bbr_tc_qdisc_type "$ROOT_LINE")
    [ -z "$QTYPE" ] && QTYPE="未知"
    local CUR; CUR=$(bbr_tc_rate_display "$DEV" "$(command -v tc 2>/dev/null || echo /sbin/tc)")

    echo -e "  网卡：${BOLD}${DEV}${NC}  当前 qdisc：${BOLD}${QTYPE}${NC}  当前限速：${BOLD}${CUR}${NC}"
    echo ""
    menu_div
    menu_pair "1" "200 Mbps" "2" "500 Mbps"
    menu_pair "3" "780 Mbps" "4" "1 Gbps"
    menu_pair "5" "2 Gbps" "6" "自定义输入"
    menu_item "7" "取消限速" "$YELLOW"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择限速 [0-7]: ')" CH

    local RATE=0
    case "$CH" in
        1) RATE=200 ;;
        2) RATE=500 ;;
        3) RATE=780 ;;
        4) RATE=1024 ;;
        5) RATE=2048 ;;
        6)
            read -rp "  请输入限速值（Mbps）: " RATE
            if ! echo "$RATE" | grep -qE '^[0-9]+$' || [ "$RATE" -lt 1 ]; then
                error "无效数值"; return
            fi
            ;;
        7) RATE=0 ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    if [ "$RATE" -eq 0 ]; then
        local REMOVE_RC TC_BIN
        bbr_remove_tc
        REMOVE_RC=$?
        if [ "$REMOVE_RC" -eq 2 ]; then
            TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
            bbr_tc_remove_confirm "$DEV" "$TC_BIN" || return
            bbr_remove_tc 1
        elif [ "$REMOVE_RC" -ne 0 ]; then
            return "$REMOVE_RC"
        fi
    else
        local APPLY_RC TC_BIN
        bbr_apply_tc "$RATE"
        APPLY_RC=$?
        if [ "$APPLY_RC" -eq 2 ]; then
            TC_BIN=$(command -v tc 2>/dev/null || echo /sbin/tc)
            bbr_tc_force_confirm "$DEV" "$RATE" "$TC_BIN" || return
            bbr_apply_tc "$RATE" 1
        elif [ "$APPLY_RC" -ne 0 ]; then
            return "$APPLY_RC"
        fi
    fi
}

# ── initcwnd 菜单 ─────────────────────────────────────────
# 检测是否在 LXC 容器内

# 检测 OpenVZ / LXC 等受限容器
is_openvz() {
    [ -f /proc/vz/veinfo ] && return 0
    grep -qaE 'openvz|lxc' /proc/1/environ 2>/dev/null && return 0
    grep -qaE 'openvz|lxc' /proc/1/cgroup 2>/dev/null && return 0
    return 1
}

is_lxc() {
    grep -qa "lxc" /proc/1/environ 2>/dev/null     || [ -f /run/systemd/container ]     || grep -qa "container=lxc" /proc/1/environ 2>/dev/null     || { [ -f /proc/1/cgroup ] && grep -qa "lxc" /proc/1/cgroup 2>/dev/null; }
}

bbr_default_route_info() {
    local ROUTE
    ROUTE=$(ip -4 route show default 2>/dev/null | head -1)
    if [ -n "$ROUTE" ]; then
        printf '4|%s\n' "$ROUTE"
        return 0
    fi
    ROUTE=$(ip -6 route show default 2>/dev/null | head -1)
    [ -n "$ROUTE" ] || return 1
    printf '6|%s\n' "$ROUTE"
}

bbr_route_token() {
    local ROUTE="$1" TOKEN="$2"
    awk -v token="$TOKEN" '{ for (i=1; i<=NF; i++) if ($i == token) { print $(i+1); exit } }' <<< "$ROUTE"
}

bbr_route_strip_cwnd() {
    awk '
        {
            out=""
            for (i=1; i<=NF; i++) {
                if ($i == "initcwnd" || $i == "initrwnd") { i++; continue }
                out = out (out == "" ? "" : " ") $i
            }
            print out
        }
    ' <<< "$1"
}

bbr_apply_initcwnd_route() {
    local FAMILY="$1" ROUTE="$2" VAL="$3" BASE_ROUTE
    local -a ROUTE_ARGS
    BASE_ROUTE=$(bbr_route_strip_cwnd "$ROUTE")
    read -r -a ROUTE_ARGS <<< "$BASE_ROUTE"
    [ "${ROUTE_ARGS[0]:-}" = default ] || return 1
    ip "-${FAMILY}" route replace "${ROUTE_ARGS[@]}" initcwnd "$VAL" initrwnd "$VAL"
}

bbr_cwnd_write_persistence() {
    local FAMILY="$1" ROUTE="$2" VAL="$3" TMP
    [ -n "$ROUTE" ] || return 1
    mkdir -p "$(dirname "$CWND_HELPER")" "$(dirname "$CWND_STATE_FILE")" 2>/dev/null || return 1
    TMP=$(mktemp "${CWND_STATE_FILE}.tmp.XXXXXX") || return 1
    printf 'FAMILY=%s\nVALUE=%s\n' "$FAMILY" "$VAL" > "$TMP" || {
        rm -f "$TMP"
        return 1
    }
    chmod 600 "$TMP" && mv "$TMP" "$CWND_STATE_FILE" || { rm -f "$TMP"; return 1; }

    TMP=$(mktemp "${CWND_HELPER}.tmp.XXXXXX") || return 1
    cat > "$TMP" << 'CWND_HELPER_EOF'
#!/bin/sh
STATE=/var/lib/vps-tools/initcwnd.state
state_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STATE"; }
FAMILY=$(state_value FAMILY)
VALUE=$(state_value VALUE)
case "$FAMILY" in 4|6) : ;; *) exit 1 ;; esac
echo "$VALUE" | grep -qE '^[0-9]+$' || exit 1
case "${1:-apply}" in
    remove) exit 0 ;;
    status) ip "-${FAMILY}" route show default 2>/dev/null | grep -q "initcwnd ${VALUE}"; exit $? ;;
esac
ROUTE=$(ip "-${FAMILY}" route show default 2>/dev/null | head -1 | awk '
    {
        out=""
        for (i=1; i<=NF; i++) {
            if ($i == "initcwnd" || $i == "initrwnd") { i++; continue }
            out = out (out == "" ? "" : " ") $i
        }
        print out
    }
')
[ -n "$ROUTE" ] || exit 1
# ROUTE comes from iproute2 and is split back into individual route arguments.
# shellcheck disable=SC2086
set -- $ROUTE
[ "${1:-}" = default ] || exit 1
ip "-${FAMILY}" route replace "$@" initcwnd "$VALUE" initrwnd "$VALUE"
CWND_HELPER_EOF
    chmod 700 "$TMP" && mv "$TMP" "$CWND_HELPER" || { rm -f "$TMP"; return 1; }

    if systemd_available; then
        TMP=$(mktemp "${SERVICE_CWND}.tmp.XXXXXX") || return 1
        cat > "$TMP" << EOF
[Unit]
Description=VPS TOOLS TCP initcwnd
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${CWND_HELPER} apply
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
        mv "$TMP" "$SERVICE_CWND" || { rm -f "$TMP"; return 1; }
        systemctl daemon-reload >/dev/null 2>&1 \
            && systemctl enable initcwnd --quiet >/dev/null 2>&1 \
            && systemctl restart initcwnd >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 systemd 持久化失败"
                return 1
            }
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" openrc || return 1
        rc-update add initcwnd default >/dev/null 2>&1 \
            && rc-service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 OpenRC 持久化失败"
                return 1
            }
    elif command -v update-rc.d >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        bbr_write_init_script "$SERVICE_CWND_INIT" "$CWND_HELPER" sysv || return 1
        update-rc.d initcwnd defaults >/dev/null 2>&1 \
            && service initcwnd restart >/dev/null 2>&1 || {
                error "initcwnd 已立即生效，但 SysV 持久化失败"
                return 1
            }
    else
        error "initcwnd 已立即生效，但未检测到支持的服务管理器，无法设置开机恢复"
        return 1
    fi
}

bbr_menu_initcwnd() {
    print_header "initcwnd 设置"

    # ── LXC 检测 ───────────────────────────────────────────
    if is_lxc; then
        echo ""
        warn "检测到当前运行于 ${BOLD}LXC 容器${NC} 中"
        warn "LXC 容器没有独立网络命名空间权限，无法执行 ip route change"
        echo ""
        echo -e "  ${DIM}initcwnd 需要在宿主机或独立网络命名空间（如 KVM/独立VPS）中设置${NC}"
        echo -e "  ${DIM}如需设置，请在宿主机执行：${NC}"
        echo -e "  ${CYAN}  ip route change default initcwnd 50 initrwnd 50${NC}"
        echo ""
        return
    fi

    local ROUTE_INFO FAMILY ROUTE DEV GW
    ROUTE_INFO=$(bbr_default_route_info) || {
        error "未找到 IPv4 或 IPv6 默认路由"
        return 1
    }
    FAMILY=${ROUTE_INFO%%|*}
    ROUTE=${ROUTE_INFO#*|}
    DEV=$(bbr_route_token "$ROUTE" dev)
    GW=$(bbr_route_token "$ROUTE" via)
    [ -n "$DEV" ] || { error "默认路由缺少出口网卡"; return 1; }
    local CUR; CUR=$(bbr_route_token "$ROUTE" initcwnd)
    CUR="${CUR:-10（默认）}"

    echo -e "  协议：${BOLD}IPv${FAMILY}${NC}  网卡：${BOLD}${DEV}${NC}  网关：${BOLD}${GW:-直连}${NC}  当前 initcwnd：${BOLD}${CUR}${NC}"
    echo ""
    menu_div
    menu_item "1" "10 · 默认保守"
    menu_item "2" "50 · 跨国高延迟推荐"
    menu_item "3" "100 · 激进，可能丢包" "$YELLOW"
    menu_item "4" "自定义输入"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择 initcwnd [0-4]: ')" CH

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=50 ;;
        3) VAL=100 ;;
        4)
            read -rp "  请输入 initcwnd 值（1-1000）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -lt 1 ] || [ "$VAL" -gt 1000 ]; then
                error "无效数值"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    bbr_apply_initcwnd_route "$FAMILY" "$ROUTE" "$VAL" || {
        error "ip route change 失败"
        echo ""
        echo -e "  ${DIM}如果你在 LXC/OpenVZ 容器内，此操作会被宿主机拒绝，这是正常现象${NC}"
        return
    }

    bbr_cwnd_write_persistence "$FAMILY" "$ROUTE" "$VAL" || {
        error "initcwnd 已立即生效，但持久化配置未完成"
        return 1
    }
    info "initcwnd 已设置为 ${VAL}，重启后自动生效 ✓"
}

# ── BBR 主菜单 ────────────────────────────────────────────

# ── 一键 TCP 预设（三种场景）────────────────────────────
volcano_tcp_profile() {
    local PROFILE="${1:-balanced}"
    local RMEM WMEM NOTSENT SWAP LABEL BUF_MB MEM_MB BUFFER_CAP
    MEM_MB=$(bbr_physical_memory_mb)
    if [ "$MEM_MB" -le 0 ]; then
        warn "无法读取物理内存，按 512MB 保守计算"
        MEM_MB=512
    fi
    case "$PROFILE" in
        balanced)
            if [ "$MEM_MB" -lt 512 ]; then
                RMEM=16777216; BUF_MB=16
            elif [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432; BUF_MB=32
            else
                RMEM=67108864; BUF_MB=64
            fi
            NOTSENT=262144; SWAP=10
            LABEL="均衡跨境  — 网页/代理/日常综合（推荐）" ;;
        latency)
            RMEM=33554432; NOTSENT=131072; SWAP=10; BUF_MB=32
            LABEL="低延迟交互 — SSH/游戏/远程桌面/小包优先" ;;
        throughput)
            # 根据内存动态选缓冲区，万兆机器自动用大缓冲
            if [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;   BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728;  BUF_MB=128
            elif [ "$MEM_MB" -lt 8192 ]; then
                RMEM=268435456;  BUF_MB=256
            else
                RMEM=536870912;  BUF_MB=512
            fi
            NOTSENT=2097152; SWAP=5
            LABEL="高吞吐传输 — 大带宽/万兆/下载上传优先" ;;
        relay)
            # 中转机：两进两出，需要均衡缓冲+低延迟+大并发
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128
            else
                RMEM=268435456; BUF_MB=256
            fi
            NOTSENT=262144; SWAP=10
            LABEL="中转机 — 双向流量/大并发/均衡延迟与吞吐" ;;
        landing)
            # 落地机：流量主要是单向上行，跨境延迟高，需要大缓冲吃满带宽
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=67108864;   BUF_MB=64
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=134217728;  BUF_MB=128
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=268435456;  BUF_MB=256
            else
                RMEM=536870912;  BUF_MB=512
            fi
            NOTSENT=2097152; SWAP=5
            LABEL="落地机 — 跨境上行/大缓冲吃满带宽" ;;
        line_landing)
            # 线路落地机：直连用户/CN2/IPLC 线路，低延迟优先+中等吞吐
            if [ "$MEM_MB" -lt 1024 ]; then
                RMEM=33554432;  BUF_MB=32
            elif [ "$MEM_MB" -lt 2048 ]; then
                RMEM=67108864;  BUF_MB=64
            elif [ "$MEM_MB" -lt 4096 ]; then
                RMEM=134217728; BUF_MB=128
            else
                RMEM=268435456; BUF_MB=256
            fi
            NOTSENT=131072; SWAP=5
            LABEL="线路落地机 — CN2/IPLC/直连用户/低延迟优先" ;;
        *) error "未知预设：$PROFILE"; return 1 ;;
    esac

    WMEM=$RMEM
    BUFFER_CAP=$(bbr_buffer_cap_bytes "$MEM_MB") || return 1
    if [ "$RMEM" -gt "$BUFFER_CAP" ]; then
        warn "预设缓冲区 ${BUF_MB}MB 超过实际内存 ${MEM_MB}MB 的 25%，已自动降级"
        RMEM=$BUFFER_CAP
        WMEM=$BUFFER_CAP
        BUF_MB=$(( RMEM / 1048576 ))
    fi

    bbr_confirm_apply "$RMEM" "$WMEM" "$NOTSENT" "$SWAP" "$LABEL" "$BUF_MB" "$PROFILE"
}

# ── 智能 TCP 调优向导 ────────────────────────────────────
bbr_recommend_profile() {
    local MEM_MB="$1"
    if [ "$MEM_MB" -lt 768 ]; then
        echo latency
    elif [ "$MEM_MB" -lt 4096 ]; then
        echo balanced
    else
        echo throughput
    fi
}

bbr_smart_wizard() {
    print_header "智能 TCP 调优向导"
    local MEM_MB KERNEL CUR_CC
    MEM_MB=$(bbr_physical_memory_mb)
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CUR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")

    menu_group "当前环境"
    echo -e "  内存：${GREEN}${MEM_MB}MB${NC}  内核：${GREEN}${KERNEL}${NC}  拥塞控制：${GREEN}${CUR_CC}${NC}"
    echo ""
    menu_div
    menu_group "通用预设"
    menu_item "1" "均衡跨境  ${DIM}默认推荐${NC}"
    menu_item "2" "低延迟交互  ${DIM}SSH / 游戏 / 远程桌面${NC}"
    menu_item "3" "高吞吐传输  ${DIM}大带宽优先${NC}"
    echo ""
    menu_group "场景化预设"
    menu_item "4" "中转机  ${DIM}双向转发 / 大并发${NC}"
    menu_item "5" "落地机  ${DIM}跨境上行 / 大缓冲${NC}"
    menu_item "6" "线路落地机  ${DIM}低延迟优先${NC}"
    echo ""
    menu_item "7" "自动推荐  ${DIM}根据内存智能选择${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择预设 [0-7]: ')" CH

    local PROFILE=""
    case "$CH" in
        1) PROFILE="balanced" ;;
        2) PROFILE="latency" ;;
        3) PROFILE="throughput" ;;
        4) PROFILE="relay" ;;
        5) PROFILE="landing" ;;
        6) PROFILE="line_landing" ;;
        7)
            PROFILE=$(bbr_recommend_profile "$MEM_MB")
            case "$PROFILE" in
                latency) warn "小内存机器，推荐低延迟/轻量参数" ;;
                balanced) info "内存低于 4GB，推荐均衡模式" ;;
                throughput) info "内存达到 4GB，推荐高吞吐模式" ;;
            esac
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    volcano_tcp_profile "$PROFILE" || return 1
}


# ── 检测是否有 sysctl 写入权限 ───────────────────────────
has_sysctl_write() {
    local CUR
    CUR=$(sysctl -n net.ipv4.tcp_fin_timeout 2>/dev/null) || return 1
    [ -n "$CUR" ] || return 1
    # 写回原值来测试权限，避免探测动作改变系统 TCP 参数。
    sysctl -w "net.ipv4.tcp_fin_timeout=${CUR}" > /dev/null 2>&1 && return 0
    return 1
}

# ── 检测内核是否支持 BBR ─────────────────────────────────
bbr_check_kernel() {
    # 1. 检测内核版本 >= 4.9
    local KVER KMAJ KMIN
    KVER=$(uname -r 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+')
    KMAJ=$(echo "$KVER" | cut -d. -f1)
    KMIN=$(echo "$KVER" | cut -d. -f2)
    if [ "${KMAJ:-0}" -lt 4 ] || { [ "${KMAJ:-0}" -eq 4 ] && [ "${KMIN:-0}" -lt 9 ]; }; then
        error "内核版本 $(uname -r) 低于 4.9，不支持 BBR"
        echo -e "  ${DIM}Alpine: apk add linux-lts 或升级内核${NC}"
        return 1
    fi

    # 2. 检测 tcp_bbr 模块是否可用
    if lsmod 2>/dev/null | grep -q "tcp_bbr"; then
        return 0  # 已加载
    fi

    # 尝试加载模块
    if modprobe tcp_bbr 2>/dev/null; then
        info "tcp_bbr 模块已加载 ✓"
        return 0
    fi

    # Alpine 上安装/切换内核包通常需要重启，交给用户确认后再动系统包。
    if command -v apk &>/dev/null; then
        warn "tcp_bbr 模块未加载。Alpine 可能需要安装/切换内核包并重启。"
        read -rp "  尝试安装 linux-lts 或 linux-virt？(y/N，默认N): " APK_KERNEL
        [ -z "$APK_KERNEL" ] && APK_KERNEL="n"
        if echo "$APK_KERNEL" | grep -qiE '^y(es)?$'; then
            apk add --no-cache linux-lts 2>/dev/null || apk add --no-cache linux-virt 2>/dev/null || true
            modprobe tcp_bbr 2>/dev/null && { info "tcp_bbr 模块已加载 ✓"; return 0; }
            warn "内核包安装后通常需要 reboot 才会生效"
        fi
    fi

    # 检查 sysctl 是否已设置 bbr（有些内核内置不需要模块）
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
        return 0
    fi

    error "当前内核不支持 BBR（tcp_bbr 模块未找到）"
    echo -e "  ${DIM}Alpine 解决方案：${NC}"
    echo -e "  ${DIM}  apk add linux-lts && reboot${NC}"
    echo -e "  ${DIM}或检查：/proc/sys/net/ipv4/tcp_available_congestion_control${NC}"
    return 1
}

# 按 basename 屏蔽低优先级同名文件，再按文件名排序；也识别 /dev/null 掩码。
bbr_sysctl_sources() {
    local DIR FILE
    local -a DIRS
    IFS=: read -r -a DIRS <<< "$BBR_SYSCTL_DIRS"
    for DIR in "${DIRS[@]}"; do
        for FILE in "$DIR"/*.conf; do
            [ -e "$FILE" ] || [ -L "$FILE" ] || continue
            printf '%s\t%s\n' "${FILE##*/}" "$FILE"
        done
    done | awk -F '\t' '!seen[$1]++' | LC_ALL=C sort | cut -f2-
    [ ! -f "$BBR_SYSCTL_MAIN" ] || printf '%s\n' "$BBR_SYSCTL_MAIN"
    return 0
}

bbr_sysctl_conflicts() {
    local FILE RECORD LINE PATTERN VALUE KEY EXPECTED FOUND=0 CONFIG="" LABEL
    [ ! -f "$SYSCTL_FILE" ] || CONFIG=$(cat "$SYSCTL_FILE")
    while IFS= read -r FILE; do
        [ -f "$FILE" ] && [ -r "$FILE" ] || continue
        [ "$FILE" = "$SYSCTL_FILE" ] && continue
        [ ! "$FILE" -ef "$SYSCTL_FILE" ] || continue
        while IFS= read -r RECORD; do
            LINE=${RECORD%%$'\t'*}; RECORD=${RECORD#*$'\t'}
            PATTERN=${RECORD%%$'\t'*}; VALUE=${RECORD#*$'\t'}
            for KEY in $(bbr_config_keys "$CONFIG" | awk '!seen[$0]++'); do
                # shellcheck disable=SC2254 # sysctl 通配符用于匹配，不是字面量
                case "$KEY" in
                    $PATTERN)
                        EXPECTED=$(bbr_config_value "$CONFIG" "$KEY")
                        LABEL="不同值，可能覆盖"
                        [ "$(printf '%s\n' "$EXPECTED" | bbr_sysctl_normalize)" != "$(printf '%s\n' "$VALUE" | bbr_sysctl_normalize)" ] || LABEL="重复同值"
                        printf '  %s: %s = %s\n    来源: %s:%s（匹配 %s）\n' "$LABEL" "$KEY" "$VALUE" "$FILE" "$LINE" "$PATTERN"
                        FOUND=1
                        ;;
                esac
            done
        done < <(awk '
            /^[[:space:]]*[#;]/ || !/=/ {next}
            {key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key); sub(/^-/, "", key)
             gsub(/\//, ".", key); value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
             printf "%d\t%s\t%s\n", NR, key, value}
        ' "$FILE")
    done < <(bbr_sysctl_sources)
    [ "$FOUND" -ne 0 ] || echo "  未发现其他有效配置文件重复定义本工具的参数。"
    echo "  以上为冲突线索；通配符/发行版加载器可能影响最终结果。"
    echo "  procps sysctl --system 最后读取 sysctl.conf；systemd 取决于发行版是否链接该文件。"
}

bbr_sysctl_drift() {
    local CONFIG KEY EXPECTED ACTUAL FOUND=0
    [ -f "$SYSCTL_FILE" ] || { echo "  尚未保存本工具的 sysctl 配置。"; return 0; }
    CONFIG=$(cat "$SYSCTL_FILE")
    for KEY in $(bbr_config_keys "$CONFIG" | awk '!seen[$0]++'); do
        EXPECTED=$(bbr_config_value "$CONFIG" "$KEY")
        ACTUAL=$(sysctl -n "$KEY" 2>/dev/null || echo 不支持或不可读)
        if [ "$(printf '%s\n' "$EXPECTED" | bbr_sysctl_normalize)" != "$(printf '%s\n' "$ACTUAL" | bbr_sysctl_normalize)" ]; then
            printf '  %s: 已保存 %s / 当前 %s\n' "$KEY" "$EXPECTED" "$ACTUAL"
            FOUND=1
        fi
    done
    [ "$FOUND" -ne 0 ] || echo "  已保存参数与当前运行值一致。"
}

bbr_network_counters() {
    local FILE FOUND=0
    echo "  TCP 累计计数（当前网络命名空间；不是本次调优的增量）："
    for FILE in "$BBR_PROC_NET/snmp" "$BBR_PROC_NET/netstat"; do
        [ -r "$FILE" ] || continue
        awk '
            $1=="Tcp:" || $1=="TcpExt:" {
                if ($2 !~ /^[0-9-]+$/) { for(i=2;i<=NF;i++) names[$1,i]=$i; next }
                for(i=2;i<=NF;i++) {
                    name=names[$1,i]
                    if(name ~ /^(OutSegs|RetransSegs|TCPSynRetrans|TCPTimeouts|ListenOverflows|ListenDrops|TCPFastOpenActive|TCPFastOpenActiveFail|TCPFastOpenPassive|TCPFastOpenPassiveFail)$/)
                        printf "    %s: %s\n", name, $i
                }
            }
        ' "$FILE"
        FOUND=1
    done
    [ "$FOUND" -eq 1 ] || echo "    不可用（缺少 /proc/net 计数文件）"
    if [ -r "$BBR_PROC_NET/softnet_stat" ]; then
        awk '
            function hex(s, n,i) { n=0; s=tolower(s); for(i=1;i<=length(s);i++) n=n*16+index("0123456789abcdef",substr(s,i,1))-1; return n }
            NF>=3 {drops+=hex($2); squeezed+=hex($3); rows++}
            END {if(rows) printf "  softnet 累计: 接收队列丢包 %.0f / 轮询预算耗尽 %.0f\n", drops, squeezed}
        ' "$BBR_PROC_NET/softnet_stat"
        echo "  softnet 的可见范围随内核/容器变化；累计值不能直接归因于 BBR。"
    else
        echo "  softnet 计数不可用。"
    fi
}

bbr_diagnose() {
    print_header "BBR 诊断"
    local DEV TC_BIN KERNEL CC AVAIL QDISC RATE SYSCTL_WRITABLE SERVICE_STATE
    DEV=$(default_iface)
    TC_BIN=$(command -v tc 2>/dev/null || true)
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    AVAIL=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    RATE="未设置"

    if [ -n "$DEV" ] && [ -n "$TC_BIN" ]; then
        RATE=$(bbr_tc_rate_display "$DEV" "$TC_BIN")
    fi

    SYSCTL_WRITABLE="文件只读或不存在"
    [ ! -w "$(bbr_sysctl_path net.ipv4.tcp_congestion_control)" ] || SYSCTL_WRITABLE="文件权限可写（内核/容器仍可能限制）"

    SERVICE_STATE="未安装"
    if systemd_available && [ -f "$SERVICE_TC" ]; then
        SERVICE_STATE=$(systemctl is-enabled tc-fq 2>/dev/null || echo "已安装未启用")
    elif [ -f "$SERVICE_TC_INIT" ]; then
        if command -v rc-service >/dev/null 2>&1 && rc-service tc-fq status >/dev/null 2>&1; then
            SERVICE_STATE="已启用"
        else
            SERVICE_STATE="已安装未运行"
        fi
    fi

    echo -e "  内核版本: ${BOLD}${KERNEL}${NC}"
    echo -e "  默认网卡: ${BOLD}${DEV:-未知}${NC}"
    echo -e "  tc 命令: ${BOLD}${TC_BIN:-未安装}${NC}"
    echo -e "  拥塞算法: ${BOLD}${CC}${NC}"
    echo -e "  可用算法: ${BOLD}${AVAIL}${NC}"
    echo -e "  默认队列: ${BOLD}${QDISC}${NC}"
    echo -e "  tc 限速: ${BOLD}${RATE}${NC}"
    echo -e "  tc-fq 服务: ${BOLD}${SERVICE_STATE}${NC}"
    echo -e "  sysctl 可写: ${BOLD}${SYSCTL_WRITABLE}${NC}"

    [ "$CC" = "bbr" ] || warn "当前未启用 BBR 拥塞算法"
    echo "$AVAIL" | grep -qw bbr || warn "可用拥塞算法里没有 bbr，可能需要升级/切换内核"
    echo ""
    echo "  实际网卡队列（默认队列值不代表现有网卡已切换）："
    if [ -n "$DEV" ] && [ -n "$TC_BIN" ]; then
        "$TC_BIN" -s qdisc show dev "$DEV" 2>/dev/null || warn "无法读取实际队列"
    else
        echo "  不可用（缺少网卡或 tc）"
    fi
    echo "  fq 可提供 pacing；其他队列下现代内核可使用 TCP 内部 pacing。"
    echo ""
    bbr_tcp_status
    echo ""
    echo "  配置与运行值："
    bbr_sysctl_drift
    echo ""
    echo "  sysctl 配置来源："
    bbr_sysctl_conflicts
    echo ""
    bbr_network_counters
    if [ -f "$SYSCTL_FILE" ] && grep -q '^# skipped unsupported:' "$SYSCTL_FILE"; then
        warn "检测到不支持的 sysctl 参数已被注释："
        grep '^# skipped unsupported:' "$SYSCTL_FILE" | sed 's/^/    /'
    fi
}

bbr_menu() {
    # 进入时检测一次 sysctl 写入权限
    local _BBR_NO_SYSCTL=0
    if ! ensure_sysctl || ! has_sysctl_write; then
        _BBR_NO_SYSCTL=1
    fi
    [ ! -s "$TC_STATE_FILE" ] || bbr_tc_reconcile_saved || true
    while true; do
        print_header "BBR TCP 调优"
        bbr_print_status
        if [ "$_BBR_NO_SYSCTL" -eq 1 ]; then
            echo ""
            echo -e "  ${RED}${BOLD}⚠ 当前环境无 sysctl 写入权限${NC}"
            echo -e "  ${DIM}检测为无特权容器（unprivileged container）${NC}"
            echo -e "  ${DIM}sysctl 参数由宿主机控制，无法在容器内修改${NC}"
            echo -e "  ${DIM}请联系 VPS 提供商开启 sysctl 权限，或使用 KVM/独立VPS${NC}"
        fi
        echo ""
        menu_div
        menu_group "调优"
        menu_item "1" "智能向导  ${DIM}推荐${NC}"
        menu_pair "2" "自动配置" "3" "手动配置"
        menu_pair "4" "限速设置" "5" "initcwnd 设置"
        menu_item "9" "TCP 增强（TFO / ECN / MTU）"
        echo ""
        menu_group "维护"
        menu_pair "6" "备份 TCP 配置" "7" "还原 TCP 配置"
        menu_item "8" "BBR 诊断"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-9]: ')" CH

        case "$CH" in
            1) bbr_smart_wizard ;;
            2) bbr_menu_auto ;;
            3) bbr_menu_manual ;;
            4) bbr_menu_tc ;;
            5) bbr_menu_initcwnd ;;
            6) bbr_backup_sysctl ;;
            7) bbr_restore_sysctl ;;
            8) bbr_diagnose ;;
            9) bbr_tcp_menu ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}
