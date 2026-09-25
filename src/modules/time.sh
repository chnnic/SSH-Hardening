# ══════════════════════════════════════════════════════════
#  时间同步模块
# ══════════════════════════════════════════════════════════

TS_HTTPS_SERVICE_FILE="${TS_HTTPS_SERVICE_FILE:-/etc/systemd/system/vps-tools-https-time.service}"
TS_HTTPS_TIMER_FILE="${TS_HTTPS_TIMER_FILE:-/etc/systemd/system/vps-tools-https-time.timer}"
TS_HTTPS_INTERVAL_FILE="${TS_HTTPS_INTERVAL_FILE:-$VPS_DATA_DIR/https-time-sync.interval}"
TS_HTTPS_STATE_FILE="${TS_HTTPS_STATE_FILE:-$VPS_DATA_DIR/https-time-sync.state}"
TS_HTTPS_LOCK_FILE="${TS_HTTPS_LOCK_FILE:-$VPS_DATA_DIR/https-time-sync.lock}"
TS_HTTPS_CRON_MARKER="# VPS_TOOLS_HTTPS_TIME_SYNC"

timesync_menu() {
    while true; do
        print_header "时间同步 / 时区设置"

        # 当前状态
        local CUR_TZ CUR_TIME CUR_DATE NTP_STATUS HTTPS_STATUS
        CUR_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")
        CUR_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        CUR_DATE=$(date '+%Z %z')

        # NTP 状态
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            NTP_STATUS="${GREEN}已同步${NC}"
        elif command -v chronyc &>/dev/null && chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
            NTP_STATUS="${GREEN}已同步(chrony)${NC}"
        else
            NTP_STATUS="${YELLOW}未同步${NC}"
        fi
        HTTPS_STATUS=$(ts_https_schedule_summary)

        echo -e "  当前时区：${BOLD}${CUR_TZ}${NC}"
        echo -e "  当前时间：${BOLD}${CUR_TIME}${NC}  ${DIM}${CUR_DATE}${NC}"
        echo -e "  NTP状态 ：${NTP_STATUS}"
        echo -e "  HTTPS定时：${HTTPS_STATUS}"
        echo ""
        menu_div
        menu_item "1" "强制同步时间"
        menu_pair "2" "设置北京时区" "3" "同步并设为北京"
        menu_pair "4" "设置其他时区" "5" "开启 NTP 自动同步"
        menu_item "6" "立即 HTTPS 时间同步  ${DIM}UDP/123 受限时使用${NC}" "$CYAN"
        menu_item "7" "HTTPS 自动同步设置" "$GREEN"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-7]: ' || return 0

        case "$CH" in
            1) ts_sync_time ;;
            2) ts_set_beijing ;;
            3) ts_set_beijing; ts_sync_time ;;
            4) ts_set_custom_tz ;;
            5) ts_enable_ntp ;;
            6) ts_sync_https ;;
            7) ts_https_schedule_menu; continue ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}

