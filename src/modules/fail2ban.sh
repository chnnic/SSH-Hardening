# ══════════════════════════════════════════════════════════
#  Fail2ban 模块
# ══════════════════════════════════════════════════════════
# 把 fail2ban 时间格式转为秒（支持 3600、1h、1d、-1 等）
f2b_to_seconds() {
    local VAL="$1"
    # 纯数字直接返回
    if echo "$VAL" | grep -qE '^-?[0-9]+$'; then
        echo "$VAL"; return
    fi
    # 解析带单位：s/m/h/d/w
    local NUM; NUM=$(echo "$VAL" | grep -oE '[0-9]+')
    local UNIT; UNIT=$(echo "$VAL" | grep -oE '[smhdw]' | tail -1)
    case "$UNIT" in
        s) echo "$NUM" ;;
        m) echo $(( NUM * 60 )) ;;
        h) echo $(( NUM * 3600 )) ;;
        d) echo $(( NUM * 86400 )) ;;
        w) echo $(( NUM * 604800 )) ;;
        *) echo "$NUM" ;;
    esac
}

# 把秒数转为可读字符串
f2b_seconds_to_human() {
    local SEC="$1"
    [ "$SEC" = "-1" ] && { echo "永久"; return; }
    [ "$SEC" -ge 86400 ] && { echo "$(( SEC / 86400 ))天"; return; }
    [ "$SEC" -ge 3600  ] && { echo "$(( SEC / 3600 ))小时"; return; }
    [ "$SEC" -ge 60    ] && { echo "$(( SEC / 60 ))分钟"; return; }
    echo "${SEC}秒"
}


# 检测 fail2ban 是否已安装并运行
# fail2ban-client ping 兼容函数（自动探测 socket 路径）
f2b_ping() {
    local SOCK
    for SOCK in /run/fail2ban/fail2ban.sock \
                /var/run/fail2ban/fail2ban.sock \
                /tmp/fail2ban.sock; do
        [ -S "$SOCK" ] && fail2ban-client -s "$SOCK" ping &>/dev/null 2>&1 && return 0
    done
    fail2ban-client ping &>/dev/null 2>&1
}

