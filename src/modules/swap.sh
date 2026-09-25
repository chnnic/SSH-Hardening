# ══════════════════════════════════════════════════════════
#  Swap 管理模块
# ══════════════════════════════════════════════════════════

# ── 显示当前 swap 状态 ────────────────────────────────────
swap_show_status() {
    echo -e "  ${BOLD}当前 Swap 状态：${NC}"
    local TOTAL USED FREE
    if swapon --show 2>/dev/null | grep -q .; then
        swapon --show --bytes 2>/dev/null | while IFS= read -r line; do
            echo -e "  ${CYAN}${line}${NC}"
        done
        echo ""
        TOTAL=$(free -m 2>/dev/null | awk '/^Swap/{print $2}')
        USED=$(free -m 2>/dev/null  | awk '/^Swap/{print $3}')
        FREE=$(free -m 2>/dev/null  | awk '/^Swap/{print $4}')
        echo -e "  总计：${BOLD}${TOTAL}MB${NC}  已用：${BOLD}${USED}MB${NC}  空闲：${BOLD}${FREE}MB${NC}"
    else
        echo -e "  ${YELLOW}当前未设置 Swap${NC}"
    fi
    echo ""
    # swappiness
    local SWAPPINESS
    SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "未知")
    echo -e "  swappiness：${BOLD}${SWAPPINESS}${NC}  ${DIM}（0=不用swap，60=默认，100=积极使用）${NC}"
}

# ── 创建 swap 文件 ────────────────────────────────────────
swap_create() {
    print_header "创建 Swap"

    # 检测是否在 OpenVZ/LXC（不支持 swap file）
    local IS_VIRT=false
    if grep -qa "lxc\|openvz" /proc/1/environ 2>/dev/null \
        || [ -f /proc/vz/veinfo ] \
        || grep -qa "container=lxc" /proc/1/environ 2>/dev/null; then
        IS_VIRT=true
    fi

    # 内存信息
    local MEM_MB; MEM_MB=$(free -m | awk '/^Mem/{print $2}')
    local DISK_FREE; DISK_FREE=$(df -m / | awk 'NR==2{print $4}')

    echo -e "  物理内存：${BOLD}${MEM_MB}MB${NC}  磁盘可用：${BOLD}${DISK_FREE}MB${NC}"
    echo ""

    if [ "$IS_VIRT" = true ]; then
        warn "检测到 LXC/OpenVZ 容器，可能不支持 swap file"
        warn "如果创建失败请联系 VPS 服务商开启 swap 权限"
        echo ""
    fi

    # 推荐大小
    local REC_SIZE
    if   [ "$MEM_MB" -le 512  ]; then REC_SIZE=1024
    elif [ "$MEM_MB" -le 1024 ]; then REC_SIZE=2048
    elif [ "$MEM_MB" -le 2048 ]; then REC_SIZE=2048
    elif [ "$MEM_MB" -le 4096 ]; then REC_SIZE=4096
    else                              REC_SIZE=4096
    fi

    echo -e "  推荐大小：${GREEN}${REC_SIZE}MB${NC}（基于当前内存 ${MEM_MB}MB）"
    echo ""
    menu_div
    menu_pair "1" "512 MB" "2" "1 GB"
    menu_pair "3" "2 GB · 推荐" "4" "4 GB"
    menu_item "5" "自定义大小"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_div
    echo ""
    menu_read CH '选择大小 [0-5]: ' || return 0

    local SIZE_MB
    case "$CH" in
        1) SIZE_MB=512 ;;
        2) SIZE_MB=1024 ;;
        3) SIZE_MB=2048 ;;
        4) SIZE_MB=4096 ;;
        5)
            read -rp "  请输入大小（MB，如 512）: " SIZE_MB
            if ! echo "$SIZE_MB" | grep -qE '^[0-9]+$' || [ "$SIZE_MB" -lt 64 ]; then
                error "无效大小（最小 64MB）"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # 检查磁盘空间
    if [ "$SIZE_MB" -gt "$DISK_FREE" ]; then
        error "磁盘空间不足（需要 ${SIZE_MB}MB，可用 ${DISK_FREE}MB）"
        return
    fi

    local SWAP_FILE NEW_SWAP OLD_SWAP
    SWAP_FILE="${SWAP_FILE:-/swapfile}"
    NEW_SWAP="${SWAP_FILE}.vps-tools.$$"
    OLD_SWAP="${SWAP_FILE}.vps-tools.bak.$$"

    echo ""
    info "正在创建 ${SIZE_MB}MB swap 文件..."

    # 用 fallocate 或 dd 创建文件
    if command -v fallocate &>/dev/null; then
        fallocate -l "${SIZE_MB}M" "$NEW_SWAP" 2>/dev/null || \
            dd if=/dev/zero of="$NEW_SWAP" bs=1M count="$SIZE_MB" status=none
    else
        dd if=/dev/zero of="$NEW_SWAP" bs=1M count="$SIZE_MB" status=progress
    fi

    if [ ! -f "$NEW_SWAP" ]; then
        error "Swap 文件创建失败"; return
    fi

    chmod 600 "$NEW_SWAP" || { rm -f "$NEW_SWAP"; return 1; }
    mkswap "$NEW_SWAP" &>/dev/null || { rm -f "$NEW_SWAP"; error "Swap 格式化失败"; return 1; }

    if swapon --show --noheadings 2>/dev/null | awk '{print $1}' | grep -qxF "$SWAP_FILE"; then
        warn "已存在 ${SWAP_FILE}，正在安全替换..."
        swapoff "$SWAP_FILE" 2>/dev/null || { rm -f "$NEW_SWAP"; error "旧 Swap 无法关闭，已取消替换"; return 1; }
    fi
    if [ -f "$SWAP_FILE" ]; then
        mv "$SWAP_FILE" "$OLD_SWAP" || { rm -f "$NEW_SWAP"; error "旧 Swap 文件备份失败"; return 1; }
    fi
    if ! mv "$NEW_SWAP" "$SWAP_FILE" || ! swapon "$SWAP_FILE" 2>/dev/null; then
        rm -f "$SWAP_FILE" "$NEW_SWAP"
        if [ -f "$OLD_SWAP" ]; then
            mv "$OLD_SWAP" "$SWAP_FILE"
            swapon "$SWAP_FILE" 2>/dev/null || true
        fi
        error "Swap 启用失败，已恢复旧文件"
        return 1
    fi
    rm -f "$OLD_SWAP"

    info "Swap 已启用 ✓"

    # 写入 /etc/fstab 持久化
    if ! awk -v target="$SWAP_FILE" '$1 == target {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab || { error "无法写入 /etc/fstab，Swap 仅当前启动有效"; return 1; }
        info "已写入 /etc/fstab，重启后自动生效 ✓"
    fi

    echo ""
    swap_show_status
}

