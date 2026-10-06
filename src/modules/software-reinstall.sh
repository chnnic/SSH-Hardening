# ══════════════════════════════════════════════════════════
#  常用软件与系统重装 / Software and system reinstall
# ══════════════════════════════════════════════════════════

software_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    elif command -v opkg >/dev/null 2>&1; then echo opkg
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown
    fi
}

software_group_packages() {
    local PM="$1" GROUP="$2"
    case "$PM:$GROUP" in
        apt:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        apt:network) echo "iproute2 dnsutils mtr-tiny traceroute tcpdump netcat-openbsd socat nmap" ;;
        apt:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        apt:develop) echo "build-essential python3 python3-pip" ;;
        dnf:base|yum:base) echo "curl wget git jq unzip zip tar nano vim-enhanced tmux screen ca-certificates" ;;
        dnf:network|yum:network) echo "iproute bind-utils mtr traceroute tcpdump nmap-ncat socat nmap" ;;
        dnf:monitor|yum:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        dnf:develop|yum:develop) echo "gcc gcc-c++ make python3 python3-pip" ;;
        apk:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        apk:network) echo "iproute2 bind-tools mtr traceroute tcpdump netcat-openbsd socat nmap" ;;
        apk:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        apk:develop) echo "build-base python3 py3-pip" ;;
        opkg:base) echo "curl wget-ssl git git-http jq unzip zip tar nano-full vim-fuller tmux screen ca-bundle" ;;
        opkg:network) echo "ip-full bind-dig mtr traceroute tcpdump netcat socat nmap" ;;
        opkg:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        opkg:develop) echo "python3 python3-pip make gcc" ;;
        pacman:base) echo "curl wget git jq unzip zip tar nano vim tmux screen ca-certificates" ;;
        pacman:network) echo "iproute2 bind mtr traceroute tcpdump openbsd-netcat socat nmap" ;;
        pacman:monitor) echo "htop iftop iotop sysstat lsof ncdu" ;;
        pacman:develop) echo "base-devel python python-pip" ;;
    esac
}

software_refresh_index() {
    case "$1" in
        apt) apt-get update -qq ;;
        dnf) dnf makecache -q ;;
        yum) yum makecache -q ;;
        apk) apk update ;;
        opkg) opkg update ;;
        pacman) pacman -Sy --noconfirm ;;
        *) return 1 ;;
    esac
}

software_install_one() {
    local PM="$1" PKG="$2"
    case "$PM" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" ;;
        dnf) dnf install -y "$PKG" ;;
        yum) yum install -y "$PKG" ;;
        apk) apk add --no-cache "$PKG" ;;
        opkg) opkg install "$PKG" ;;
        pacman) pacman -S --noconfirm --needed "$PKG" ;;
        *) return 1 ;;
    esac
}

software_install_packages() {
    local PM="$1" PACKAGES="$2" PKG OK=0 FAILED=0 FAILED_LIST=""
    info "正在刷新软件包索引..."
    software_refresh_index "$PM" || warn "软件包索引刷新失败，将继续尝试安装"
    for PKG in $PACKAGES; do
        echo -e "  ${CYAN}›${NC} 安装 ${BOLD}$PKG${NC}"
        if software_install_one "$PM" "$PKG" >/dev/null 2>&1; then
            OK=$((OK+1))
        else
            FAILED=$((FAILED+1)); FAILED_LIST="${FAILED_LIST} ${PKG}"
        fi
    done
    echo ""; menu_div
    info "安装完成：成功 $OK 个，失败 $FAILED 个"
    [ "$FAILED" -gt 0 ] && warn "未安装：${FAILED_LIST# }"
    audit_action "安装常用软件：成功 $OK，失败 $FAILED" SUCCESS
}

reinstall_menu_item() {
    local KEY="$1" LABEL_CN="$2" LABEL_EN="$3" COL="${4:-$GREEN}"
    menu_item "$KEY" "$LABEL_CN" "$COL"
    [ "$LABEL_CN" = "$LABEL_EN" ] || echo -e "       ${DIM}${LABEL_EN}${NC}"
}

reinstall_bilingual_info() {
    info "$1"
    echo -e "       ${DIM}$2${NC}"
}

reinstall_bilingual_warn() {
    warn "$1"
    echo -e "       ${DIM}$2${NC}"
}

reinstall_bilingual_error() {
    error "$1"
    echo -e "       ${DIM}$2${NC}"
}

reinstall_bilingual_hint() {
    ui_hint "$1"
    ui_hint "$2"
}