ts_https_date_epoch() {
    local HTTP_DATE="$1" WEEKDAY DAY MONTH YEAR CLOCK ZONE EXTRA MONTH_NUM DAY_NUM ISO EPOCH
    read -r WEEKDAY DAY MONTH YEAR CLOCK ZONE EXTRA <<< "$HTTP_DATE"
    [ -n "$WEEKDAY" ] && [ -z "$EXTRA" ] || return 1
    case "$DAY" in ''|*[!0-9]*) return 1 ;; esac
    case "$YEAR" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#DAY}" -le 2 ] && [ "${#YEAR}" -eq 4 ] || return 1
    [ "${ZONE^^}" = "GMT" ] || return 1
    echo "$CLOCK" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$' || return 1
    case "$MONTH" in
        Jan) MONTH_NUM=1 ;; Feb) MONTH_NUM=2 ;; Mar) MONTH_NUM=3 ;; Apr) MONTH_NUM=4 ;;
        May) MONTH_NUM=5 ;; Jun) MONTH_NUM=6 ;; Jul) MONTH_NUM=7 ;; Aug) MONTH_NUM=8 ;;
        Sep) MONTH_NUM=9 ;; Oct) MONTH_NUM=10 ;; Nov) MONTH_NUM=11 ;; Dec) MONTH_NUM=12 ;;
        *) return 1 ;;
    esac
    DAY_NUM=$((10#$DAY))
    [ "$DAY_NUM" -ge 1 ] && [ "$DAY_NUM" -le 31 ] || return 1
    printf -v ISO '%04d-%02d-%02d %s' "$YEAR" "$MONTH_NUM" "$DAY_NUM" "$CLOCK"
    EPOCH=$(date -u -d "$ISO" '+%s' 2>/dev/null || true)
    if ! echo "$EPOCH" | grep -qE '^[0-9]+$' && command -v python3 >/dev/null 2>&1; then
        EPOCH=$(python3 - "$ISO" <<'PYEOF'
from datetime import datetime, timezone
import sys

try:
    parsed = datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
except ValueError:
    raise SystemExit(1)
print(int(parsed.timestamp()))
PYEOF
        ) || return 1
    fi
    echo "$EPOCH" | grep -qE '^[0-9]+$' || return 1
    printf '%s\n' "$EPOCH"
}

ts_epoch_utc() {
    local EPOCH="$1" RESULT
    echo "$EPOCH" | grep -qE '^[0-9]+$' || return 1
    RESULT=$(date -u -d "@$EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
    if [ -z "$RESULT" ] && command -v python3 >/dev/null 2>&1; then
        RESULT=$(python3 - "$EPOCH" <<'PYEOF'
from datetime import datetime, timezone
import sys

print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))
PYEOF
        ) || return 1
    fi
    [ -n "$RESULT" ] || return 1
    printf '%s\n' "$RESULT"
}

