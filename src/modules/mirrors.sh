# ══════════════════════════════════════════════════════════
#  换源模块
# ══════════════════════════════════════════════════════════

# 检测系统发行版
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID}:${VERSION_ID}"
    else
        echo "unknown"
    fi
}

mirror_backup() {
    local SRC_FILE="$1"
    local BAK
    BAK="${SRC_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$SRC_FILE" "$BAK" 2>/dev/null && info "已备份原始源文件：$BAK"
}

mirror_apt_backup() {
    MIRROR_APT_BACKUP="/root/.vps-tools/apt-sources-backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$MIRROR_APT_BACKUP" || return 1
    [ -f /etc/apt/sources.list ] && cp -a /etc/apt/sources.list "$MIRROR_APT_BACKUP/sources.list"
    [ -d /etc/apt/sources.list.d ] && cp -a /etc/apt/sources.list.d "$MIRROR_APT_BACKUP/sources.list.d"
    return 0
}

mirror_apt_restore() {
    [ -n "${MIRROR_APT_BACKUP:-}" ] && [ -d "$MIRROR_APT_BACKUP" ] || return 1
    rm -f /etc/apt/sources.list
    [ -f "$MIRROR_APT_BACKUP/sources.list" ] && cp -a "$MIRROR_APT_BACKUP/sources.list" /etc/apt/sources.list
    rm -rf /etc/apt/sources.list.d
    [ -d "$MIRROR_APT_BACKUP/sources.list.d" ] && cp -a "$MIRROR_APT_BACKUP/sources.list.d" /etc/apt/sources.list.d \
        || mkdir -p /etc/apt/sources.list.d
}

mirror_disable_deb822_default() {
    local NAME="$1" FILE="/etc/apt/sources.list.d/${1}.sources"
    [ -f "$FILE" ] || return 0
    mv "$FILE" "${FILE}.vps-tools-disabled" || return 1
    info "已禁用 deb822 默认源：${NAME}.sources"
}

# Ubuntu 的 /ubuntu 路径只有 amd64/i386；arm64 等架构在 ubuntu-ports。
mirror_ubuntu_arch_url() {
    local MIRROR="$1" ARCH
    ARCH=$(dpkg --print-architecture 2>/dev/null || true)
    case "$ARCH" in
        ''|amd64|i386) printf '%s\n' "$MIRROR" ;;
        *)
            case "$MIRROR" in
                *://archive.ubuntu.com/ubuntu) printf '%s\n' "http://ports.ubuntu.com/ubuntu-ports" ;;
                */ubuntu) printf '%s\n' "${MIRROR}-ports" ;;
                *) printf '%s\n' "$MIRROR" ;;
            esac ;;
    esac
}

# apt 对缺少当前架构的源只给 Notice，update 仍返回 0；必须确认基础包确实有候选版本。
mirror_apt_index_usable() {
    LC_ALL=C apt-cache policy coreutils 2>/dev/null | grep -qE '^[[:space:]]*Candidate:[[:space:]]+[^([:space:]]'
}

mirror_apply_ubuntu() {
    local MIRROR
    MIRROR=$(mirror_ubuntu_arch_url "$1")
    local CODENAME; CODENAME=$(get_codename)
    confirm_change_preview "切换 Ubuntu 软件源" "目标：${MIRROR}（${CODENAME}）" "改写 /etc/apt/sources.list 并停用默认 ubuntu.sources" \
        "原配置先备份；新源不可用时自动恢复" || { warn "已取消"; return 0; }
    mirror_apt_backup || { error "软件源备份失败"; return 1; }
    mkdir -p /etc/apt/sources.list.d
    mirror_disable_deb822_default ubuntu || { mirror_apt_restore; return 1; }
    if ! cat > /etc/apt/sources.list << EOF
deb ${MIRROR} ${CODENAME} main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-updates main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-backports main restricted universe multiverse
deb ${MIRROR} ${CODENAME}-security main restricted universe multiverse
EOF
    then mirror_apt_restore; error "写入 Ubuntu 源失败"; return 1; fi
    info "已切换 Ubuntu 源 → $MIRROR"
    if apt-get update -qq 2>/dev/null && mirror_apt_index_usable; then
        info "apt update 完成 ✓"
        audit_action "切换 Ubuntu 软件源 ${MIRROR}" SUCCESS
    else
        mirror_apt_restore
        apt-get update -qq 2>/dev/null || true
        error "新软件源不可用，已恢复原配置"
        audit_action "切换 Ubuntu 软件源 ${MIRROR}" FAILED
        return 1
    fi
}