# ── 删除 swap ─────────────────────────────────────────────
swap_delete() {
    print_header "删除 Swap"

    local SWAPS
    SWAPS=$(swapon --show --noheadings 2>/dev/null | awk '{print $1}')

    if [ -z "$SWAPS" ]; then
        warn "当前没有启用的 Swap"
        return
    fi

    echo -e "  当前 Swap："
    local i=1
    local SWAP_LIST=()
    while IFS= read -r sw; do
        local SIZE; SIZE=$(swapon --show --bytes --noheadings 2>/dev/null | grep "^$sw" | awk '{printf "%.0fMB", $3/1048576}')
        echo -e "  ${GREEN}[$i]${NC} ${BOLD}${sw}${NC}  ${SIZE}"
        SWAP_LIST+=("$sw")
        i=$((i+1))
    done <<< "$SWAPS"

    echo ""
    menu_div
    echo -e "  ${DIM}输入编号删除，直接回车取消${NC}"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_read NUM "请输入编号: " || return 0
    [ "$NUM" = "0" ] && return 0
    [ -z "$NUM" ] && { warn "已取消"; return; }

    if ! echo "$NUM" | grep -qE '^[0-9]+$' || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#SWAP_LIST[@]} ]; then
        error "无效编号"; return
    fi

    local TARGET="${SWAP_LIST[$((NUM-1))]}"
    echo ""
    warn "即将删除 Swap：${BOLD}${TARGET}${NC}"
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    if ! swapoff "$TARGET" 2>/dev/null; then
        error "Swap 无法关闭，未修改 fstab，也未删除文件"
        return 1
    fi
    info "Swap 已关闭 ✓"

    # 从 fstab 移除
    if awk -v target="$TARGET" '$1 == target {found=1} END {exit !found}' /etc/fstab 2>/dev/null; then
        awk -v target="$TARGET" '$1 != target {print}' /etc/fstab > /etc/fstab.tmp \
            && mv /etc/fstab.tmp /etc/fstab || { error "更新 /etc/fstab 失败"; swapon "$TARGET" 2>/dev/null || true; return 1; }
        info "已从 /etc/fstab 移除 ✓"
    fi

    # 如果是文件则删除
    if [ -f "$TARGET" ]; then
        rm -f "$TARGET" && info "Swap 文件已删除 ✓"
    fi
}

# ── 修改 swappiness ───────────────────────────────────────
swap_set_swappiness() {
    print_header "设置 Swappiness"
    local CUR; CUR=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 60)

    echo -e "  当前 swappiness：${BOLD}${CUR}${NC}"
    echo ""
    echo -e "  ${DIM}推荐值：${NC}"
    menu_item "1" "10 · 服务器推荐"
    menu_item "2" "30 · 折中"
    menu_item "3" "60 · 系统默认"
    menu_item "4" "自定义 0-100"
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    echo ""
    menu_read CH '选择 Swappiness [0-4]: ' || return 0

    local VAL
    case "$CH" in
        1) VAL=10 ;;
        2) VAL=30 ;;
        3) VAL=60 ;;
        4)
            read -rp "  请输入值（0-100）: " VAL
            if ! echo "$VAL" | grep -qE '^[0-9]+$' || [ "$VAL" -gt 100 ]; then
                error "无效值（0-100）"; return
            fi
            ;;
        0) return ;;
        00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
        *) warn "无效选项"; return ;;
    esac

    # 立即生效
    echo "$VAL" > /proc/sys/vm/swappiness 2>/dev/null || { error "无法修改当前 swappiness"; return 1; }

    # 持久化到 sysctl.conf
    if grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^vm.swappiness.*/vm.swappiness = ${VAL}/" /etc/sysctl.conf || return 1
    else
        echo "vm.swappiness = ${VAL}" >> /etc/sysctl.conf || return 1
    fi

    sysctl -p &>/dev/null || { error "sysctl 配置加载失败"; return 1; }
    info "swappiness 已设置为 ${VAL}，重启后持续生效 ✓"
}

# ── Swap 主菜单 ───────────────────────────────────────────
swap_menu() {
    while true; do
        print_header "Swap 管理"
        swap_show_status
        menu_div
        menu_pair "1" "创建 / 更换 Swap" "2" "删除 Swap"
        menu_item "3" "设置 Swappiness"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CH '选择操作 [0-3]: ' || return 0

        case "$CH" in
            1) swap_create ;;
            2) swap_delete ;;
            3) swap_set_swappiness ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && ui_pause
    done
}