f2b_status() {
    if ! command -v fail2ban-client &>/dev/null; then
        echo "not_installed"
        return
    fi
    # 先用 fail2ban-client ping 检测实际运行状态（最可靠）
    if f2b_ping; then
        echo "running"
    elif svc_is_active fail2ban 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# 安装 fail2ban
f2b_install() {
    print_header "安装 Fail2ban"
    info "正在安装 fail2ban..."
    if ! pkg_install fail2ban; then
        error "安装失败，请检查网络或手动安装：apt install fail2ban"
        return 1
    fi

    # ── 1. 确定 backend ──────────────────────────────────────
    local BACKEND="auto"

    # 检测 python3-systemd 是否可用
    if python3 -c "import systemd.journal" &>/dev/null 2>&1; then
        BACKEND="systemd"
        info "检测到 python3-systemd，使用 systemd backend ✓"
    else
        # 尝试安装 python3-systemd
        info "尝试安装 python3-systemd..."
        if pkg_install python3-systemd &>/dev/null 2>&1 \
            && python3 -c "import systemd.journal" &>/dev/null 2>&1; then
            BACKEND="systemd"
            info "python3-systemd 安装成功，使用 systemd backend ✓"
        else
            warn "python3-systemd 不可用，使用 auto backend"
            # 没有 auth.log 则安装 rsyslog 补充
            if [ ! -f /var/log/auth.log ] && [ ! -f /var/log/secure ]; then
                info "安装 rsyslog 以生成 auth.log..."
                pkg_install rsyslog &>/dev/null 2>&1
                svc_enable rsyslog
                svc_start rsyslog || true
                sleep 1
            fi
        fi
    fi

    # ── 2. 检测版本，决定是否加 allowipv6 ────────────────────
    local F2B_MAJOR
    F2B_MAJOR=$(fail2ban-client version 2>/dev/null \
        | grep -oE '[0-9]+' | head -1)
    local ALLOW_IPV6_LINE=""
    [ "${F2B_MAJOR:-0}" -ge 1 ] && ALLOW_IPV6_LINE="allowipv6 = auto"

    # ── 3. 写入 jail.local ───────────────────────────────────
    # 已存在则先备份再重写：旧逻辑「存在就跳过」会导致脚本更新的配置永不生效
    if [ -f /etc/fail2ban/jail.local ]; then
        cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
        info "已备份原有 jail.local"
    fi

    local LOGPATH_LINE=""
    [ "$BACKEND" = "auto" ] && LOGPATH_LINE="logpath  = %(sshd_log)s"
    # systemd backend：显式声明 journalmatch，同时匹配 Debian(ssh.service) 与
    # RedHat(sshd.service)，避免纯公钥机/不同发行版漏抓（不修改系统 filter 文件）
    local JMATCH_LINE=""
    [ "$BACKEND" = "systemd" ] && JMATCH_LINE="journalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd"

    mkdir -p /etc/fail2ban
    {
        echo "[DEFAULT]"
        echo "bantime  = 3600"
        echo "findtime = 600"
        echo "maxretry = 5"
        echo "backend  = ${BACKEND}"
        [ -n "$ALLOW_IPV6_LINE" ] && echo "$ALLOW_IPV6_LINE"
        echo ""
        echo "[sshd]"
        echo "enabled  = true"
        echo "port     = ssh"
        # aggressive：纯公钥机(禁密码)下，扫描者被 publickey 拒绝/探测即断的行为
        # 默认 normal 模式不计为 failure；aggressive 才能抓到并封禁
        echo "mode     = aggressive"
        [ -n "$JMATCH_LINE" ] && echo "$JMATCH_LINE"
        [ -n "$LOGPATH_LINE" ] && echo "$LOGPATH_LINE"
    } > /etc/fail2ban/jail.local
    info "已写入 jail.local（backend=${BACKEND}, mode=aggressive）✓"

    # ── 4. 清理残留，准备启动 ────────────────────────────────
    # 清理旧 socket
    rm -f /run/fail2ban/fail2ban.sock \
          /var/run/fail2ban/fail2ban.sock 2>/dev/null || true

    # 清理可能残留的错误 override
    rm -f /etc/systemd/system/fail2ban.service.d/override.conf 2>/dev/null
    rmdir /etc/systemd/system/fail2ban.service.d/ 2>/dev/null || true

    # unmask + enable
    if systemd_available; then
        systemctl unmask fail2ban 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable fail2ban 2>/dev/null || true
    fi

    # ── 5. 验证配置再启动 ────────────────────────────────────
    info "验证 fail2ban 配置..."
    local TEST_OUT
    TEST_OUT=$(fail2ban-server -t 2>&1)
    if echo "$TEST_OUT" | grep -qiE "^OK|test is successful"; then
        info "配置验证通过，正在启动..."
        start_fail2ban
        # 等待 socket 出现（最多 8 秒）
        local i=0
        while [ $i -lt 8 ]; do
            f2b_ping && break
            sleep 1
            i=$((i+1))
        done
        if f2b_ping; then
            info "Fail2ban 安装并启动成功 ✓"
        else
            # 最后尝试：直接前台启动后台化
            warn "标准启动未响应，尝试备用方式..."
            /usr/bin/fail2ban-server -xf start &>/dev/null &
            sleep 3
            if f2b_ping; then
                info "Fail2ban 启动成功 ✓"
            else
                error "启动失败，请手动执行："
                echo -e "  ${DIM}journalctl -u fail2ban -n 20${NC}"
                echo -e "  ${DIM}fail2ban-server -xf --logtarget=sysout start${NC}"
            fi
        fi
    else
        error "配置验证失败："
        echo "$TEST_OUT" | grep -v "^OK" | while IFS= read -r l; do
            echo -e "  ${RED}$l${NC}"
        done
        echo ""
        warn "请进入「基础参数配置」修复后再启动"
    fi
}


# ── 基础参数配置 ──────────────────────────────────────────
f2b_config_params() {
    while true; do
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
        local _BAN_S; _BAN_S=$(f2b_to_seconds "$CUR_BAN")
        local _FIND_S; _FIND_S=$(f2b_to_seconds "$CUR_FIND")
        echo -e "  封禁时长  (bantime)  : ${BOLD}${CUR_BAN}${NC}  （$(f2b_seconds_to_human "$_BAN_S")）"
        echo -e "  时间窗口  (findtime) : ${BOLD}${CUR_FIND}${NC}  （$(f2b_seconds_to_human "$_FIND_S")）"
        echo -e "  最大重试  (maxretry) : ${BOLD}${CUR_MAX}${NC} 次"
        echo ""
        menu_div
        menu_pair "1" "封禁时长" "2" "时间窗口"
        menu_pair "3" "最大重试次数" "4" "监控端口"
        menu_item "5" "快速预设"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择参数 [0-5]: ' || return 0

        case "$CH" in
            1)
                echo ""
                echo -e "  常用参考：3600=1小时  86400=1天  604800=7天  -1=永久"
                read -rp "  请输入新的 bantime（秒）: " VAL
                echo "$VAL" | grep -qE '^-?[0-9]+$' || { error "无效数值"; return; }
                f2b_set_param "bantime" "$VAL"
                ;;
            2)
                echo ""
                echo -e "  常用参考：300=5分钟  600=10分钟  3600=1小时"
                read -rp "  请输入新的 findtime（秒）: " VAL
                echo "$VAL" | grep -qE '^[0-9]+$' || { error "无效数值"; return; }
                f2b_set_param "findtime" "$VAL"
                ;;
            3)
                echo ""
                echo -e "  常用参考：3=严格  5=默认  10=宽松"
                read -rp "  请输入新的 maxretry（次）: " VAL
                echo "$VAL" | grep -qE '^[0-9]+$' || { error "无效数值"; return; }
                f2b_set_param "maxretry" "$VAL"
                ;;
            4)
                echo ""
                local CUR_SSH_PORT; CUR_SSH_PORT=$(get_config "Port"); CUR_SSH_PORT="${CUR_SSH_PORT:-22}"
                echo -e "  当前 SSH 端口：${BOLD}${CUR_SSH_PORT}${NC}"
                echo -e "  示例：ssh  或  22  或  22,2222  或  22:2222"
                echo -e "  ${DIM}提示：直接回车使用当前 SSH 端口 ${CUR_SSH_PORT}${NC}"
                echo ""
                read -rp "  请输入监控端口: " VAL
                VAL="${VAL:-$CUR_SSH_PORT}"
                f2b_set_param_jail "port" "$VAL"
                ;;
            5)
                echo ""
                menu_item "1" "严格 · 1天 / 10分钟 / 3次"
                menu_item "2" "标准 · 1小时 / 10分钟 / 5次"
                menu_item "3" "宽松 · 30分钟 / 5分钟 / 10次"
                menu_item "4" "永久 · 永久 / 10分钟 / 3次" "$YELLOW"
                echo ""
                menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
                menu_read PRESET '选择预设 [1-4]: ' || return 0
                case "$PRESET" in
                    0) continue ;;
                    1) f2b_set_param "bantime" "86400";  f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "3" ;;
                    2) f2b_set_param "bantime" "3600";   f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "5" ;;
                    3) f2b_set_param "bantime" "1800";   f2b_set_param "findtime" "300"; f2b_set_param "maxretry" "10" ;;
                    4) f2b_set_param "bantime" "-1";     f2b_set_param "findtime" "600"; f2b_set_param "maxretry" "3" ;;
                    *) warn "无效选项"; return ;;
                esac
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; return ;;
        esac

        echo ""
        info "重启 Fail2ban 使配置生效..."
        if restart_fail2ban; then
            info "Fail2ban 已重启 ✓"
        else
            error "重启失败"
        fi
        ui_pause
    done
}