reinstall_bilingual_header() {
    print_header "$1"
    echo -e "  ${BOLD}${DIM}$2${NC}"
    echo ""
}

common_software_menu() {
    while true; do
        print_header "安装常用软件"
        local PM; PM=$(software_package_manager)
        echo -e "  包管理器：${BOLD}$PM${NC}"
        ui_hint "可多选，例如 1 2 3；重复软件会自动去重"
        echo ""; menu_div
        menu_item "1" "基础工具  ${DIM}curl / wget / git / jq / tmux / 编辑器${NC}"
        menu_item "2" "网络诊断  ${DIM}mtr / tcpdump / socat / nmap / DNS${NC}"
        menu_item "3" "系统监控  ${DIM}htop / iftop / iotop / sysstat / ncdu${NC}"
        menu_item "4" "开发环境  ${DIM}编译工具 / Python / pip${NC}"
        menu_item "5" "全部推荐软件"
        menu_item "6" "安装自定义软件包"
        menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        menu_read CHOICES '选择分类 [0-6，可多选]: ' || return 0
        [ "$CHOICES" = "0" ] && return
        # 导航键必须单独输入；避免混选时仍执行前面的安装分类。
        if printf '%s\n' "$CHOICES" | grep -qE '(^|[[:space:],])(0|00)([[:space:],]|$)'; then
            warn "0 / 00 请单独输入"; continue
        fi
        [ "$PM" != "unknown" ] || { error "未识别到支持的包管理器"; ui_pause; return; }

        local PACKAGES="" CH GROUP PKG
        CHOICES=${CHOICES//,/ }
        for CH in $CHOICES; do
            case "$CH" in
                1) GROUP="base" ;;
                2) GROUP="network" ;;
                3) GROUP="monitor" ;;
                4) GROUP="develop" ;;
                5) GROUP="base network monitor develop" ;;
                6)
                    read -rp "$(ui_prompt '输入软件包名称: ')" PKG
                    if ! echo "$PKG" | grep -qE '^[A-Za-z0-9.+_-]+$'; then error "软件包名称格式无效"; continue; fi
                    PACKAGES="$PACKAGES $PKG"; continue ;;
                *) warn "忽略无效分类：$CH"; continue ;;
            esac
            local G
            for G in $GROUP; do
                for PKG in $(software_group_packages "$PM" "$G"); do
                    case " $PACKAGES " in *" $PKG "*) ;; *) PACKAGES="$PACKAGES $PKG" ;; esac
                done
            done
        done
        PACKAGES=${PACKAGES# }
        [ -n "$PACKAGES" ] || { warn "没有选择可安装的软件"; sleep 1; continue; }
        echo ""; echo -e "  ${BOLD}准备安装：${NC}"
        echo "$PACKAGES" | fold -s -w "$((BOX_W-4))" | sed 's/^/  /'
        confirm_change_preview "安装常用软件" "包管理器：$PM" "软件包数量：$(echo "$PACKAGES" | wc -w | tr -d ' ')" || { warn "已取消"; continue; }
        software_install_packages "$PM" "$PACKAGES"
        ui_pause
    done
}

reinstall_is_container() {
    local VIRT=""
    command -v systemd-detect-virt >/dev/null 2>&1 && VIRT=$(systemd-detect-virt 2>/dev/null || true)
    case "$VIRT" in lxc|lxc-libvirt|openvz|docker|podman|container-other) return 0 ;; esac
    grep -qaE 'lxc|openvz|docker|kubepods|containerd' /proc/1/cgroup /proc/1/environ 2>/dev/null
}

reinstall_download_engine() {
    local DEST="$1"
    local URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    reinstall_bilingual_info "正在从官方仓库下载重装工具..." "Downloading the reinstall tool from the official repository..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 10 "$URL" -o "$DEST" || {
            reinstall_bilingual_error "重装工具下载失败" "Failed to download the reinstall tool"
            return 1
        }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$DEST" "$URL" || {
            reinstall_bilingual_error "重装工具下载失败" "Failed to download the reinstall tool"
            return 1
        }
    else
        reinstall_bilingual_error "需要先安装 curl 或 wget" "Install curl or wget first"
        return 1
    fi
    bash -n "$DEST" 2>/dev/null || {
        rm -f "$DEST"
        reinstall_bilingual_error "下载脚本语法校验失败" "Downloaded script failed Bash syntax validation"
        return 1
    }
    chmod 700 "$DEST"
    local HASH; HASH=$(file_sha256 "$DEST" 2>/dev/null || echo "无法计算 / unavailable")
    reinstall_bilingual_info "下载完成" "Download complete"
    echo -e "       SHA256: ${BOLD}$HASH${NC}"
}