mirror_apply_debian() {
    local MIRROR="$1"
    local CODENAME; CODENAME=$(get_codename)
    confirm_change_preview "切换 Debian 软件源" "目标：${MIRROR}（${CODENAME}）" "改写 /etc/apt/sources.list 并停用默认 debian.sources" \
        "原配置先备份；新源不可用时自动恢复" || { warn "已取消"; return 0; }
    mirror_apt_backup || { error "软件源备份失败"; return 1; }
    mkdir -p /etc/apt/sources.list.d
    mirror_disable_deb822_default debian || { mirror_apt_restore; return 1; }
    if ! cat > /etc/apt/sources.list << EOF
deb ${MIRROR} ${CODENAME} main contrib non-free non-free-firmware
deb ${MIRROR} ${CODENAME}-updates main contrib non-free non-free-firmware
deb ${MIRROR} ${CODENAME}-backports main contrib non-free non-free-firmware
deb ${MIRROR}-security ${CODENAME}-security main contrib non-free non-free-firmware
EOF
    then mirror_apt_restore; error "写入 Debian 源失败"; return 1; fi
    info "已切换 Debian 源 → $MIRROR"
    if apt-get update -qq 2>/dev/null && mirror_apt_index_usable; then
        info "apt update 完成 ✓"
        audit_action "切换 Debian 软件源 ${MIRROR}" SUCCESS
    else
        mirror_apt_restore
        apt-get update -qq 2>/dev/null || true
        error "新软件源不可用，已恢复原配置"
        audit_action "切换 Debian 软件源 ${MIRROR}" FAILED
        return 1
    fi
}

