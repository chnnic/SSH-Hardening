# ══════════════════════════════════════════════════════════
#  脚本自我管理模块
# ══════════════════════════════════════════════════════════

SCRIPT_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh"
CHECKSUM_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.sh.sha256"
MANIFEST_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/refs/heads/main/SSH-Hardening.manifest.json"
GITHUB_REF_URL="https://api.github.com/repos/chnnic/SSH-Hardening/git/ref/heads/main"
LOCAL_BIN_DIR="${LOCAL_BIN_DIR:-/usr/local/bin}"
LOCAL_SCRIPT="${LOCAL_SCRIPT:-${LOCAL_BIN_DIR}/vps-tools}"
VPS_UPDATE_CACHE="${VPS_UPDATE_CACHE:-${VPS_DATA_DIR}/update/latest-version}"

# 版本是数字分段而不是字符串；V3.12.10 > V3.12.9，V3.12 == V3.12.0。
# 在交给 awk 或界面前严格校验，拒绝多行、ANSI 转义和任意缓存文本。
self_version_valid() {
    [[ "$1" =~ ^[vV]?[0-9]{1,9}[.][0-9]{1,9}([.][0-9]{1,9})?$ ]]
}

self_version_newer() {
    local REMOTE="$1" CURRENT="$2"
    self_version_valid "$REMOTE" && self_version_valid "$CURRENT" || return 1
    LC_ALL=C awk -v remote="$REMOTE" -v current="$CURRENT" 'BEGIN {
        sub(/^[vV]/, "", remote); sub(/^[vV]/, "", current)
        split(remote, r, "."); split(current, c, ".")
        for(i=1;i<=3;i++) {
            if(r[i]+0 > c[i]+0) exit 0
            if(r[i]+0 < c[i]+0) exit 1
        }
        exit 1
    }'
}

self_cached_update_version() {
    local CACHED
    [ -f "$VPS_UPDATE_CACHE" ] && [ ! -L "$VPS_UPDATE_CACHE" ] || return 1
    CACHED=$(cat "$VPS_UPDATE_CACHE" 2>/dev/null) || return 1
    self_version_newer "$CACHED" "$APP_VERSION" || return 1
    printf 'V%s\n' "${CACHED#[vV]}"
}

self_update_notice() {
    local NEW_VER
    NEW_VER=$(self_cached_update_version) || return 0
    printf '  %s%s! 新版本 %s 可用%s  %s输入 m 后选择 2 更新%s\n' \
        "$YELLOW" "$BOLD" "$NEW_VER" "$NC" "$DIM" "$NC"
}

self_check_update() {
    local REMOTE_VER CACHE_DIR CACHE_TMP
    # 不等待网络：等于/低于当前运行版本的旧通知立即失效。首页自身也
    # 再次比较，因此后台任务未完成或旧进程后来写入缓存都不会误报。
    if ! self_cached_update_version >/dev/null; then
        rm -f "$VPS_UPDATE_CACHE" 2>/dev/null || true
    fi
    REMOTE_VER=$(
        set -o pipefail
        curl -fsSL --max-time 5 "$SCRIPT_URL" 2>/dev/null \
            | sed -nE 's/^APP_VERSION="([vV]?[0-9]+[.][0-9]+([.][0-9]+)?)"[[:space:]]*$/\1/p'
    ) || return 0
    self_version_valid "$REMOTE_VER" || return 0
    if ! self_version_newer "$REMOTE_VER" "$APP_VERSION"; then
        rm -f "$VPS_UPDATE_CACHE" 2>/dev/null || true
        return 0
    fi
    CACHE_DIR=$(dirname "$VPS_UPDATE_CACHE")
    mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
    CACHE_TMP=$(mktemp "${VPS_UPDATE_CACHE}.tmp.XXXXXX") || return 0
    if ! printf 'V%s\n' "${REMOTE_VER#[vV]}" > "$CACHE_TMP" || ! mv -f "$CACHE_TMP" "$VPS_UPDATE_CACHE"; then
        rm -f "$CACHE_TMP"
    fi
    return 0
}

file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    else return 1
    fi
}