reinstall_collect_auth_args() {
    REINSTALL_AUTH_ARGS=()
    local SSH_PORT PASSWORD PASSWORD2 TYPE BODY COMMENT FINGER KEY_ARGS=() SKIPPED=0
    SSH_PORT=$(get_config Port); SSH_PORT=${SSH_PORT:-22}
    echo -e "  新系统 SSH 端口 / New system SSH port：${BOLD}$SSH_PORT${NC}"
    # 全部公钥都带到新系统；上游只接受 ssh-rsa / ssh-ed25519 / ecdsa-sha2-nistp*。
    while IFS=$'\t' read -r _ TYPE BODY _ COMMENT; do
        [ -n "$TYPE" ] || continue
        FINGER=$(ssh_pubkey_fingerprint "$TYPE" "$BODY")
        case "$TYPE" in
            ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)
                KEY_ARGS+=(--ssh-key "$TYPE $BODY${COMMENT:+ $COMMENT}")
                echo -e "    ${GREEN}✓${NC} ${TYPE} ${COMMENT:-（无备注）} ${DIM}${FINGER}${NC}" ;;
            *)
                SKIPPED=$((SKIPPED + 1))
                echo -e "    ${YELLOW}✗${NC} ${TYPE} ${COMMENT:-（无备注）} ${DIM}${FINGER}（重装工具不支持此类型）${NC}" ;;
        esac
    done < <(ssh_pubkey_entries "$AUTH_KEYS")
    if [ "${#KEY_ARGS[@]}" -gt 0 ]; then
        reinstall_bilingual_info "新系统将使用以上 $(( ${#KEY_ARGS[@]} / 2 )) 个公钥登录，请确认其中有你自己的公钥" "The new system will accept the public keys listed above; make sure yours is included"
        [ "$SKIPPED" -eq 0 ] || reinstall_bilingual_warn "标记 ✗ 的公钥不会带到新系统" "Keys marked ✗ will not be copied to the new system"
        local KEYS_OK
        read -rp "$(ui_prompt '以上公钥中有你能登录的私钥吗？(y/N): ')" KEYS_OK
        echo "$KEYS_OK" | grep -qiE '^y(es)?$' || {
            reinstall_bilingual_warn "已取消：请先在 SSH 管理中添加你自己的公钥" "Cancelled: add your own public key in SSH management first"
            return 1
        }
        REINSTALL_AUTH_ARGS=(--ssh-port "$SSH_PORT" "${KEY_ARGS[@]}")
        return 0
    fi
    reinstall_bilingual_warn "未检测到 SSH 公钥，需要为新系统设置 root 密码" "No SSH public key found; set a root password for the new system"
    echo -e "  ${DIM}Enter new root password (visible)${NC}"
    read -rp "$(ui_prompt '输入新系统 root 密码（明文显示）: ')" PASSWORD
    echo -e "  ${DIM}Re-enter password${NC}"
    read -rp "$(ui_prompt '再次输入密码: ')" PASSWORD2
    [ -n "$PASSWORD" ] && [ "$PASSWORD" = "$PASSWORD2" ] || {
        reinstall_bilingual_error "两次密码不一致或为空" "Passwords are empty or do not match"
        return 1
    }
    REINSTALL_AUTH_ARGS=(--ssh-port "$SSH_PORT" --password "$PASSWORD")
}

# 只在第三方工具成功完成准备后调用。返回/退出不撤销已写入的安装引导。
reinstall_reboot_menu() {
    local CH CONFIRM
    while true; do
        reinstall_bilingual_header "重装准备完成" "Reinstall preparation completed"
        reinstall_bilingual_warn "下次重启将进入安装环境并清空系统盘，请确认备份和控制台/VNC可用" "The next reboot starts installation and erases the system disk; verify backups and console/VNC access"
        reinstall_bilingual_hint "稍后重启或退出不会撤销重装准备；如需取消，请先运行 bash /root/reinstall.sh reset" "Returning or exiting does not cancel preparation; to cancel, first run bash /root/reinstall.sh reset"
        reinstall_menu_item "1" "立即重启系统，开始重装" "Reboot now to start installation" "$RED"
        reinstall_menu_item "0" "稍后重启，返回上级" "Reboot later and return" "$YELLOW"
        reinstall_menu_item "00" "退出脚本" "Exit script" "$RED"
        menu_read CH '选择操作 [0-1 / 00]: ' || return 0
        case "$CH" in
            0|"") return 0 ;;
            1)
                reinstall_bilingual_warn "重启会断开 SSH。只有输入 REBOOT 才会执行" "Reboot disconnects SSH. Type REBOOT to proceed"
                read -rp "$(ui_prompt '输入 REBOOT 确认重启（回车取消）: ')" CONFIRM || return 0
                if [ "$CONFIRM" != REBOOT ]; then
                    reinstall_bilingual_warn "已取消立即重启；重装准备仍保留" "Immediate reboot cancelled; preparation remains in place"
                    continue
                fi
                audit_action "用户确认重启进入重装环境" DANGER
                if reinstall_request_reboot; then
                    reinstall_bilingual_hint "重启请求已提交，SSH 即将断开；请从商家控制台查看安装进度" "Reboot requested; follow installation in the provider console"
                    return 0
                fi
                audit_action "重装后重启请求失败" FAILED
                reinstall_bilingual_error "重启请求失败，未自动重试；请检查系统服务状态" "Reboot request failed; no automatic retry was attempted"
                return 1
                ;;
            *) reinstall_bilingual_warn "无效选项" "Invalid option" ;;
        esac
    done
}