ts_https_fetch_epoch() {
    local URL="$1" HEADERS HTTP_DATE
    HEADERS=$(curl --proto '=https' -sS -I --connect-timeout 5 --max-time 8 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$URL" 2>/dev/null) || return 1
    HTTP_DATE=$(printf '%s\n' "$HEADERS" | awk '
        tolower($0) ~ /^date:[[:space:]]/ {
            sub(/^[^:]*:[[:space:]]*/, "")
            sub(/\r$/, "")
            value=$0
        }
        END { if (value != "") print value }
    ')
    [ -n "$HTTP_DATE" ] || return 1
    ts_https_date_epoch "$HTTP_DATE"
}

ts_https_consensus() {
    local MAX_SKEW="${TS_HTTPS_MAX_SKEW:-10}" VALUE I J COUNT BEST_START=0 BEST_COUNT=0
    local FIRST LAST MID TARGET SPREAD
    local VALUES=()
    case "$MAX_SKEW" in ''|*[!0-9]*) MAX_SKEW=10 ;; esac
    [ "$MAX_SKEW" -ge 1 ] || MAX_SKEW=10
    for VALUE in "$@"; do
        echo "$VALUE" | grep -qE '^[0-9]+$' && VALUES+=("$VALUE")
    done
    [ "${#VALUES[@]}" -ge 2 ] || return 1
    mapfile -t VALUES < <(printf '%s\n' "${VALUES[@]}" | sort -n)

    for ((I=0; I<${#VALUES[@]}; I++)); do
        COUNT=0
        for ((J=I; J<${#VALUES[@]}; J++)); do
            [ $((VALUES[J] - VALUES[I])) -le "$MAX_SKEW" ] || break
            COUNT=$((COUNT + 1))
        done
        if [ "$COUNT" -gt "$BEST_COUNT" ]; then
            BEST_START=$I
            BEST_COUNT=$COUNT
        fi
    done
    [ "$BEST_COUNT" -ge 2 ] || return 1

    FIRST=${VALUES[BEST_START]}
    LAST=${VALUES[$((BEST_START + BEST_COUNT - 1))]}
    MID=$((BEST_START + BEST_COUNT / 2))
    if [ $((BEST_COUNT % 2)) -eq 0 ]; then
        TARGET=$(( (VALUES[MID - 1] + VALUES[MID]) / 2 ))
    else
        TARGET=${VALUES[MID]}
    fi
    SPREAD=$((LAST - FIRST))
    printf '%s %s %s\n' "$TARGET" "$BEST_COUNT" "$SPREAD"
}

ts_sync_https() {
    local MODE="${1:-standalone}" SOURCE LABEL URL EPOCH LOCAL_SAMPLE REFERENCE_LOCAL
    local CONSENSUS COUNT SPREAD TARGET_UTC BEFORE AFTER DRIFT ABS_DRIFT I
    local SOURCES=(
        'Cloudflare|https://www.cloudflare.com/'
        'Aliyun|https://www.aliyun.com/'
        'Microsoft|https://www.microsoft.com/'
        'GitHub|https://github.com/'
        'Google|https://www.google.com/generate_204'
    )
    local SAMPLE_EPOCHS=() SAMPLE_LOCALS=() ADJUSTED=()

    [ "$MODE" = standalone ] && print_header "HTTPS 时间同步"
    echo -e "  ${DIM}通过 TCP/443 获取多个 HTTPS Date 响应并校验时间共识${NC}"
    echo -e "  ${DIM}证书验证保持开启；至少两个来源需在 10 秒内一致${NC}"
    echo ""

    if ! command -v curl >/dev/null 2>&1; then
        error "缺少 curl，无法执行 HTTPS 时间同步"
        return 1
    fi

    for SOURCE in "${SOURCES[@]}"; do
        LABEL=${SOURCE%%|*}
        URL=${SOURCE#*|}
        if EPOCH=$(ts_https_fetch_epoch "$URL") \
            && echo "$EPOCH" | grep -qE '^[0-9]+$' \
            && [ "$EPOCH" -ge 1577836800 ] && [ "$EPOCH" -le 4102444799 ]; then
            LOCAL_SAMPLE=$(date '+%s')
            SAMPLE_EPOCHS+=("$EPOCH")
            SAMPLE_LOCALS+=("$LOCAL_SAMPLE")
            info "$LABEL：$(ts_epoch_utc "$EPOCH") UTC"
            [ "${#SAMPLE_EPOCHS[@]}" -ge 3 ] && break
        else
            warn "$LABEL：无法获取有效 HTTPS 时间"
        fi
    done

    if [ "${#SAMPLE_EPOCHS[@]}" -lt 2 ]; then
        error "有效 HTTPS 时间来源不足，至少需要 2 个"
        warn "若系统时间偏差过大，TLS 证书也可能无法验证；请先通过 VPS 控制台粗略校时"
        return 1
    fi

    REFERENCE_LOCAL=$(date '+%s')
    for ((I=0; I<${#SAMPLE_EPOCHS[@]}; I++)); do
        ADJUSTED+=("$((SAMPLE_EPOCHS[I] + REFERENCE_LOCAL - SAMPLE_LOCALS[I]))")
    done
    CONSENSUS=$(ts_https_consensus "${ADJUSTED[@]}") || {
        error "HTTPS 来源时间差异超过 10 秒，已拒绝修改系统时间"
        return 1
    }
    read -r EPOCH COUNT SPREAD <<< "$CONSENSUS"
    TARGET_UTC=$(ts_epoch_utc "$EPOCH") || { error "无法转换 HTTPS 时间"; return 1; }
    BEFORE=$(date '+%s')
    DRIFT=$((EPOCH - BEFORE))

    menu_div
    echo -e "  共识来源：${BOLD}${COUNT}${NC}  最大差异：${BOLD}${SPREAD} 秒${NC}"
    echo -e "  目标时间：${BOLD}${TARGET_UTC} UTC${NC}"
    echo -e "  本机偏差：${BOLD}${DRIFT} 秒${NC}"
    menu_div
    echo ""

    if ! date -u -s "$TARGET_UTC" >/dev/null 2>&1; then
        error "设置系统时间失败，当前环境可能缺少改时权限"
        return 1
    fi
    command -v hwclock >/dev/null 2>&1 && hwclock --systohc >/dev/null 2>&1 || true
    AFTER=$(date '+%s')
    ABS_DRIFT=$((AFTER - EPOCH)); ABS_DRIFT=${ABS_DRIFT#-}
    if [ "$ABS_DRIFT" -gt 5 ]; then
        error "设置后的系统时间校验失败，偏差 ${ABS_DRIFT} 秒"
        return 1
    fi

    info "HTTPS 时间同步成功 ✓"
    [ "$MODE" = fallback ] || info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    [ "$MODE" = scheduled ] || info "可在时间菜单启用 HTTPS 自动同步"
    audit_action "HTTPS时间同步，${COUNT}个来源共识，偏差${DRIFT}秒" SUCCESS
    return 0
}

ts_https_interval_normalize() {
    case "${1:-}" in
        1|3|6|12|24) printf '%s\n' "$1" ;;
        *) return 1 ;;
    esac
}

ts_https_interval_current() {
    local VALUE
    VALUE=$(awk 'NR == 1 { print $1 }' "$TS_HTTPS_INTERVAL_FILE" 2>/dev/null || true)
    ts_https_interval_normalize "$VALUE" 2>/dev/null || printf '6\n'
}

ts_https_cron_expr() {
    local INTERVAL
    INTERVAL=$(ts_https_interval_normalize "$1") || return 1
    case "$INTERVAL" in
        1) printf '17 * * * *\n' ;;
        3) printf '17 */3 * * *\n' ;;
        6) printf '17 */6 * * *\n' ;;
        12) printf '17 */12 * * *\n' ;;
        24) printf '17 3 * * *\n' ;;
    esac
}

ts_https_cron_without_managed() {
    grep -Fv -- "$TS_HTTPS_CRON_MARKER"
}

ts_https_schedule_backend() {
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet "$(basename "$TS_HTTPS_TIMER_FILE")" 2>/dev/null; then
        printf 'systemd\n'
        return 0
    fi
    if command -v crontab >/dev/null 2>&1 \
        && crontab -l 2>/dev/null | grep -Fq -- "$TS_HTTPS_CRON_MARKER"; then
        printf 'cron\n'
        return 0
    fi
    return 1
}

ts_https_schedule_last_result() {
    [ -s "$TS_HTTPS_STATE_FILE" ] || return 1
    awk -F '\t' 'NR == 1 && NF >= 3 { printf "%s %s（%s）", $1, $2, $3 }' "$TS_HTTPS_STATE_FILE"
}

ts_https_schedule_summary() {
    local BACKEND INTERVAL
    BACKEND=$(ts_https_schedule_backend 2>/dev/null || true)
    [ -n "$BACKEND" ] || { printf '%s未启用%s' "$DIM" "$NC"; return; }
    INTERVAL=$(ts_https_interval_current)
    printf '%s每 %s 小时（%s）%s' "$GREEN" "$INTERVAL" "$BACKEND" "$NC"
}

ts_https_runner_valid() {
    self_script_valid "$LOCAL_SCRIPT" \
        && grep -qF -- '--https-time-sync-run)' "$LOCAL_SCRIPT" 2>/dev/null
}

ts_https_runner_path_valid() {
    case "$LOCAL_SCRIPT" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$LOCAL_SCRIPT" in
        *[!A-Za-z0-9_./-]*) return 1 ;;
    esac
}

ts_https_ensure_runner() {
    local SOURCE
    ts_https_runner_path_valid || { error "本地脚本路径包含定时任务不支持的字符"; return 1; }
    ts_https_runner_valid && return 0
    SOURCE=$(self_resolve_script_source "$0" 2>/dev/null || true)
    if [ -n "$SOURCE" ]; then
        self_atomic_replace "$SOURCE" "$LOCAL_SCRIPT" || { error "无法安装 HTTPS 定时任务执行脚本"; return 1; }
        chmod 755 "$LOCAL_SCRIPT" 2>/dev/null || true
    else
        info "定时任务需要本地完整脚本，正在安装..."
        self_install || return 1
    fi
    ts_https_runner_valid || { error "本地脚本缺少 HTTPS 定时任务入口"; return 1; }
}

ts_https_scheduled_run() {
    local OUTPUT STATUS RC STATE_TMP LOCK_DIR="" LOCK_PID=""
    mkdir -p "$VPS_DATA_DIR" 2>/dev/null || return 1
    chmod 700 "$VPS_DATA_DIR" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$TS_HTTPS_LOCK_FILE"
        flock -n 9 || return 0
    else
        LOCK_DIR="${TS_HTTPS_LOCK_FILE}.d"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
            if echo "$LOCK_PID" | grep -qE '^[0-9]+$' && ! kill -0 "$LOCK_PID" 2>/dev/null; then
                rm -rf "$LOCK_DIR"
                mkdir "$LOCK_DIR" 2>/dev/null || return 0
            else
                return 0
            fi
        fi
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
    fi
    if OUTPUT=$(ts_sync_https scheduled 2>&1); then
        STATUS=成功
        RC=0
    else
        STATUS=失败
        RC=1
    fi
    STATE_TMP="${TS_HTTPS_STATE_FILE}.tmp.$$"
    if printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$STATUS" "HTTPS" > "$STATE_TMP"; then
        chmod 600 "$STATE_TMP" 2>/dev/null || true
        mv -f "$STATE_TMP" "$TS_HTTPS_STATE_FILE" || true
    fi
    if command -v logger >/dev/null 2>&1; then
        printf '%s\n' "$OUTPUT" | logger -t vps-tools-https-time
    fi
    if [ "$RC" -eq 0 ]; then
        audit_action "HTTPS定时同步成功" SUCCESS
    else
        audit_action "HTTPS定时同步失败" FAILED
    fi
    [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
    return "$RC"
}

ts_https_schedule_enable_systemd() {
    local INTERVAL="$1" SERVICE_TMP TIMER_TMP
    SERVICE_TMP="${TS_HTTPS_SERVICE_FILE}.tmp.$$"
    TIMER_TMP="${TS_HTTPS_TIMER_FILE}.tmp.$$"
    cat > "$SERVICE_TMP" <<EOF
[Unit]
Description=VPS Tools HTTPS time synchronization
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$LOCAL_SCRIPT --https-time-sync-run
TimeoutStartSec=60
EOF
    cat > "$TIMER_TMP" <<EOF
[Unit]
Description=Run VPS Tools HTTPS time synchronization every ${INTERVAL} hours

[Timer]
OnActiveSec=1min
OnUnitActiveSec=${INTERVAL}h
AccuracySec=1min
RandomizedDelaySec=2min
Persistent=true
Unit=$(basename "$TS_HTTPS_SERVICE_FILE")

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$SERVICE_TMP" "$TIMER_TMP"
    mv -f "$SERVICE_TMP" "$TS_HTTPS_SERVICE_FILE" \
        && mv -f "$TIMER_TMP" "$TS_HTTPS_TIMER_FILE" \
        || { rm -f "$SERVICE_TMP" "$TIMER_TMP"; return 1; }
    if ! systemctl daemon-reload >/dev/null 2>&1 \
        || ! systemctl enable "$(basename "$TS_HTTPS_TIMER_FILE")" >/dev/null 2>&1 \
        || ! systemctl restart "$(basename "$TS_HTTPS_TIMER_FILE")" >/dev/null 2>&1; then
        systemctl disable --now "$(basename "$TS_HTTPS_TIMER_FILE")" >/dev/null 2>&1 || true
        rm -f "$TS_HTTPS_SERVICE_FILE" "$TS_HTTPS_TIMER_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        return 1
    fi
}

ts_https_schedule_enable_cron() {
    local INTERVAL="$1" EXPR CURRENT CRON_TMP
    command -v crontab >/dev/null 2>&1 || return 1
    EXPR=$(ts_https_cron_expr "$INTERVAL") || return 1
    CURRENT=$(crontab -l 2>/dev/null || true)
    CRON_TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-time-cron.XXXXXX") || return 1
    {
        printf '%s\n' "$CURRENT" | ts_https_cron_without_managed || true
        printf '%s %s --https-time-sync-run >/dev/null 2>&1 %s\n' "$EXPR" "$LOCAL_SCRIPT" "$TS_HTTPS_CRON_MARKER"
    } | awk 'NF' > "$CRON_TMP"
    if ! crontab "$CRON_TMP"; then
        rm -f "$CRON_TMP"
        return 1
    fi
    rm -f "$CRON_TMP"
    if ! ts_https_cron_daemon_enable; then
        ts_https_schedule_remove_cron || true
        return 1
    fi
}

ts_https_cron_daemon_enable() {
    local SERVICE
    for SERVICE in cron crond; do
        svc_is_active "$SERVICE" 2>/dev/null && return 0
    done
    for SERVICE in cron crond; do
        if [ -x "/etc/init.d/$SERVICE" ]; then
            "/etc/init.d/$SERVICE" enable >/dev/null 2>&1 || true
            "/etc/init.d/$SERVICE" start >/dev/null 2>&1 && return 0
        fi
        svc_enable "$SERVICE" >/dev/null 2>&1 || true
        svc_start "$SERVICE" >/dev/null 2>&1 && return 0
    done
    command -v pgrep >/dev/null 2>&1 \
        && { pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; }
}

ts_https_schedule_remove_cron() {
    local CURRENT CRON_TMP
    command -v crontab >/dev/null 2>&1 || return 0
    CURRENT=$(crontab -l 2>/dev/null || true)
    printf '%s\n' "$CURRENT" | grep -Fq -- "$TS_HTTPS_CRON_MARKER" || return 0
    CRON_TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-time-cron.XXXXXX") || return 1
    printf '%s\n' "$CURRENT" | ts_https_cron_without_managed | awk 'NF' > "$CRON_TMP" || true
    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"
}

ts_https_schedule_enable() {
    local INTERVAL BACKEND
    INTERVAL=$(ts_https_interval_normalize "$1") || { error "不支持的同步周期"; return 1; }
    ts_https_ensure_runner || return 1
    mkdir -p "$(dirname "$TS_HTTPS_INTERVAL_FILE")" || return 1

    if systemd_available && command -v systemctl >/dev/null 2>&1; then
        ts_https_schedule_remove_cron || true
        if ! ts_https_schedule_enable_systemd "$INTERVAL"; then
            error "systemd timer 创建失败"
            return 1
        fi
        BACKEND=systemd
    else
        if ! ts_https_schedule_enable_cron "$INTERVAL"; then
            error "系统缺少可用的 systemd timer 或 crontab"
            return 1
        fi
        BACKEND=cron
    fi
    printf '%s\n' "$INTERVAL" > "$TS_HTTPS_INTERVAL_FILE"
    chmod 600 "$TS_HTTPS_INTERVAL_FILE" 2>/dev/null || true
    info "HTTPS 自动同步已启用：每 ${INTERVAL} 小时（${BACKEND}）"
    audit_action "启用HTTPS定时同步，每${INTERVAL}小时，${BACKEND}" SUCCESS
    if ts_https_scheduled_run; then
        info "首次 HTTPS 时间同步成功"
    else
        warn "定时任务已启用，但首次同步失败；系统将在下一周期重试"
    fi
}

ts_https_schedule_disable() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$(basename "$TS_HTTPS_TIMER_FILE")" >/dev/null 2>&1 || true
        systemctl stop "$(basename "$TS_HTTPS_SERVICE_FILE")" >/dev/null 2>&1 || true
    fi
    rm -f "$TS_HTTPS_TIMER_FILE" "$TS_HTTPS_SERVICE_FILE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    ts_https_schedule_remove_cron || true
    rm -f "$TS_HTTPS_INTERVAL_FILE"
    info "HTTPS 自动同步已关闭"
    audit_action "关闭HTTPS定时同步" SUCCESS
}

ts_https_schedule_menu() {
    while true; do
        local BACKEND INTERVAL LAST CH
        BACKEND=$(ts_https_schedule_backend 2>/dev/null || true)
        INTERVAL=$(ts_https_interval_current)
        LAST=$(ts_https_schedule_last_result 2>/dev/null || true)
        print_header "HTTPS 自动同步"
        if [ -n "$BACKEND" ]; then
            echo -e "  状态：${GREEN}${BOLD}运行中${NC}  每 ${BOLD}${INTERVAL}${NC} 小时  ${DIM}${BACKEND}${NC}"
        else
            echo -e "  状态：${DIM}未启用${NC}"
        fi
        echo -e "  最近：${BOLD}${LAST:-暂无执行记录}${NC}"
        echo ""
        menu_div
        menu_pair "1" "每 1 小时" "2" "每 3 小时"
        menu_pair "3" "每 6 小时  推荐" "4" "每 12 小时" "$GREEN" "$CYAN"
        menu_pair "5" "每 24 小时" "6" "立即同步"
        menu_item "7" "关闭 HTTPS 自动同步" "$RED"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-7]: ' || return 0
        case "$CH" in
            1) ts_https_schedule_enable 1 ;;
            2) ts_https_schedule_enable 3 ;;
            3) ts_https_schedule_enable 6 ;;
            4) ts_https_schedule_enable 12 ;;
            5) ts_https_schedule_enable 24 ;;
            6) ts_sync_https ;;
            7) ts_https_schedule_disable ;;
            0) return ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac
        ui_pause
    done
}