self_atomic_replace() {
    local SOURCE="$1" DEST="$2" INSTALL_TMP
    mkdir -p "$(dirname "$DEST")" || return 1
    INSTALL_TMP="$(dirname "$DEST")/.vps-tools.update.$$"
    if ! install -m 755 "$SOURCE" "$INSTALL_TMP" || ! mv -f "$INSTALL_TMP" "$DEST"; then
        rm -f "$INSTALL_TMP"
        return 1
    fi
}

self_script_valid() {
    local FILE="$1"
    [ -f "$FILE" ] && [ -r "$FILE" ] || return 1
    bash -n "$FILE" >/dev/null 2>&1 || return 1
    grep -qE '^APP_VERSION="V[0-9]+\.[0-9]+(\.[0-9]+)?"' "$FILE" 2>/dev/null
}

self_resolve_script_source() {
    local CANDIDATE="${1:-$0}" RESOLVED
    case "$CANDIDATE" in
        -|/dev/fd/*|/dev/stdin|/proc/*/fd/*) return 1 ;;
    esac
    RESOLVED=$(readlink -f "$CANDIDATE" 2>/dev/null) || return 1
    case "$RESOLVED" in
        /dev/fd/*|/dev/stdin|/proc/*/fd/*) return 1 ;;
    esac
    self_script_valid "$RESOLVED" || return 1
    printf '%s\n' "$RESOLVED"
}

self_reconcile_tc_after_update() {
    local STATE_FILE="${TC_STATE_FILE:-/var/lib/vps-tools/tc-fq.state}"
    [ -s "$STATE_FILE" ] || return 0
    [ -f "$LOCAL_SCRIPT" ] || return 1
    VPS_TOOLS_TEST_MODE=0 BBR_TUNE_TEST_MODE=0 \
        bash "$LOCAL_SCRIPT" --bbr-reconcile-tc
}

self_fetch_script() {
    local DEST="$1" REMOTE_SHA FETCH_URL
    REMOTE_SHA=$(self_remote_main_sha || true)
    if [ -n "$REMOTE_SHA" ]; then
        FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh"
    else
        FETCH_URL="${SCRIPT_URL}?ts=$(date +%s)"
    fi
    curl -fsSL --retry 2 --retry-delay 1 \
        -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
        "$FETCH_URL" -o "$DEST" 2>/dev/null || return 1
    self_script_valid "$DEST"
}

self_shortcut_path() {
    printf '%s/%s\n' "$LOCAL_BIN_DIR" "$1"
}

self_shortcut_owned() {
    local TARGET LINK
    TARGET=$(self_shortcut_path "$1")
    [ -L "$TARGET" ] || return 1
    LINK=$(readlink "$TARGET" 2>/dev/null || true)
    [ "$LINK" = "$LOCAL_SCRIPT" ]
}

self_managed_script_file() {
    [ -f "$1" ] || return 1
    grep -qE 'VPS 开荒脚本|APP_UI_TITLE="VPS TOOLS"' "$1" 2>/dev/null
}

self_install_shortcut() {
    local CMD="$1" TARGET LINK
    TARGET=$(self_shortcut_path "$CMD")
    mkdir -p "$LOCAL_BIN_DIR" 2>/dev/null || return 1

    if self_shortcut_owned "$CMD"; then
        ln -sfn "$LOCAL_SCRIPT" "$TARGET" 2>/dev/null || return 1
        info "系统命令 ${CMD} 已创建 ✓"
        return 0
    fi

    if [ -L "$TARGET" ]; then
        LINK=$(readlink "$TARGET" 2>/dev/null || true)
        if [ ! -e "$TARGET" ]; then
            warn "快捷键 ${CMD} 指向失效路径（${LINK:-未知}），正在修复"
        elif self_managed_script_file "$TARGET"; then
            warn "快捷键 ${CMD} 指向旧版 VPS Tools，正在修复"
        else
            warn "快捷键 ${CMD} 已被其他脚本占用（${LINK:-未知}），跳过"
            return 0
        fi
    elif [ -e "$TARGET" ]; then
        if self_managed_script_file "$TARGET"; then
            warn "快捷键 ${CMD} 是旧版 VPS Tools 文件，正在替换为软链接"
        else
            warn "快捷键 ${CMD} 是独立文件（非软链接），跳过以避免覆盖"
            return 0
        fi
    fi

    ln -sfn "$LOCAL_SCRIPT" "$TARGET" 2>/dev/null || return 1
    info "系统命令 ${CMD} 已创建 ✓"
}

self_remove_shortcut() {
    local CMD="$1" TARGET
    TARGET=$(self_shortcut_path "$CMD")
    if self_shortcut_owned "$CMD" || self_managed_script_file "$TARGET"; then
        rm -f "$TARGET"
    fi
}

self_manifest_value() {
    local FILE="$1" KEY="$2"
    sed -n 's/.*"'$KEY'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$FILE" | head -1
}

self_remote_main_sha() {
    curl -fsSL --retry 2 --retry-delay 1 \
        -H 'Accept: application/vnd.github+json' \
        -H 'Cache-Control: no-cache' \
        -H 'Pragma: no-cache' \
        "$GITHUB_REF_URL" 2>/dev/null \
        | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -1
}

# ── 安装脚本到本地（设置快捷键 v）────────────────────────
self_install() {
    print_header "安装脚本到本地"
    echo -e "  将脚本安装到 ${BOLD}${LOCAL_SCRIPT}${NC}"
    echo -e "  安装后输入 ${GREEN}v${NC} 或 ${GREEN}V${NC} 即可快速呼出"
    echo ""

    local SELF="" SOURCE="" DOWNLOAD_TMP=""
    SELF=$(self_resolve_script_source "$0" 2>/dev/null || true)
    if [ -n "$SELF" ]; then
        SOURCE="$SELF"
    else
        info "当前通过管道运行，正在下载完整脚本..."
        DOWNLOAD_TMP=$(mktemp "${TMPDIR:-/tmp}/vps-tools-install.XXXXXX") || {
            error "无法创建安装临时文件"; return 1
        }
        if self_fetch_script "$DOWNLOAD_TMP"; then
            SOURCE="$DOWNLOAD_TMP"
        elif self_script_valid /tmp/ssh_hardening.sh; then
            warn "下载失败，改用已校验的本地缓存"
            SOURCE="/tmp/ssh_hardening.sh"
        else
            rm -f "$DOWNLOAD_TMP"
            error "无法获取完整脚本，请检查网络"
            return 1
        fi
    fi

    if [ "$SOURCE" != "$LOCAL_SCRIPT" ]; then
        if ! self_atomic_replace "$SOURCE" "$LOCAL_SCRIPT"; then
            rm -f "$DOWNLOAD_TMP"
            error "脚本安装失败，原文件未被替换"
            return 1
        fi
    fi
    rm -f "$DOWNLOAD_TMP"
    self_script_valid "$LOCAL_SCRIPT" || {
        error "安装后的脚本完整性校验失败"
        return 1
    }
    chmod 755 "$LOCAL_SCRIPT" || { error "无法设置脚本执行权限"; return 1; }
    info "脚本已安装到 ${LOCAL_SCRIPT} ✓"

    # 创建系统级命令 v / V（最可靠，无需 source）。
    for _CMD in v V; do
        self_install_shortcut "$_CMD" || warn "快捷键 ${_CMD} 创建失败"
    done

    echo ""
    menu_div
    info "安装完成！新终端直接输入 ${BOLD}v${NC} 即可启动"
    echo -e "  ${DIM}软链接已创建，无需 source，新终端直接可用${NC}"
    menu_div
}

# ── 强制从 GitHub 更新脚本 ────────────────────────────────
self_update() {
    print_header "强制更新脚本"
    echo -e "  ${DIM}${SCRIPT_URL}${NC}"
    echo ""

    local TMP_FILE CHECKSUM_FILE MANIFEST_FILE; TMP_FILE="/tmp/vps_update_$$.sh"; CHECKSUM_FILE="/tmp/vps_update_$$.sha256"; MANIFEST_FILE="/tmp/vps_update_$$.manifest.json"

    info "正在下载最新版本..."
    local TRY EXPECTED_HASH ACTUAL_HASH DOWNLOAD_OK SCRIPT_FETCH_URL CHECKSUM_FETCH_URL MANIFEST_FETCH_URL TS REMOTE_SHA
    DOWNLOAD_OK=0
    REMOTE_SHA=$(self_remote_main_sha || true)
    if [ -n "$REMOTE_SHA" ]; then
        info "已锁定 GitHub main commit：${REMOTE_SHA:0:12}"
    fi
    for TRY in 1 2 3 4 5; do
        TS=$(date +%s)
        case "$TRY" in
            1)
                if [ -n "$REMOTE_SHA" ]; then
                    SCRIPT_FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh"
                    CHECKSUM_FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.sh.sha256"
                    MANIFEST_FETCH_URL="https://raw.githubusercontent.com/chnnic/SSH-Hardening/${REMOTE_SHA}/SSH-Hardening.manifest.json"
                else
                    SCRIPT_FETCH_URL="$SCRIPT_URL"
                    CHECKSUM_FETCH_URL="$CHECKSUM_URL"
                    MANIFEST_FETCH_URL="$MANIFEST_URL"
                fi
                ;;
            2)
                SCRIPT_FETCH_URL="$SCRIPT_URL"
                CHECKSUM_FETCH_URL="$CHECKSUM_URL"
                MANIFEST_FETCH_URL="$MANIFEST_URL"
                ;;
            3)
                SCRIPT_FETCH_URL="$SCRIPT_URL?ts=$TS"
                CHECKSUM_FETCH_URL="$CHECKSUM_URL?ts=$TS"
                MANIFEST_FETCH_URL="$MANIFEST_URL?ts=$TS"
                ;;
            4)
                SCRIPT_FETCH_URL="https://github.com/chnnic/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh"
                CHECKSUM_FETCH_URL="https://github.com/chnnic/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.sh.sha256"
                MANIFEST_FETCH_URL="https://github.com/chnnic/SSH-Hardening/raw/refs/heads/main/SSH-Hardening.manifest.json"
                ;;
            *)
                SCRIPT_FETCH_URL="https://cdn.jsdelivr.net/gh/chnnic/SSH-Hardening@main/SSH-Hardening.sh"
                CHECKSUM_FETCH_URL="https://cdn.jsdelivr.net/gh/chnnic/SSH-Hardening@main/SSH-Hardening.sh.sha256"
                MANIFEST_FETCH_URL="https://cdn.jsdelivr.net/gh/chnnic/SSH-Hardening@main/SSH-Hardening.manifest.json"
                ;;
        esac
        rm -f "$TMP_FILE" "$CHECKSUM_FILE" "$MANIFEST_FILE"
        if curl -fsSL --retry 2 --retry-delay 1 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
            "$SCRIPT_FETCH_URL" -o "$TMP_FILE" 2>/dev/null \
            && curl -fsSL --retry 2 --retry-delay 1 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
            "$CHECKSUM_FETCH_URL" -o "$CHECKSUM_FILE" 2>/dev/null; then
            EXPECTED_HASH=$(awk 'NR==1 {print $1}' "$CHECKSUM_FILE")
            if curl -fsSL --retry 1 --retry-delay 1 -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                "$MANIFEST_FETCH_URL" -o "$MANIFEST_FILE" 2>/dev/null; then
                local MANIFEST_HASH
                MANIFEST_HASH=$(self_manifest_value "$MANIFEST_FILE" sha256)
                [ -n "$MANIFEST_HASH" ] && EXPECTED_HASH="$MANIFEST_HASH"
            fi
            ACTUAL_HASH=$(file_sha256 "$TMP_FILE" 2>/dev/null || true)
            if [ -n "$ACTUAL_HASH" ] && [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ]; then
                DOWNLOAD_OK=1
                break
            fi
        fi
        warn "下载或校验未通过，正在重试（${TRY}/5）"
        if [ -n "${ACTUAL_HASH:-}" ] || [ -n "${EXPECTED_HASH:-}" ]; then
            echo -e "  ${DIM}期望：${EXPECTED_HASH:-未知}  实际：${ACTUAL_HASH:-未知}${NC}"
        fi
        sleep 1
    done
    rm -f "$CHECKSUM_FILE" "$MANIFEST_FILE"
    if [ "$DOWNLOAD_OK" -ne 1 ]; then
        rm -f "$TMP_FILE"
        error "SHA256 校验失败，已拒绝更新"
        echo -e "  ${DIM}可先手动验证：curl -fsSL '${SCRIPT_URL}' -o /tmp/SSH-Hardening.sh && sha256sum /tmp/SSH-Hardening.sh${NC}"
        echo -e "  ${DIM}若 VPS 网络缓存异常，可临时手动覆盖：curl -fsSL '${SCRIPT_URL}' -o ${LOCAL_SCRIPT} && chmod +x ${LOCAL_SCRIPT}${NC}"
        audit_action "脚本更新SHA256校验失败" FAILED
        return
    fi
    info "SHA256 校验通过：${ACTUAL_HASH:0:16}..."

    # 验证语法
    if ! bash -n "$TMP_FILE" 2>/dev/null; then
        rm -f "$TMP_FILE"
        error "下载的文件语法有误，已取消更新"
        return
    fi

    # 版本对比
    local NEW_VER; NEW_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$TMP_FILE" | head -1)
    local CUR_VER; CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "${LOCAL_SCRIPT}" 2>/dev/null | head -1)
    echo -e "  当前版本：${BOLD}${CUR_VER:-未知}${NC}  →  最新版本：${GREEN}${BOLD}${NEW_VER:-未知}${NC}"
    echo ""

    # 覆盖前保留当前可执行版本
    if [ -f "$LOCAL_SCRIPT" ]; then
        mkdir -p "$VPS_VERSION_DIR" || { rm -f "$TMP_FILE"; error "无法创建版本备份目录"; return 1; }
        chmod 700 "$VPS_DATA_DIR" "$VPS_VERSION_DIR" 2>/dev/null || true
        local SAVED_VER
        SAVED_VER="${CUR_VER:-unknown}_$(date +%Y%m%d_%H%M%S).sh"
        cp "$LOCAL_SCRIPT" "$VPS_VERSION_DIR/$SAVED_VER" \
            && chmod 700 "$VPS_VERSION_DIR/$SAVED_VER" \
            || { rm -f "$TMP_FILE"; error "当前版本备份失败，已取消更新"; return 1; }
    fi
    # 同目录写入后原子替换，避免磁盘满或中断破坏当前脚本。
    if ! self_atomic_replace "$TMP_FILE" "$LOCAL_SCRIPT"; then
        rm -f "$TMP_FILE"
        error "更新文件安装失败，当前版本未被替换"
        audit_action "脚本更新安装失败" FAILED
        return 1
    fi
    cp "$TMP_FILE" /tmp/ssh_hardening.sh 2>/dev/null
    rm -f "$TMP_FILE"

    # 确保 v 命令还在
    self_install_shortcut v || warn "快捷键 v 修复失败"
    self_install_shortcut V || warn "快捷键 V 修复失败"

    # 由刚安装的新脚本执行，首次升级到带恢复功能的版本也能立即生效。
    self_reconcile_tc_after_update || warn "已保存的 tc 限速状态未能自动恢复，请进入 BBR 菜单检查"

    info "更新完成 ✓"
    audit_action "脚本更新 ${CUR_VER:-未知} 到 ${NEW_VER:-未知}" SUCCESS
    # 清理 DDNS 日志，保留最后 500 行（避免文件过大）
    if [ -f /var/log/ddns.log ]; then
        local _LL; _LL=$(wc -l < /var/log/ddns.log 2>/dev/null || echo 0)
        if [ "$_LL" -gt 500 ]; then
            tail -n 500 /var/log/ddns.log > /var/log/ddns.log.tmp \
                && mv /var/log/ddns.log.tmp /var/log/ddns.log
            info "DDNS 日志已清理（保留最近 500 条）✓"
        fi
    fi
    # 清理旧版写入的 alias（旧版本会写 alias v=，会拦截其他命令如 volss）
    for RC in /root/.bashrc /root/.bash_profile ~/.bashrc ~/.bash_profile ~/.zshrc; do
        [ -f "$RC" ] || continue
        if grep -q "VPS 开荒脚本快捷键" "$RC" 2>/dev/null; then
            grep -v "alias v=\|alias V=\|VPS 开荒脚本快捷键" "$RC" > "${RC}.tmp" \
                && mv "${RC}.tmp" "$RC"
            info "已清理旧版 alias（${RC}）✓"
        fi
    done
    # 清除更新提示，避免新版本启动后还显示旧提示
    rm -f "$VPS_UPDATE_CACHE" 2>/dev/null
    warn "即将用新版本重启脚本..."
    sleep 1
    exec "$LOCAL_SCRIPT"
}

# ── 回滚到更新前版本 ──────────────────────────────────────
self_rollback() {
    print_header "回滚脚本版本"
    mkdir -p "$VPS_VERSION_DIR"
    local FILES=() f i=1
    while IFS= read -r f; do FILES+=("$f"); done < <(find "$VPS_VERSION_DIR" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort -r)
    [ "${#FILES[@]}" -gt 0 ] || { warn "暂无可回滚版本"; return; }
    for f in "${FILES[@]}"; do echo -e "  ${GREEN}[$i]${NC} $(basename "$f")"; i=$((i+1)); done
    read -rp "  选择版本编号（回车取消）: " N
    [ -n "$N" ] || return
    echo "$N" | grep -qE '^[0-9]+$' || { warn "编号无效"; return; }
    [ "$N" -ge 1 ] && [ "$N" -le "${#FILES[@]}" ] || { warn "编号无效"; return; }
    local SELECTED="${FILES[$((N-1))]}"
    bash -n "$SELECTED" 2>/dev/null || { error "该版本语法校验失败"; return 1; }
    read -rp "  确认回滚到 $(basename "$SELECTED")？(y/N): " OK
    echo "$OK" | grep -qiE '^y(es)?$' || { warn "已取消"; return; }
    [ -f "$LOCAL_SCRIPT" ] && cp "$LOCAL_SCRIPT" "$VPS_VERSION_DIR/before_rollback_$(date +%Y%m%d_%H%M%S).sh"
    if ! cp "$SELECTED" "$LOCAL_SCRIPT" || ! chmod 700 "$LOCAL_SCRIPT"; then error "回滚失败"; return 1; fi
    audit_action "脚本回滚到 $(basename "$SELECTED")" SUCCESS
    info "版本回滚完成"
    warn "即将用回滚版本重启脚本..."
    sleep 1
    exec "$LOCAL_SCRIPT"
}

self_offline_bundle_create() {
    print_header "离线安装包"
    local SRC TMPDIR BUNDLE ARCHIVE
    SRC="${LOCAL_SCRIPT:-}"
    [ -f "$SRC" ] || SRC=$(self_resolve_script_source "$0" 2>/dev/null || true)
    [ -f "$SRC" ] || { error "找不到可打包的脚本"; return 1; }
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-offline.XXXXXX") || return 1
    ARCHIVE="$TMPDIR/SSH-Hardening.sh"
    cp "$SRC" "$ARCHIVE" || { rm -rf "$TMPDIR"; error "复制脚本失败"; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$ARCHIVE" > "$TMPDIR/SSH-Hardening.sh.sha256"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$ARCHIVE" > "$TMPDIR/SSH-Hardening.sh.sha256"
    else
        rm -rf "$TMPDIR"; error "缺少 SHA256 工具"; return 1
    fi
    BUNDLE="$VPS_DATA_DIR/offline/SSH-Hardening_offline_$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$VPS_DATA_DIR/offline" 2>/dev/null || { rm -rf "$TMPDIR"; error "无法创建离线包目录"; return 1; }
    tar -czf "$BUNDLE" -C "$TMPDIR" SSH-Hardening.sh SSH-Hardening.sh.sha256 || { rm -rf "$TMPDIR"; error "打包失败"; return 1; }
    rm -rf "$TMPDIR"
    chmod 600 "$BUNDLE" 2>/dev/null || true
    audit_action "生成离线安装包 $(basename "$BUNDLE")" SUCCESS
    info "离线安装包已生成：$BUNDLE"
    printf '%s\n' "$BUNDLE"
}

self_offline_bundle_install() {
    local PACKAGE="$1" TMPDIR FILE SHA_FILE EXPECTED ACTUAL DEST SRC_FILE
    [ -f "$PACKAGE" ] || { error "离线包不存在"; return 1; }
    TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/vps-offline-install.XXXXXX") || return 1
    case "$PACKAGE" in
        *.tar.gz|*.tgz)
            tar -xzf "$PACKAGE" -C "$TMPDIR" || { rm -rf "$TMPDIR"; error "解包失败"; return 1; }
            FILE=$(find "$TMPDIR" -maxdepth 1 -type f \( -name 'SSH-Hardening.sh' -o -name 'vps-tools.sh' -o -name '*.sh' \) | head -1)
            [ -n "$FILE" ] || FILE=$(find "$TMPDIR" -maxdepth 1 -type f ! -name '*.sha256' | head -1)
            SHA_FILE=$(find "$TMPDIR" -maxdepth 1 -type f -name '*.sha256' | head -1)
            [ -n "$FILE" ] || { rm -rf "$TMPDIR"; error "离线包中没有脚本文件"; return 1; }
            if [ -n "$SHA_FILE" ]; then
                EXPECTED=$(awk 'NR==1{print $1}' "$SHA_FILE")
                ACTUAL=$(file_sha256 "$FILE" 2>/dev/null || true)
                [ -n "$ACTUAL" ] && [ "$ACTUAL" = "$EXPECTED" ] || { rm -rf "$TMPDIR"; error "离线包校验失败"; return 1; }
            fi
            SRC_FILE="$FILE"
            ;;
        *.sh)
            SRC_FILE="$PACKAGE"
            bash -n "$SRC_FILE" 2>/dev/null || { rm -rf "$TMPDIR"; error "脚本语法校验失败"; return 1; }
            ;;
        *)
            rm -rf "$TMPDIR"
            error "仅支持 .sh / .tar.gz / .tgz 离线包"
            return 1
            ;;
    esac
    DEST="${LOCAL_SCRIPT:-/usr/local/bin/vps-tools}"
    mkdir -p "$(dirname "$DEST")" 2>/dev/null || { rm -rf "$TMPDIR"; error "无法创建安装目录"; return 1; }
    cp "$SRC_FILE" "$DEST" || { rm -rf "$TMPDIR"; error "安装失败"; return 1; }
    chmod 700 "$DEST" 2>/dev/null || true
    self_install_shortcut v || warn "快捷键 v 创建失败"
    self_install_shortcut V || warn "快捷键 V 创建失败"
    audit_action "离线安装脚本 $(basename "$PACKAGE")" SUCCESS
    info "离线安装完成：$DEST"
    rm -rf "$TMPDIR"
}

# ── 脚本管理菜单 ──────────────────────────────────────────
# ── 删除本地脚本和快捷键 ─────────────────────────────────
self_uninstall() {
    print_header "删除本地脚本和快捷键"
    warn "将删除以下内容："
    echo -e "  ${DIM}${LOCAL_SCRIPT}${NC}"
    echo -e "  ${DIM}$(self_shortcut_path v)${NC}"
    echo -e "  ${DIM}$(self_shortcut_path V)${NC}"
    echo -e "  ${DIM}各 shell 配置文件中的 alias v=...${NC}"
    echo ""
    read -rp "  确认删除？(Y/n，默认Y): " CONFIRM
    [ -z "$CONFIRM" ] && CONFIRM="y"
    if ! echo "$CONFIRM" | grep -qiE '^y(es)?$'; then warn "已取消"; return; fi

    # 删除本地脚本
    rm -f "$LOCAL_SCRIPT" && info "已删除 ${LOCAL_SCRIPT} ✓"

    # 删除系统命令
    self_remove_shortcut v
    self_remove_shortcut V
    info "已删除 VPS Tools 管理的系统命令 v/V ✓"

    # 清理 shell 配置文件中可能残留的旧版 alias
    for RC in /root/.bashrc /root/.bash_profile ~/.bashrc ~/.bash_profile ~/.zshrc; do
        [ -f "$RC" ] || continue
        if grep -q "VPS 开荒脚本快捷键" "$RC" 2>/dev/null; then
            grep -v "alias v=\|alias V=\|VPS 开荒脚本快捷键" "$RC" > "${RC}.tmp" \
                && mv "${RC}.tmp" "$RC"
            info "已清理旧版 alias（${RC}）✓"
        fi
    done

    echo ""
    info "清理完成，快捷键 v 已移除"
    warn "当前会话仍可使用 alias，重新登录后完全生效"
    ui_pause
    return
}

# ── 首次运行检测是否已安装快捷键 ─────────────────────────
self_check_first_run() {
    # 已安装则跳过
    self_shortcut_owned v && return
    [ -f "$LOCAL_SCRIPT" ] && return

    print_header "首次运行设置"
    echo -e "  ${YELLOW}检测到脚本未安装到本地${NC}"
    echo -e "  安装后可随时输入 ${BOLD}v${NC} 快速启动"
    echo ""
    menu_div
    menu_item "1" "立即安装  ${DIM}推荐${NC}"
    menu_item "0" "跳过并进入主菜单" "$RED"
    menu_div
    echo ""
    read -rp "$(ui_prompt '选择操作 [0-1]: ')" CH
    case "$CH" in
        1)
            self_install
            ui_pause
            ;;
        *) ;;
    esac
}

self_manage_menu() {
    while true; do
        print_header "脚本管理"

        local IS_INSTALLED=false
        local CUR_VER=""
        if [ -f "$LOCAL_SCRIPT" ]; then
            IS_INSTALLED=true
            CUR_VER=$(grep -oE 'V[0-9]+\.[0-9]+\.[0-9]+|V[0-9]+\.[0-9]+' "$LOCAL_SCRIPT" | head -1)
        fi
        local HAS_CMD=false
        self_shortcut_owned v && HAS_CMD=true

        echo -e "  本地路径：${BOLD}${LOCAL_SCRIPT}${NC}"
        if [ "$IS_INSTALLED" = true ]; then
            echo -e "  状  态  ：${GREEN}${BOLD}已安装${NC}  版本：${BOLD}${CUR_VER:-未知}${NC}"
        else
            echo -e "  状  态  ：${YELLOW}${BOLD}未安装${NC}"
        fi
        echo -e "  快捷键 v：${BOLD}$([ "$HAS_CMD" = true ] && echo "${GREEN}已设置${NC}" || echo "${YELLOW}未设置${NC}")${NC}"
        echo ""
        menu_div
        menu_pair "1" "安装并设置快捷键" "2" "更新到最新版"
        menu_pair "3" "卸载本地脚本" "4" "回滚历史版本" "$YELLOW" "$YELLOW"
        menu_pair "5" "离线安装包" "0" "返回主菜单" "$CYAN" "$RED"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        read -rp "$(ui_prompt '选择操作 [0-5]: ')" CH

        case "$CH" in
            1) self_install ;;
            2) self_update ;;
            3) self_uninstall ;;
            4) self_rollback ;;
            5)
                while true; do
                    print_header "离线安装包"
                    menu_item "1" "生成离线安装包" "$GREEN"
                    menu_item "2" "安装本地离线包" "$YELLOW"
                    menu_item "0" "返回上级" "$RED"
                    menu_div; echo ""
                    read -rp "$(ui_prompt '选择操作 [0-2]: ')" OCH
                    case "$OCH" in
                        1) self_offline_bundle_create; ui_pause ;;
                        2)
                            local PKG
                            read -rp "$(ui_prompt '输入离线包路径 (.sh/.tar.gz): ')" PKG
                            [ -n "$PKG" ] && self_offline_bundle_install "$PKG"
                            ui_pause
                            ;;
                        0) break ;;
                        *) warn "无效选项"; sleep 1 ;;
                    esac
                done
                ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; continue ;;
        esac

        [ "${CH}" != "0" ] && [ "${CH}" != "3" ] && ui_pause
    done
}