reinstall_request_reboot() {
    if systemd_available; then
        systemctl reboot
    else
        reboot
    fi
}

reinstall_run_target() {
    local TARGET_LABEL="$1"; shift
    local SCRIPT="/root/reinstall.sh" ROOT_SOURCE ROOT_DISK VIRT ACTION="${1:-}" SSH_PORT
    if reinstall_is_container; then
        reinstall_bilingual_error "检测到容器环境，官方重装工具不支持 OpenVZ/LXC/Docker" "Container environment detected; OpenVZ/LXC/Docker is unsupported"
        return 1
    fi
    ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || df / | awk 'END {print $1}')
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SOURCE" 2>/dev/null | head -1)
    VIRT=$(systemd-detect-virt 2>/dev/null || echo "未知")
    reinstall_bilingual_header "系统重装最终确认" "Final Reinstall Confirmation"
    echo -e "  目标系统 / Target system：${RED}${BOLD}$TARGET_LABEL${NC}"
    echo -e "  当前根分区 / Current root partition：${BOLD}${ROOT_SOURCE:-未知}${NC}"
    echo -e "  系统磁盘 / System disk：${BOLD}${ROOT_DISK:-自动识别}${NC}"
    echo -e "  虚拟化 / Virtualization：${BOLD}${VIRT:-物理机}${NC}"
    echo ""
    reinstall_bilingual_error "继续操作将清空整块系统盘，现有系统和所有数据不可恢复" "Continuing will erase the entire system disk; all data will be lost"
    reinstall_bilingual_warn "请先确认商家控制台/VNC可用，并已在异地保存必要备份" "Confirm provider console/VNC access and back up all needed data elsewhere"
    reinstall_bilingual_hint "准备成功后可选择并确认重启，随后进入临时安装环境" "After successful preparation, choose and confirm reboot to enter the installer"
    reinstall_bilingual_hint "可能看到 Reinstalling...、BusyBox 或 ~ #；这些不是新系统" "Reinstalling..., BusyBox, or ~ # may appear; this is not the new system yet"
    echo ""
    echo -e "  ${DIM}Type ERASE-ALL-DATA to confirm${NC}"
    read -rp "$(ui_prompt '输入 ERASE-ALL-DATA 确认: ')" CONFIRM
    [ "$CONFIRM" = "ERASE-ALL-DATA" ] || {
        reinstall_bilingual_warn "确认词不匹配，已取消" "Confirmation did not match; cancelled"
        return
    }
    if [ "$ACTION" = "dd" ]; then
        SSH_PORT=$(get_config Port); SSH_PORT=${SSH_PORT:-22}
        REINSTALL_AUTH_ARGS=(--ssh-port "$SSH_PORT")
        reinstall_bilingual_warn "RAW 镜像保留镜像自身账户凭据，本脚本不会注入 SSH 公钥或 root 密码" "RAW images keep their own credentials; no SSH key or root password will be injected"
    else
        reinstall_collect_auth_args || return 1
    fi
    reinstall_download_engine "$SCRIPT" || return 1
    audit_action "启动系统重装 / Start system reinstall：$TARGET_LABEL" DANGER
    echo ""
    reinstall_bilingual_warn "即将交由官方第三方重装工具执行，请认真阅读其后续输出" "The official third-party reinstall tool will now run; read its output carefully"
    reinstall_bilingual_hint "后续日志由官方工具生成，可能仅显示英文；若停在 ~ #，请查看 /var/log/syslog" "Subsequent logs come from the official tool and may be English; if it stops at ~ #, check /var/log/syslog"
    sleep 2
    if bash "$SCRIPT" "$@" "${REINSTALL_AUTH_ARGS[@]}"; then
        reinstall_reboot_menu
    else
        audit_action "系统重装准备失败：$TARGET_LABEL" FAILED
        reinstall_bilingual_error "重装工具未成功完成，不提供自动重启；请检查上方错误和当前引导状态" "Preparation failed; reboot was not requested. Check the errors and current boot state"
        return 1
    fi
}

