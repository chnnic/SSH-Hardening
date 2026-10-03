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
    menu_div
    local PUBKEY_INPUT
    PUBKEY_INPUT=$(cat)
    menu_div
    echo ""

    # 逐行处理：去掉 CR 和空行；任何一行不是公钥就整体拒绝，避免把提示符/折行碎片写入。
    local KEY_LINES=() LINE BAD=0
    while IFS= read -r LINE; do
        LINE=${LINE%$'\r'}
        LINE=$(printf '%s' "$LINE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -n "$LINE" ] || continue
        if ! printf '%s\n' "$LINE" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss)[^[:space:]]* [A-Za-z0-9+/=]+( .*)?$'; then
            BAD=1; break
        fi
        if command -v ssh-keygen >/dev/null 2>&1 && ! printf '%s\n' "$LINE" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1; then
            BAD=1; break
        fi
        KEY_LINES+=("$LINE")
    done <<< "$PUBKEY_INPUT"

    if [ "${#KEY_LINES[@]}" -eq 0 ]; then
        warn "未输入任何内容，已取消。"
        return
    fi
    if [ "$BAD" -eq 1 ]; then
        error "公钥格式不正确：${LINE:0:40}"
        echo -e "  ${DIM}每行一个公钥，以密钥类型开头（如 ssh-ed25519 AAAA... 备注）。未写入任何公钥。${NC}"
        return
    fi

    mkdir -p "$(dirname "$AUTH_KEYS")"
    chmod 700 "$(dirname "$AUTH_KEYS")"

    # 按“类型 + 主体”去重，忽略备注差异；每把钥匙单独判断。
    local KEY_BODY ADDED=0 SKIPPED=0 SEEN=""
    # 原文件末尾没有换行时先补上，避免新公钥拼接到最后一行。
    if [ -s "$AUTH_KEYS" ] && [ -n "$(tail -c 1 "$AUTH_KEYS")" ]; then
        printf '\n' >> "$AUTH_KEYS"
    fi
    for LINE in "${KEY_LINES[@]}"; do
        KEY_BODY=$(printf '%s\n' "$LINE" | awk '{print $1, $2}')
        if grep -qF -- "$KEY_BODY" "$AUTH_KEYS" 2>/dev/null || printf '%s' "$SEEN" | grep -qxF -- "$KEY_BODY"; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi
        printf '%s\n' "$LINE" >> "$AUTH_KEYS"
        SEEN="${SEEN}${KEY_BODY}"$'\n'
        ADDED=$((ADDED + 1))
    done
    chmod 600 "$AUTH_KEYS" 2>/dev/null || true

    [ "$SKIPPED" -gt 0 ] && warn "跳过 ${SKIPPED} 个已存在的公钥"
    local TOTAL
    TOTAL=$(ssh_key_count)
    if [ "$ADDED" -gt 0 ]; then
        info "已添加 ${ADDED} 个公钥！当前共 $TOTAL 个公钥 ✓"
    else
        warn "没有新增公钥（当前共 $TOTAL 个）"
    fi
}

delete_key() {
    print_header "删除 SSH 公钥"

    if ! list_keys; then
        return
    fi

    menu_div
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_read DEL_NUM "请输入要删除的编号（直接回车取消）: " || return 0
    [ "$DEL_NUM" = "0" ] && return 0
    [ -z "$DEL_NUM" ] && { warn "已取消。"; return; }

    if ! echo "$DEL_NUM" | grep -qE '^[0-9]+$'; then
        error "无效编号。"; return
    fi

    local i=1 TARGET_LINE=""
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2|sk-ssh|sk-ecdsa|ssh-dss) '; then
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
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "${CONFIRM}" ] && CONFIRM="y"
    if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 取公钥主体（类型+base64）作为匹配依据，避免尾部空格/备注差异导致删除失败
    local KEY_BODY
    KEY_BODY=$(echo "$TARGET_LINE" | awk '{print $1, $2}')
    grep -vF "$KEY_BODY" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" || true
    mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    info "公钥已删除 ✓"
}