f2b_write_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_LOCAL="${F2B_JAIL_LOCAL:-/etc/fail2ban/jail.local}" TMP
    mkdir -p "$(dirname "$JAIL_LOCAL")" || return 1
    TMP=$(mktemp "${JAIL_LOCAL}.tmp.XXXXXX") || return 1
    [ -f "$JAIL_LOCAL" ] || : > "$JAIL_LOCAL"
    awk -v section="$SECTION" -v key="$KEY" -v value="$VAL" '
        function section_line(name) { return "[" name "]" }
        /^\[[^]]+\][[:space:]]*$/ {
            if (in_target && !written) print key " = " value
            current = $0
            gsub(/[[:space:]]+$/, "", current)
            in_target = (current == section_line(section))
            if (in_target) found_section = 1
            written = 0
            print
            next
        }
        in_target && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (!written) print key " = " value
            written = 1
            next
        }
        { print }
        END {
            if (in_target && !written) print key " = " value
            if (!found_section) {
                if (NR > 0) print ""
                print section_line(section)
                print key " = " value
            }
        }
    ' "$JAIL_LOCAL" > "$TMP" || { rm -f "$TMP"; return 1; }
    mv "$TMP" "$JAIL_LOCAL" || { rm -f "$TMP"; return 1; }
}