system_reinstall_menu() {
    while true; do
        reinstall_bilingual_header "一键 DD / 系统重装" "One-click DD / System Reinstall"
        reinstall_bilingual_error "此功能会清空整块系统盘" "This operation erases the entire system disk"
        reinstall_bilingual_hint "仅适用于 KVM、VMware、Hyper-V 或独立服务器" "Only for KVM, VMware, Hyper-V, or bare-metal servers"
        reinstall_bilingual_hint "使用 bin456789/reinstall 官方工具；OpenVZ/LXC/Docker 将被拒绝" "Uses bin456789/reinstall; OpenVZ/LXC/Docker containers are rejected"
        echo ""; menu_div
        reinstall_menu_item "1" "Debian 12" "Debian 12"
        reinstall_menu_item "2" "Debian 13" "Debian 13"
        reinstall_menu_item "3" "Ubuntu 22.04" "Ubuntu 22.04"
        reinstall_menu_item "4" "Ubuntu 24.04" "Ubuntu 24.04"
        reinstall_menu_item "5" "Alpine 3.20" "Alpine 3.20"
        reinstall_menu_item "6" "Alpine 3.22" "Alpine 3.22"
        reinstall_menu_item "7" "Rocky Linux 9" "Rocky Linux 9"
        reinstall_menu_item "8" "DD 自定义 RAW 镜像" "Custom DD RAW image" "$YELLOW"
        reinstall_menu_item "9" "仅下载 / 更新重装工具" "Download / update reinstall tool"
        reinstall_menu_item "0" "返回上级" "Back to previous menu" "$RED"
        reinstall_menu_item "00" "退出脚本" "Exit script" "$RED"
        menu_div; echo ""
        echo -e "  ${DIM}Select target system [0-9]${NC}"
        menu_read CH '选择目标系统 [0-9]: ' || return 0
        case "$CH" in
            1) reinstall_run_target "Debian 12" debian 12 ;;
            2) reinstall_run_target "Debian 13" debian 13 ;;
            3) reinstall_run_target "Ubuntu 22.04" ubuntu 22.04 ;;
            4) reinstall_run_target "Ubuntu 24.04" ubuntu 24.04 ;;
            5) reinstall_run_target "Alpine 3.20" alpine 3.20 ;;
            6) reinstall_run_target "Alpine 3.22" alpine 3.22 ;;
            7) reinstall_run_target "Rocky Linux 9" rocky 9 ;;
            8)
                local IMG
                echo -e "  ${DIM}Enter RAW/VHD image URL${NC}"
                read -rp "$(ui_prompt '输入 RAW/VHD 镜像直链: ')" IMG
                echo "$IMG" | grep -qE '^https?://[^[:space:]]+$' || {
                    reinstall_bilingual_error "镜像链接格式无效" "Invalid image URL"
                    ui_pause
                    continue
                }
                reinstall_run_target "自定义 RAW 镜像" dd --img "$IMG"
                ;;
            9) reinstall_download_engine /root/reinstall.sh ;;
            0) return ;;
            *) reinstall_bilingual_warn "无效选项" "Invalid option"; sleep 1; continue ;;
        esac
        ui_pause
    done
}

software_reinstall_menu() {
    while true; do
        reinstall_bilingual_header "软件与系统重装" "Software & System Reinstall"
        reinstall_menu_item "1" "安装常用软件" "Install common software"
        reinstall_menu_item "2" "一键 DD / 系统重装" "One-click DD / System Reinstall" "$RED"
        reinstall_menu_item "0" "返回主菜单" "Back to main menu" "$RED"
        reinstall_menu_item "00" "退出脚本" "Exit script" "$RED"
        menu_div; echo ""
        echo -e "  ${DIM}Select function [0-2]${NC}"
        menu_read CH '选择功能 [0-2]: ' || return 0
        case "$CH" in
            1) common_software_menu ;;
            2) system_reinstall_menu ;;
            0) return ;;
            *) reinstall_bilingual_warn "无效选项" "Invalid option"; sleep 1 ;;
        esac
    done
}