generate_key() {
    print_header "生成 SSH 密钥对"

    echo -e "  选择密钥类型："
    menu_item "1" "Ed25519  ${DIM}推荐，更安全更短${NC}"
    menu_item "2" "RSA 4096"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    menu_read KEY_TYPE_CHOICE '选择密钥类型 [0-2]: ' || return 0

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
    TMP_DIR=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/vps_tmp_$$" && echo "/tmp/vps_tmp_$$"; })
    KEY_FILE="$TMP_DIR/id_${KEY_TYPE}"

    echo ""
    info "正在生成 $KEY_TYPE 密钥对..."

    # shellcheck disable=SC2086 # KEY_BITS intentionally expands to "-b 4096" for RSA only.
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
    menu_div
    warn "私钥请立即复制到本地保存，关闭后无法找回！"
    menu_div
    echo ""

    read -rp "  是否将公钥添加到本服务器？(Y/n，默认Y): " ADD_CONFIRM
    [ -z "${ADD_CONFIRM}" ] && ADD_CONFIRM="y"
    if echo "${ADD_CONFIRM}" | grep -qiE '^y(es)?$'; then
        mkdir -p "$(dirname "$AUTH_KEYS")"; chmod 700 "$(dirname "$AUTH_KEYS")"
        local KEY_BODY
        KEY_BODY=$(echo "$PUBKEY" | awk '{print $1, $2}')
        if grep -qF "$KEY_BODY" "$AUTH_KEYS" 2>/dev/null; then
            warn "该公钥已存在于服务器，跳过添加"
        else
            echo "$PUBKEY" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
            local TOTAL
            TOTAL=$(ssh_key_count)
            echo ""
            info "公钥已添加到服务器！当前共 $TOTAL 个公钥 ✓"
        fi
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
    menu_div
    menu_item "1" "仅密钥登录  ${DIM}推荐${NC}"
    menu_item "2" "密码 + 密钥登录"
    menu_item "3" "仅密码登录  ${RED}不推荐${NC}" "$YELLOW"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    menu_read MODE '选择登录方式 [0-3]: ' || return 0
    echo ""

    case "$MODE" in
        1)
            local KEYCOUNT
            KEYCOUNT=$(ssh_key_count)
            if [ "$KEYCOUNT" -eq 0 ]; then
                warn "当前没有公钥！启用仅密钥登录后将无法通过密码登录！"
                read -rp "  仍要继续？(Y/n，默认Y): " FORCE
                [ -z "${FORCE}" ] && FORCE="y"
    if ! echo "${FORCE}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            fi
            backup_config
            local CANDIDATE; CANDIDATE=$(mktemp)
            cp "$SSHD_CONFIG" "$CANDIDATE"
            set_config_file "$CANDIDATE" "PasswordAuthentication" "no"
            set_config_file "$CANDIDATE" "PubkeyAuthentication"   "yes"
            set_config_file "$CANDIDATE" "PermitRootLogin"        "prohibit-password"
            if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 仅密钥登录"; then
                rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return
            fi
            safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
            cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"
            if apply_and_restart; then info "已切换：仅密钥登录 ✓"; audit_action "SSH切换为仅密钥登录" SUCCESS; safety_confirm; fi
            ;;
        2)
            backup_config
            local CANDIDATE; CANDIDATE=$(mktemp)
            cp "$SSHD_CONFIG" "$CANDIDATE"
            set_config_file "$CANDIDATE" "PasswordAuthentication" "yes"
            set_config_file "$CANDIDATE" "PubkeyAuthentication"   "yes"
            set_config_file "$CANDIDATE" "PermitRootLogin"        "yes"
            if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 密码和密钥登录"; then
                rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return
            fi
            safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
            cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"
            if apply_and_restart; then info "已切换：密码 + 密钥均可登录 ✓"; audit_action "SSH启用密码和密钥登录" SUCCESS; safety_confirm; fi
            ;;
        3)
            warn "仅密码登录安全性较低，建议配合强密码使用！"
            read -rp "  确认切换？(Y/n，默认Y): " CONFIRM
            [ -z "${CONFIRM}" ] && CONFIRM="y"
            if ! echo "${CONFIRM}" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi
            backup_config
            local CANDIDATE; CANDIDATE=$(mktemp)
            cp "$SSHD_CONFIG" "$CANDIDATE"
            set_config_file "$CANDIDATE" "PasswordAuthentication" "yes"
            set_config_file "$CANDIDATE" "PubkeyAuthentication"   "no"
            set_config_file "$CANDIDATE" "PermitRootLogin"        "yes"
            if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 仅密码登录"; then
                rm -f "$CANDIDATE"; warn "已取消，配置未修改"; return
            fi
            safety_arm ssh_login || { rm -f "$CANDIDATE"; return 1; }
            cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"
            if apply_and_restart; then info "已切换：仅密码登录 ✓"; audit_action "SSH切换为仅密码登录" SUCCESS; safety_confirm; fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) return ;;
    esac
}

# 重启后核对实际监听：socket 激活、Include 片段里的 Port 都可能让结果与预期不同。
ssh_port_report_listeners() {
    local WANT="$1" EXTRA i
    EXTRA=$(sshd_effective_ports 2>/dev/null | grep -vx "$WANT" | sort -u | paste -sd' ' -)
    [ -n "$EXTRA" ] && warn "sshd 配置仍包含其它端口：${EXTRA}（可能来自 /etc/ssh/sshd_config.d/），请手动检查"
    command -v ss >/dev/null 2>&1 || return 0
    for i in 1 2 3; do
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${WANT}\$" && return 0
        [ "$i" -lt 3 ] && sleep 1
    done
    warn "未检测到 ${WANT}/tcp 处于监听状态，请勿确认，等待自动回滚或手动检查 SSH 服务"
}