# ── 强制同步时间 ──────────────────────────────────────────
ts_sync_time() {
    print_header "强制同步系统时间"
    echo -e "  ${DIM}尝试多种方式同步时间...${NC}"
    echo ""

    local SYNCED=false

    # 方法1：timedatectl + systemd-timesyncd
    if command -v timedatectl &>/dev/null && systemd_available; then
        info "尝试 systemd-timesyncd..."
        timedatectl set-ntp true 2>/dev/null
        # 重启 timesyncd 强制立即同步
        systemctl restart systemd-timesyncd 2>/dev/null
        sleep 2
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            info "systemd-timesyncd 同步成功 ✓"
            SYNCED=true
        fi
    fi

    # 方法2：chrony
    if [ "$SYNCED" = false ] && command -v chronyc &>/dev/null; then
        info "尝试 chrony..."
        systemctl restart chronyd 2>/dev/null || rc-service chronyd restart 2>/dev/null || true
        sleep 1
        chronyc makestep 2>/dev/null && info "chrony 强制同步成功 ✓" && SYNCED=true
    fi

    # 方法3：ntpdate（直连 NTP 服务器）
    if [ "$SYNCED" = false ]; then
        local NTP_SERVERS="ntp.aliyun.com time.cloudflare.com pool.ntp.org time.google.com"
        if command -v ntpdate &>/dev/null; then
            info "尝试 ntpdate..."
            for srv in $NTP_SERVERS; do
                if ntpdate -u "$srv" &>/dev/null; then
                    info "ntpdate 同步成功（$srv）✓"
                    SYNCED=true
                    break
                fi
            done
        else
            # 安装 ntpdate 再同步
            info "ntpdate 未安装，尝试安装..."
            pkg_install ntpdate &>/dev/null
            if command -v ntpdate &>/dev/null; then
                for srv in $NTP_SERVERS; do
                    if ntpdate -u "$srv" &>/dev/null; then
                        info "ntpdate 同步成功（$srv）✓"
                        SYNCED=true
                        break
                    fi
                done
            fi
        fi
    fi

    # 方法4：通过多个 HTTPS Date 响应建立共识，适用于 UDP/123 被封锁
    if [ "$SYNCED" = false ]; then
        info "尝试 HTTPS 多来源时间同步..."
        ts_sync_https fallback && SYNCED=true
    fi

    echo ""
    if [ "$SYNCED" = true ]; then
        info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    else
        error "自动同步失败，请检查网络连接"
        echo -e "  ${DIM}可返回时间菜单选择 6，单独诊断 HTTPS 时间同步${NC}"
    fi
}