f2b_set_section_param() {
    local SECTION="$1" KEY="$2" VAL="$3" JAIL_LOCAL="${F2B_JAIL_LOCAL:-/etc/fail2ban/jail.local}" BACKUP EXISTED=no
    BACKUP=$(mktemp) || return 1
    if [ -f "$JAIL_LOCAL" ]; then cp "$JAIL_LOCAL" "$BACKUP" || { rm -f "$BACKUP"; return 1; }; EXISTED=yes; fi
    if ! f2b_write_section_param "$SECTION" "$KEY" "$VAL" \
        || { command -v fail2ban-client >/dev/null 2>&1 && ! fail2ban-client -t >/dev/null 2>&1; }; then
        [ "$EXISTED" = yes ] && cp "$BACKUP" "$JAIL_LOCAL" || rm -f "$JAIL_LOCAL"
        rm -f "$BACKUP"
        error "Fail2ban 配置验证失败，已恢复原配置"
        return 1
    fi
    rm -f "$BACKUP"
}

# 写入参数到 jail.local [DEFAULT] 节
f2b_set_param() {
    local KEY="$1" VAL="$2"
    f2b_set_section_param DEFAULT "$KEY" "$VAL" || return 1
    info "${KEY} 已设置为 ${VAL} ✓"
}

# 写入参数到 jail.local [sshd] 节
f2b_set_param_jail() {
    local KEY="$1" VAL="$2"
    f2b_set_section_param sshd enabled true || return 1
    f2b_set_section_param sshd "$KEY" "$VAL" || return 1
    info "[sshd] ${KEY} 已设置为 ${VAL} ✓"
}

# ── 编辑配置文件 ──────────────────────────────────────────
f2b_edit_config() {
    print_header "编辑 Fail2ban 配置文件"
    local JAIL_LOCAL="/etc/fail2ban/jail.local"
    local JAIL_CONF="/etc/fail2ban/jail.conf"

    menu_item "1" "编辑 jail.local  ${DIM}推荐${NC}"
    menu_item "2" "查看 jail.conf  ${DIM}只读参考${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    menu_read CH '选择操作 [0-2]: ' || return 0

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
            warn "即将用 $(get_editor) 打开 $JAIL_LOCAL"
            warn "编辑完成后保存退出（vi: :wq  nano: Ctrl+O/X）"
            echo ""
            ui_continue
            open_editor "$JAIL_LOCAL"
            echo ""
            read -rp "  是否重启 Fail2ban 使配置生效？(Y/n，默认Y): " RESTART
            [ -z "$RESTART" ] && RESTART="y"
            echo "$RESTART" | grep -qiE '^y(es)?$' && restart_fail2ban && info "Fail2ban 已重启 ✓" || true
            ;;
        2)
            if [ -f "$JAIL_CONF" ]; then
                echo ""
                echo -e "  ${DIM}--- $JAIL_CONF（只读）---${NC}"
                echo ""
                LANG=C.UTF-8 LESSCHARSET=utf-8 less -R "$JAIL_CONF"
            else
                warn "$JAIL_CONF 不存在"
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
}