mirror_apply_centos() {
    local REGION="$1" BASE LABEL GPGKEY REPO_DIR="/etc/yum.repos.d" BACKUP RID
    command -v dnf >/dev/null 2>&1 || { error "当前系统缺少 dnf，无法安全自动换源"; return 1; }
    confirm_change_preview "切换 RPM 软件源" "目标：$([ "$REGION" = intl ] && echo 系统默认源 || echo "$REGION 镜像")" \
        "原仓库配置先备份；新源不可用时自动恢复" || { warn "已取消"; return 0; }
    dnf install -y dnf-plugins-core >/dev/null 2>&1 || { error "dnf config-manager 安装失败"; return 1; }
    if [ "$REGION" = intl ]; then
        local ENABLED_LIST
        rm -f "$REPO_DIR/vps-tools-base.repo"
        # 只恢复换源前处于启用状态的仓库；crb / powertools 默认是关闭的，不能一律打开。
        ENABLED_LIST=$(find /root/.vps-tools/yum-repos-backup -name enabled-repos 2>/dev/null | sort | tail -1)
        if [ -n "$ENABLED_LIST" ]; then
            while IFS= read -r RID; do
                [ -n "$RID" ] && dnf config-manager --set-enabled "$RID" >/dev/null 2>&1 || true
            done < "$ENABLED_LIST"
        else
            for RID in baseos appstream extras; do
                dnf config-manager --set-enabled "$RID" >/dev/null 2>&1 || true
            done
        fi
        dnf makecache -q || { error "系统默认源恢复后不可用"; audit_action "恢复 RPM 默认软件源" FAILED; return 1; }
        info "已恢复系统默认源 ✓"
        audit_action "恢复 RPM 默认软件源" SUCCESS
        return 0
    fi
    . /etc/os-release
    # EL8 的扩展仓库目录叫 PowerTools，EL9 起才改名 CRB。
    local CRB_DIR=CRB
    [ "${VERSION_ID%%.*}" != 8 ] || CRB_DIR=PowerTools
    case "$ID:$REGION" in
        rocky:cn) BASE="https://mirrors.aliyun.com/rockylinux"; GPGKEY="file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${VERSION_ID%%.*}" ;;
        rocky:edu) BASE="https://mirrors.tuna.tsinghua.edu.cn/rocky"; GPGKEY="file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-${VERSION_ID%%.*}" ;;
        almalinux:cn) BASE="https://mirrors.aliyun.com/almalinux"; GPGKEY="file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-${VERSION_ID%%.*}" ;;
        almalinux:edu) BASE="https://mirrors.tuna.tsinghua.edu.cn/almalinux"; GPGKEY="file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-${VERSION_ID%%.*}" ;;
        centos:cn) BASE="https://mirrors.aliyun.com/centos-stream"; GPGKEY="file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial" ;;
        centos:edu) BASE="https://mirrors.tuna.tsinghua.edu.cn/centos-stream"; GPGKEY="file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial" ;;
        rhel:*) error "RHEL 订阅仓库不支持自动替换，请使用 subscription-manager"; return 1 ;;
        *) error "暂不支持 ${ID:-unknown} 的该镜像组合"; return 1 ;;
    esac
    BACKUP="/root/.vps-tools/yum-repos-backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP" "$REPO_DIR" || return 1
    cp -a "$REPO_DIR/." "$BACKUP/" || { error "RPM 仓库配置备份失败"; return 1; }
    dnf repolist --enabled -q 2>/dev/null | awk 'NR > 1 || $1 != "repo" { print $1 }' | grep -v '^repo$' \
        | grep -E '^(baseos|appstream|crb|powertools|extras)$' > "$BACKUP/enabled-repos" || true
    for RID in baseos appstream crb powertools extras; do
        dnf config-manager --set-disabled "$RID" >/dev/null 2>&1 || true
    done
    if [ "$ID" = centos ]; then
        LABEL="CentOS Stream"
        cat > "$REPO_DIR/vps-tools-base.repo" <<EOF
[vps-tools-baseos]
name=${LABEL} - BaseOS
baseurl=${BASE}/\$releasever-stream/BaseOS/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
[vps-tools-appstream]
name=${LABEL} - AppStream
baseurl=${BASE}/\$releasever-stream/AppStream/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
[vps-tools-crb]
name=${LABEL} - CRB
baseurl=${BASE}/\$releasever-stream/CRB/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
EOF
    else
        LABEL=$([ "$ID" = rocky ] && echo Rocky || echo AlmaLinux)
        cat > "$REPO_DIR/vps-tools-base.repo" <<EOF
[vps-tools-baseos]
name=${LABEL} - BaseOS
baseurl=${BASE}/\$releasever/BaseOS/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
[vps-tools-appstream]
name=${LABEL} - AppStream
baseurl=${BASE}/\$releasever/AppStream/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
[vps-tools-crb]
name=${LABEL} - ${CRB_DIR}
baseurl=${BASE}/\$releasever/${CRB_DIR}/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
[vps-tools-extras]
name=${LABEL} - Extras
baseurl=${BASE}/\$releasever/extras/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=${GPGKEY}
EOF
    fi
    if dnf makecache -q; then
        info "${LABEL} 源已更新 ✓"
        audit_action "切换 ${LABEL} 软件源 ${BASE}" SUCCESS
    else
        rm -rf "$REPO_DIR"
        mkdir -p "$REPO_DIR"
        cp -a "$BACKUP/." "$REPO_DIR/"
        rm -f "$REPO_DIR/enabled-repos"
        error "新 RPM 软件源不可用，已恢复原配置"
        audit_action "切换 ${LABEL} 软件源 ${BASE}" FAILED
        return 1
    fi
}