# ── 设置北京时区 ──────────────────────────────────────────
ts_set_beijing() {
    print_header "设置北京时区"
    info "设置时区为 Asia/Shanghai（北京 UTC+8）..."

    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null && info "时区已设置 ✓"
    elif [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
        info "时区已设置 ✓"
    else
        error "找不到时区文件，尝试安装 tzdata..."
        pkg_install tzdata &>/dev/null
        if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
            ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
            echo "Asia/Shanghai" > /etc/timezone
            info "时区已设置 ✓"
        else
            error "设置失败，请手动执行：timedatectl set-timezone Asia/Shanghai"
            return
        fi
    fi

    echo ""
    info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
}

# ── 设置自定义时区 ────────────────────────────────────────
ts_set_custom_tz() {
    print_header "设置自定义时区"
    echo -e "  常用时区参考："
    echo -e "  ${GREEN}Asia/Shanghai${NC}       北京 UTC+8"
    echo -e "  ${GREEN}Asia/Tokyo${NC}          东京 UTC+9"
    echo -e "  ${GREEN}America/New_York${NC}    纽约 UTC-5"
    echo -e "  ${GREEN}America/Los_Angeles${NC} 洛杉矶 UTC-8"
    echo -e "  ${GREEN}Europe/London${NC}       伦敦 UTC+0"
    echo -e "  ${GREEN}Europe/Paris${NC}        巴黎 UTC+1"
    echo ""
    read -rp "  请输入时区名称（直接回车取消）: " TZ_INPUT
    [ -z "$TZ_INPUT" ] && { warn "已取消"; return; }

    if [ ! -f "/usr/share/zoneinfo/${TZ_INPUT}" ]; then
        error "时区 '${TZ_INPUT}' 不存在，请检查拼写"
        return
    fi

    if command -v timedatectl &>/dev/null; then
        timedatectl set-timezone "$TZ_INPUT" 2>/dev/null && info "时区已设置为 ${TZ_INPUT} ✓"
    else
        ln -sf "/usr/share/zoneinfo/${TZ_INPUT}" /etc/localtime
        echo "$TZ_INPUT" > /etc/timezone
        info "时区已设置为 ${TZ_INPUT} ✓"
    fi

    echo ""
    info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z %z')"
}

# ── 开启 NTP 自动同步 ─────────────────────────────────────
ts_enable_ntp() {
    print_header "开启 NTP 自动同步"

    # 检测 CanNTP — 判断是否有 timesyncd
    local CAN_NTP
    CAN_NTP=$(timedatectl show --property=CanNTP --value 2>/dev/null || echo "no")

    if [ "$CAN_NTP" = "yes" ] && command -v systemctl &>/dev/null \
        && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
        # systemd-timesyncd 可用
        timedatectl set-ntp true 2>/dev/null || { error "无法启用系统 NTP"; return 1; }
        systemctl enable systemd-timesyncd --quiet 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || { error "systemd-timesyncd 启动失败"; return 1; }
        systemctl is-active --quiet systemd-timesyncd 2>/dev/null || { error "systemd-timesyncd 未运行"; return 1; }
        info "systemd-timesyncd NTP 已开启 ✓"
    elif command -v chronyc &>/dev/null; then
        # chrony 已安装，自动探测服务名
        local CHRONY_SVC="chronyd"
        systemctl list-unit-files 2>/dev/null | grep -q "^chrony.service" && CHRONY_SVC="chrony"
        svc_enable "$CHRONY_SVC"
        svc_start "$CHRONY_SVC" || { error "chrony 启动失败"; return 1; }
        sleep 1
        chronyc makestep &>/dev/null && info "chrony 强制同步 ✓"
        info "chrony NTP 自动同步已开启 ✓"
    else
        # 都没有，安装 chrony
        info "正在安装 chrony..."
        if pkg_install chrony; then
            # Debian 服务名是 chrony，CentOS/Alpine 是 chronyd
            local CHRONY_SVC="chronyd"
            systemctl list-unit-files 2>/dev/null | grep -q "^chrony.service" && CHRONY_SVC="chrony"
            svc_enable "$CHRONY_SVC"
            svc_start "$CHRONY_SVC" || { error "chrony 启动失败"; return 1; }
            sleep 2
            chronyc makestep &>/dev/null && info "chrony 强制同步 ✓"
            info "chrony 已安装并开启自动同步 ✓"
        else
            error "chrony 安装失败，请手动执行：apt-get install -y chrony"
            return
        fi
    fi

    echo ""
    sleep 2
    # 验证同步状态
    local SYNC_ST
    SYNC_ST=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
    if [ "$SYNC_ST" = "yes" ]; then
        info "NTP 状态：已同步 ✓"
        info "当前时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
    else
        warn "NTP 状态：同步中（chrony 可能需要几秒完成首次同步）"
        # 尝试 chrony 状态
        if command -v chronyc &>/dev/null; then
            chronyc tracking 2>/dev/null | grep -E "Reference|System time|Last offset" | while IFS= read -r l; do
                echo -e "  ${DIM}$l${NC}"
            done
        fi
    fi
}