change_port() {
    print_header "修改 SSH 端口"

    local CURRENT_PORT
    CURRENT_PORT=$(get_config "Port")
    echo -e "  当前端口：${BOLD}${CURRENT_PORT:-22}${NC}"
    echo ""
    menu_div
    read -rp "  请输入新端口号（直接回车取消）: " INPUT_PORT
    menu_div
    echo ""

    [ -z "$INPUT_PORT" ] && { warn "已取消。"; return; }

    if ! echo "$INPUT_PORT" | grep -qE '^[0-9]+$' || [ "$INPUT_PORT" -lt 1 ] || [ "$INPUT_PORT" -gt 65535 ]; then
        error "无效端口号（请输入 1-65535）。"; return
    fi

    if [ "$INPUT_PORT" = "${CURRENT_PORT:-22}" ]; then
        warn "端口未变化，无需修改。"; return
    fi

    backup_config
    local CANDIDATE; CANDIDATE=$(mktemp)
    cp "$SSHD_CONFIG" "$CANDIDATE"
    set_config_file "$CANDIDATE" "Port" "$INPUT_PORT"
    sshd_comment_unmanaged_directive "$CANDIDATE" "Port" || { rm -f "$CANDIDATE"; error "无法生成候选配置"; return 1; }

    if ! confirm_file_diff "$SSHD_CONFIG" "$CANDIDATE" "SSH 端口 ${CURRENT_PORT:-22} → $INPUT_PORT"; then
        rm -f "$CANDIDATE"
        warn "已取消，配置未修改"
        return
    fi
    safety_arm ssh_port || { rm -f "$CANDIDATE"; return 1; }
    cp "$CANDIDATE" "$SSHD_CONFIG"; rm -f "$CANDIDATE"

    if ! sshd -t 2>/dev/null; then
        error "配置语法错误，自动回滚中..."
        [ -n "${LAST_SSHD_BACKUP:-}" ] && [ -f "$LAST_SSHD_BACKUP" ] && cp "$LAST_SSHD_BACKUP" "$SSHD_CONFIG" 2>/dev/null && warn "已回滚配置"
        return
    fi

    local OLD_PORT="${CURRENT_PORT:-22}"
    # 先放行新端口（旧端口暂不删，避免 restart 失败/连不上时被锁外面）
    firewall_allow_port "$INPUT_PORT"

    # 应用并重启（失败会自动回滚到旧配置）
    apply_and_restart || {
        error "SSH 重启失败，已回滚。旧端口 ${OLD_PORT} 未改动，当前连接安全。"
        return
    }
    audit_action "SSH端口 ${CURRENT_PORT:-22} 修改为 $INPUT_PORT" SUCCESS
    ssh_port_report_listeners "$INPUT_PORT"

    echo ""
    menu_div
    warn "新端口已生效，自动回滚保护仍在。"
    echo ""
    echo -e "  请【保持当前连接不要断开】，新开一个终端测试新端口："
    echo ""
    echo -e "     ${BOLD}ssh -p $INPUT_PORT 用户名@服务器IP${NC}"
    echo ""
    echo -e "  ${DIM}注意：如果 VPS 有云厂商安全组，也必须在安全组放行 ${INPUT_PORT}/tcp。${NC}"
    echo ""
    warn "只有确认新端口可登录后，脚本才会取消自动回滚。"
    menu_div
    echo ""
    read -rp "  新端口已测试可登录吗？(y/N，默认N): " NEW_OK
    [ -z "$NEW_OK" ] && NEW_OK="n"
    if ! echo "$NEW_OK" | grep -qiE '^y(es)?$'; then
        warn "未确认新端口可用，自动回滚保护仍在。180 秒内未确认将恢复旧配置。"
        return
    fi

    cancel_safety_timer
    audit_action "确认 SSH 新端口 ${INPUT_PORT} 可登录，取消自动回滚" SUCCESS
    info "已确认新端口可登录，自动回滚已取消。"
    f2b_sync_ssh_port "$OLD_PORT" "$INPUT_PORT" || warn "Fail2ban 监控端口同步失败，请在 Fail2ban 菜单手动设置为 ${INPUT_PORT}"

    echo ""
    warn "下面只清理旧端口 ${OLD_PORT}/tcp 的防火墙放行规则，不会再修改 SSH 监听端口。"
    read -rp "  现在关闭旧端口防火墙规则 ${OLD_PORT}/tcp？(y/N，默认N): " CLOSE_OLD
    [ -z "$CLOSE_OLD" ] && CLOSE_OLD="n"
    if echo "$CLOSE_OLD" | grep -qiE '^y(es)?$'; then
        if [ "$OLD_PORT" != "$INPUT_PORT" ]; then
            command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && \
                ufw delete allow "${OLD_PORT}"/tcp 2>/dev/null && info "ufw 已关闭旧端口 ${OLD_PORT}/tcp ✓"
            if command -v firewall-cmd &>/dev/null && svc_is_active firewalld; then
                firewall-cmd --permanent --remove-port="${OLD_PORT}/tcp" 2>/dev/null
                firewall-cmd --reload 2>/dev/null && info "firewalld 已关闭旧端口 ${OLD_PORT}/tcp ✓"
            fi
        fi
        info "旧端口已关闭。"
    else
        warn "旧端口 ${OLD_PORT} 保留开放。确认无误后可手动关闭，或重新进入本菜单。"
    fi
}