mirror_menu() {
    while true; do
        local OS_INFO; OS_INFO=$(detect_os)
        local OS_ID; OS_ID=$(echo "$OS_INFO" | cut -d: -f1)
        local OS_VER; OS_VER=$(echo "$OS_INFO" | cut -d: -f2)

        print_header "系统换源"
        echo -e "  检测到系统：${BOLD}${OS_ID} ${OS_VER}${NC}"
        echo ""
        menu_div

        case "$OS_ID" in
            ubuntu)
                menu_item "1" "阿里云  ${DIM}mirrors.aliyun.com${NC}"
                menu_item "2" "腾讯云  ${DIM}mirrors.tencent.com${NC}"
                menu_item "3" "清华  ${DIM}mirrors.tuna.tsinghua.edu.cn${NC}"
                menu_item "4" "中科大  ${DIM}mirrors.ustc.edu.cn${NC}"
                menu_item "5" "Ubuntu 官方源  ${DIM}海外${NC}"
                menu_div
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                menu_div
                echo ""
                menu_read CH '选择软件源 [0-5]: ' || return 0
                case "$CH" in
                    1) mirror_apply_ubuntu "https://mirrors.aliyun.com/ubuntu" ;;
                    2) mirror_apply_ubuntu "https://mirrors.tencent.com/ubuntu" ;;
                    3) mirror_apply_ubuntu "https://mirrors.tuna.tsinghua.edu.cn/ubuntu" ;;
                    4) mirror_apply_ubuntu "https://mirrors.ustc.edu.cn/ubuntu" ;;
                    5) mirror_apply_ubuntu "http://archive.ubuntu.com/ubuntu" ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            debian)
                menu_item "1" "阿里云  ${DIM}mirrors.aliyun.com${NC}"
                menu_item "2" "腾讯云  ${DIM}mirrors.tencent.com${NC}"
                menu_item "3" "清华  ${DIM}mirrors.tuna.tsinghua.edu.cn${NC}"
                menu_item "4" "中科大  ${DIM}mirrors.ustc.edu.cn${NC}"
                menu_item "5" "Debian 官方源  ${DIM}海外${NC}"
                menu_div
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                menu_div
                echo ""
                menu_read CH '选择软件源 [0-5]: ' || return 0
                case "$CH" in
                    1) mirror_apply_debian "https://mirrors.aliyun.com/debian" ;;
                    2) mirror_apply_debian "https://mirrors.tencent.com/debian" ;;
                    3) mirror_apply_debian "https://mirrors.tuna.tsinghua.edu.cn/debian" ;;
                    4) mirror_apply_debian "https://mirrors.ustc.edu.cn/debian" ;;
                    5) mirror_apply_debian "http://deb.debian.org/debian" ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            centos|rocky|rhel|almalinux)
                menu_item "1" "阿里云"
                menu_item "2" "清华"
                menu_item "3" "系统默认源"
                menu_div
                menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
                menu_div
                echo ""
                menu_read CH '选择软件源 [0-3]: ' || return 0
                case "$CH" in
                    1) mirror_apply_centos "cn" ;;
                    2) mirror_apply_centos "edu" ;;
                    3) mirror_apply_centos "intl" ;;
                    0) return ;;
                    00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
                    *) warn "无效选项"; sleep 1; continue ;;
                esac
                ;;
            *)
                warn "暂不支持自动换源的系统：${OS_ID}"
                warn "请手动修改 /etc/apt/sources.list 或对应源文件"
                echo ""
                ui_pause
                return
                ;;
        esac

        [ "${CH:-x}" != "0" ] && ui_pause
    done
}