# ── 卸载 Fail2ban ─────────────────────────────────────────
f2b_uninstall() {
    print_header "卸载 Fail2ban"
    warn "即将卸载 Fail2ban，所有配置将被清除！"
    echo ""
    read -rp "  确认卸载？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    stop_fail2ban
    svc_disable fail2ban
    if pkg_remove fail2ban; then
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
            warn "Fail2ban 未安装！"
            echo ""
            echo -e "  ${DIM}Fail2ban 是一个防暴力破解工具，可自动封禁恶意 IP${NC}"
            echo ""
            menu_div
            menu_item "1" "立即安装 Fail2ban"
            menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
            menu_div
            echo ""
            menu_read CHOICE '选择操作 [0-1]: ' || return 0
            case "$CHOICE" in
                1) f2b_install; ui_continue ;;
                0) return ;;
                00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                *) warn "无效选项"; sleep 1 ;;
            esac
            continue
        fi

        # 已安装 — 收集数据
        local F2B_COLOR BANNED_COUNT TOTAL_FAIL JAIL_NAME
        [ "$F2B_ST" = "running" ] && F2B_COLOR="$GREEN" || F2B_COLOR="$RED"

        # 自动找 SSH jail 名称（sshd / ssh）
        JAIL_NAME=$(fail2ban-client status 2>/dev/null | grep -oE 'sshd?'| head -1)
        JAIL_NAME="${JAIL_NAME:-sshd}"

        if [ "$F2B_ST" = "running" ]; then
            BANNED_COUNT=$(fail2ban-client status "$JAIL_NAME" 2>/dev/null \
                | grep "Currently banned" | grep -oE "[0-9]+" | tail -1)
            BANNED_COUNT="${BANNED_COUNT:-0}"
        else
            BANNED_COUNT="-"; TOTAL_FAIL="-"
        fi

        safe_clear
        echo ""
        box_top
        app_header_line
        echo -e "  ${BOLD}${CYAN}Fail2ban 管理${NC}"
        box_sep
        # 读取当前参数
        local CUR_BAN CUR_FIND CUR_MAX CUR_PORT
        CUR_BAN=$(grep -E "^bantime\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        CUR_FIND=$(grep -E "^findtime\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        CUR_MAX=$(grep -E "^maxretry\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        CUR_PORT=$(grep -E "^port\s*=" /etc/fail2ban/jail.local 2>/dev/null | tail -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        [ -z "$CUR_BAN" ]  && CUR_BAN="3600"
        [ -z "$CUR_FIND" ] && CUR_FIND="600"
        [ -z "$CUR_MAX" ]  && CUR_MAX="5"
        [ -z "$CUR_PORT" ] && CUR_PORT="ssh"
        local BAN_SEC; BAN_SEC=$(f2b_to_seconds "$CUR_BAN")
        local FIND_SEC; FIND_SEC=$(f2b_to_seconds "$CUR_FIND")
        local BAN_HUMAN; BAN_HUMAN=$(f2b_seconds_to_human "$BAN_SEC")
        local FIND_HUMAN; FIND_HUMAN=$(f2b_seconds_to_human "$FIND_SEC")

        box_line "  服务: ${F2B_ST}  jail: ${JAIL_NAME}"                  "  服务: ${F2B_COLOR}${BOLD}${F2B_ST}${NC}  jail: ${BOLD}${JAIL_NAME}${NC}"
        box_line "  封禁IP: ${BANNED_COUNT}  总失败: ${TOTAL_FAIL}  监控端口: ${CUR_PORT}"                  "  封禁IP: ${RED}${BOLD}${BANNED_COUNT}${NC}  总失败: ${YELLOW}${BOLD}${TOTAL_FAIL}${NC}  端口: ${BOLD}${CUR_PORT}${NC}"
        box_line "  封禁时长: ${BAN_HUMAN}  窗口: ${FIND_HUMAN}  最大重试: ${CUR_MAX}次"                  "  封禁时长: ${BOLD}${BAN_HUMAN}${NC}  窗口: ${BOLD}${FIND_HUMAN}${NC}  最大重试: ${BOLD}${CUR_MAX}${NC}次"
        box_sep
        menu_pair "1" "查看封禁 IP" "2" "手动解封"
        menu_pair "3" "实时日志" "4" "基础参数"
        menu_pair "5" "编辑配置" "6" "卸载 Fail2ban" "$GREEN" "$YELLOW"
        menu_item "u" "安装 / 更新 Fail2ban" "$CYAN"
        if [ "$F2B_ST" = "running" ]; then
            menu_item "7" "停止服务" "$YELLOW"
        else
            menu_item "7" "启动服务"
        fi
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        box_bot
        echo ""
        menu_read CHOICE '选择操作 [0-7 / u]: ' || return 0

        case "$CHOICE" in
            1) f2b_banned_list "$JAIL_NAME" ;;
            2) f2b_unban "$JAIL_NAME" ;;
            3) f2b_logs ;;
            4) f2b_config_params ;;
            5) f2b_edit_config ;;
            6) f2b_uninstall ;;
            u|U)
                print_header "安装/更新 Fail2ban"
                info "正在更新 Fail2ban..."
                pkg_install fail2ban
                local NEW_VER; NEW_VER=$(fail2ban-client version 2>/dev/null | head -1)
                info "当前版本：${NEW_VER:-未知} ✓"
                ;;
            7)
                if [ "$F2B_ST" = "running" ]; then
                    if stop_fail2ban; then
                        info "Fail2ban 已停止"
                    else
                        error "停止失败"
                    fi
                else
                    start_fail2ban
                    sleep 2
                    if f2b_ping; then
                        info "Fail2ban 已启动 ✓"
                    else
                        error "启动失败，请检查：journalctl -u fail2ban -n 20"
                    fi
                fi
                sleep 1; continue
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CHOICE}" != "0" ] && ui_pause
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
    while true; do
        print_header "手动解封 IP — $JAIL"

        local RAW
        RAW=$(fail2ban-client status "$JAIL" 2>/dev/null | grep "Banned IP" | sed 's/.*Banned IP list:\s*//')

        if [ -z "$RAW" ]; then
            echo -e "  ${GREEN}当前没有封禁的 IP${NC}"
            echo ""
            ui_pause
            return
        fi

        local i=1
        for IP in $RAW; do
            echo -e "  ${RED}[$i]${NC} $IP"
            i=$((i+1))
        done
        echo ""
        menu_div
        echo -e "  ${DIM}输入 IP 地址解封，直接回车返回上级${NC}"
        read -rp "  请输入 IP: " UNBAN_IP
        [ -z "$UNBAN_IP" ] && return

        echo ""
        if fail2ban-client set "$JAIL" unbanip "$UNBAN_IP" 2>/dev/null; then
            info "IP ${BOLD}$UNBAN_IP${NC} 已解封 ✓"
        else
            error "解封失败，请确认 IP 地址正确"
        fi
        sleep 1
    done
}

# ── 实时日志 ──────────────────────────────────────────────
f2b_logs() {
    print_header "Fail2ban 实时日志"
    echo -e "  ${DIM}显示最近 30 条，按 Ctrl+C 退出实时模式${NC}"
    menu_div
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
        menu_div
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
        menu_div
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
