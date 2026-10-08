# ============================================================
#  Docker 安装与容器管理
# ============================================================

docker_is_ready() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

docker_status() {
    if ! command -v docker >/dev/null 2>&1; then echo not_installed
    elif docker info >/dev/null 2>&1; then echo running
    else echo stopped
    fi
}

docker_download_installer() {
    local DEST="$1" URL="https://get.docker.com"
    info "正在下载 Docker 官方安装脚本..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 10 "$URL" -o "$DEST"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$DEST" "$URL"
    else
        error "需要先安装 curl 或 wget"
        return 1
    fi
    sh -n "$DEST" 2>/dev/null || { rm -f "$DEST"; error "Docker 安装脚本语法校验失败"; return 1; }
    chmod 700 "$DEST"
}

docker_download_file() {
    local URL="$1" DEST="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 10 "$URL" -o "$DEST"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$DEST" "$URL"
    else
        error "需要先安装 curl 或 wget"
        return 1
    fi
}

docker_install() {
    local PM TMP SUDO_USER_NAME="${SUDO_USER:-}"
    if docker_is_ready; then
        info "Docker 已安装并正在运行：$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        info "检测到 Docker，正在尝试启动服务..."
        svc_enable docker
        svc_start docker || true
        if docker_is_ready; then
            info "Docker 服务已恢复运行"
            return 0
        fi
    fi
    PM=$(software_package_manager)
    confirm_change_preview "安装 Docker Engine" "来源：Docker 官方仓库" "同时安装 Docker Compose 插件" || return
    if [ "$PM" = "apk" ]; then
        info "正在通过 Alpine 软件仓库安装 Docker..."
        apk update && apk add --no-cache docker docker-cli-compose
        rc-update add docker default >/dev/null 2>&1 || true
    elif [ "$PM" = "opkg" ]; then
        error "暂不支持在 OpenWrt 上自动安装 Docker"
        return 1
    else
        TMP=$(mktemp "${TMPDIR:-/tmp}/docker-install.XXXXXX") || return 1
        docker_download_installer "$TMP" || { rm -f "$TMP"; return 1; }
        info "正在执行 Docker 官方安装脚本..."
        sh "$TMP"
        rm -f "$TMP"
    fi
    svc_enable docker
    svc_start docker || true
    if [ -n "$SUDO_USER_NAME" ] && [ "$SUDO_USER_NAME" != "root" ] && id "$SUDO_USER_NAME" >/dev/null 2>&1; then
        usermod -aG docker "$SUDO_USER_NAME" 2>/dev/null || true
        warn "用户 $SUDO_USER_NAME 已加入 docker 组，重新登录后生效"
    fi
    if docker_is_ready; then
        info "Docker 安装成功：$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
        docker compose version 2>/dev/null || warn "Docker Compose 插件不可用，请检查软件源"
        audit_action "安装 Docker Engine" SUCCESS
    else
        error "Docker 已安装，但服务未能正常启动"
        audit_action "安装 Docker Engine" FAILED
        return 1
    fi
}

docker_require_ready() {
    docker_is_ready && return 0
    error "Docker 未安装或服务未运行，请先选择一键安装/修复"
    return 1
}

docker_list_containers() {
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

docker_select_container() {
    local IDS=() NAMES=() ID NAME STATUS IMAGE I CH
    while IFS='|' read -r ID NAME STATUS IMAGE; do
        [ -n "$ID" ] || continue
        IDS+=("$ID"); NAMES+=("$NAME")
        printf '  %2d) %-20s %-18s %s\n' "${#IDS[@]}" "$NAME" "$STATUS" "$IMAGE"
    done < <(docker ps -a --format '{{.ID}}|{{.Names}}|{{.State}}|{{.Image}}')
    [ "${#IDS[@]}" -gt 0 ] || { warn "当前没有容器"; return 1; }
    echo ""
    menu_pair "0" "返回上级" "00" "退出脚本" "$RED" "$RED"
    menu_read CH '选择容器编号: ' || return 1
    [ "$CH" = "0" ] && return 1
    case "$CH" in ''|*[!0-9]*) error "编号无效"; return 1 ;; esac
    I=$((CH-1))
    [ "$I" -ge 0 ] && [ "$I" -lt "${#IDS[@]}" ] || { error "编号超出范围"; return 1; }
    DOCKER_SELECTED_ID="${IDS[$I]}"
    DOCKER_SELECTED_NAME="${NAMES[$I]}"
}

docker_container_details() {
    local ID="$1"
    docker inspect --format '名称: {{.Name}}
镜像: {{.Config.Image}}
状态: {{.State.Status}}
创建: {{.Created}}
重启策略: {{.HostConfig.RestartPolicy.Name}}
网络: {{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}
挂载: {{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Type}}){{println}}{{end}}' "$ID" | sed 's#名称: /#名称: #'
}

docker_compose_available() {
    docker compose version >/dev/null 2>&1
}

docker_compose_basename() {
    local URL="$1" FILE
    FILE=${URL%%\?*}
    FILE=${FILE##*/}
    case "$FILE" in
        *.yml|*.yaml) printf '%s\n' "$FILE" ;;
        *) printf '%s\n' "compose.yaml" ;;
    esac
}

# 默认部署目录按项目区分：所有项目共用 /opt/docker-compose 时，同名文件会被覆盖，
# Compose 项目名（取自目录名）相同还会复用对方的同名服务和数据卷。
docker_compose_project_name() {
    local URL="$1" PATH_PART STEM NAME
    PATH_PART=${URL%%\?*}
    PATH_PART=${PATH_PART#*://}
    STEM=${PATH_PART##*/}
    STEM=${STEM%.*}
    case "$STEM" in
        ""|compose|docker-compose)
            PATH_PART=${PATH_PART%/*}
            STEM=${PATH_PART##*/} ;;
    esac
    NAME=$(printf '%s' "$STEM" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed -e 's/^-*//' -e 's/-*$//')
    printf '%s\n' "${NAME:-app}"
}

docker_compose_fetch_and_deploy() {
    local URL DEST_DIR FILE TMP PREVIEW
    docker_require_ready || return
    docker_compose_available || { error "缺少 Docker Compose 插件"; return 1; }
    read -rp "$(ui_prompt '输入 Compose 文件 URL: ')" URL
    echo "$URL" | grep -qE '^https?://[^[:space:]]+$' || { error "URL 格式无效"; return 1; }
    local DEFAULT_DIR OVERWRITE_NOTE="新文件"
    DEFAULT_DIR="/opt/docker-compose/$(docker_compose_project_name "$URL")"
    read -rp "$(ui_prompt "输入部署目录（默认 ${DEFAULT_DIR}）: ")" DEST_DIR
    DEST_DIR=${DEST_DIR:-$DEFAULT_DIR}
    mkdir -p "$DEST_DIR" || { error "无法创建目录：$DEST_DIR"; return 1; }
    FILE=$(docker_compose_basename "$URL")
    TMP=$(mktemp "${TMPDIR:-/tmp}/compose-file.XXXXXX") || return 1
    info "正在下载 Compose 文件..."
    if ! docker_download_file "$URL" "$TMP"; then
        rm -f "$TMP"
        return 1
    fi
    if ! docker compose -f "$TMP" config >/dev/null 2>&1; then
        rm -f "$TMP"
        error "Compose 文件校验失败"
        return 1
    fi
    PREVIEW=$(sed -n '1,120p' "$TMP")
    echo ""
    echo "$PREVIEW" | sed 's/^/  /'
    echo ""
    if [ -e "$DEST_DIR/$FILE" ]; then
        OVERWRITE_NOTE="覆盖已有文件（原文件备份为 ${FILE}.bak.*）"
        warn "目标目录已有 ${FILE}，部署会替换它；同一目录的 Compose 项目会复用同名服务和数据卷"
        if command -v diff >/dev/null 2>&1; then
            diff -u "$DEST_DIR/$FILE" "$TMP" 2>/dev/null | sed -n '1,60p' | sed 's/^/  /' || true
        fi
    fi
    if ! confirm_change_preview "部署 Compose 文件" "来源：$URL" "目标目录：$DEST_DIR" "保存为：$FILE（${OVERWRITE_NOTE}）"; then
        rm -f "$TMP"
        return
    fi
    if [ -e "$DEST_DIR/$FILE" ] && ! cp -p "$DEST_DIR/$FILE" "$DEST_DIR/${FILE}.bak.$(date +%Y%m%d_%H%M%S)"; then
        rm -f "$TMP"
        error "无法备份已有的 ${FILE}"
        return 1
    fi
    if ! cp "$TMP" "$DEST_DIR/$FILE"; then
        rm -f "$TMP"
        return 1
    fi
    rm -f "$TMP"
    if (cd "$DEST_DIR" && docker compose -f "$FILE" up -d --pull always); then
        info "Compose 项目已部署：$DEST_DIR/$FILE"
        audit_action "拉取并部署 Compose 文件：$URL -> $DEST_DIR/$FILE" SUCCESS
    else
        error "Compose 部署失败，请检查文件内容与镜像可用性"
        audit_action "拉取并部署 Compose 文件：$URL -> $DEST_DIR/$FILE" FAILED
        return 1
    fi
}

docker_inspect_label() {
    local VALUE
    VALUE=$(docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true)
    [ "$VALUE" = "<no value>" ] && VALUE=""
    printf '%s\n' "$VALUE"
}

docker_upgrade_container() {
    local ID="$1" NAME="$2" PROJECT SERVICE WORKDIR CONFIG_FILES IMAGE OLD_IMAGE NEW_IMAGE FILE
    PROJECT=$(docker_inspect_label "$ID" com.docker.compose.project)
    SERVICE=$(docker_inspect_label "$ID" com.docker.compose.service)
    WORKDIR=$(docker_inspect_label "$ID" com.docker.compose.project.working_dir)
    CONFIG_FILES=$(docker_inspect_label "$ID" com.docker.compose.project.config_files)
    if [ -n "$PROJECT" ] && [ -n "$SERVICE" ]; then
        docker_compose_available || { error "缺少 Docker Compose 插件"; return 1; }
        [ -d "$WORKDIR" ] || { error "Compose 工作目录不存在：${WORKDIR:-未记录}"; return 1; }
        confirm_change_preview "升级 Compose 容器 $NAME" "项目：$PROJECT" "服务：$SERVICE" "将拉取镜像并按 Compose 配置重建该服务" || return
        local ARGS=(-p "$PROJECT") FILES=()
        IFS=',' read -r -a FILES <<< "$CONFIG_FILES"
        for FILE in "${FILES[@]}"; do
            [ -f "$FILE" ] || FILE="$WORKDIR/$FILE"
            [ -f "$FILE" ] && ARGS+=(-f "$FILE")
        done
        if (cd "$WORKDIR" && docker compose "${ARGS[@]}" up -d --pull always "$SERVICE"); then
            info "Compose 服务 $SERVICE 已升级"
            audit_action "升级 Docker Compose：$PROJECT/$SERVICE" SUCCESS
        else
            error "Compose 升级失败，原容器不会被脚本主动删除"
            audit_action "升级 Docker Compose：$PROJECT/$SERVICE" FAILED
            return 1
        fi
        return
    fi

    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$ID" 2>/dev/null)
    [ -n "$IMAGE" ] || { error "无法读取容器镜像"; return 1; }
    OLD_IMAGE=$(docker inspect --format '{{.Image}}' "$ID" 2>/dev/null)
    if ! confirm_change_preview "检查普通容器 $NAME 的镜像更新" "镜像：$IMAGE" "仅拉取镜像，不删除或重建现有容器"; then
        return
    fi
    if ! docker pull "$IMAGE"; then
        error "镜像拉取失败"
        return 1
    fi
    NEW_IMAGE=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)
    if [ "$OLD_IMAGE" = "$NEW_IMAGE" ]; then
        info "容器已使用当前最新镜像"
    else
        warn "新镜像已下载，但现有容器仍在运行旧镜像"
        warn "该容器不是 Compose 项目，需按原 docker run 参数重建；脚本不会冒险自动删除"
    fi
}

docker_container_action() {
    local ACTION="$1"
    docker_require_ready || return
    print_header "选择 Docker 容器"
    docker_select_container || return
    case "$ACTION" in
        inspect) docker_container_details "$DOCKER_SELECTED_ID" ;;
        start|stop|restart)
            docker "$ACTION" "$DOCKER_SELECTED_ID" && info "容器 $DOCKER_SELECTED_NAME 已执行 $ACTION"
            ;;
        logs) docker logs --tail 200 --timestamps "$DOCKER_SELECTED_ID" ;;
        shell)
            docker exec -it "$DOCKER_SELECTED_ID" sh 2>/dev/null || docker exec -it "$DOCKER_SELECTED_ID" bash
            ;;
        upgrade) docker_upgrade_container "$DOCKER_SELECTED_ID" "$DOCKER_SELECTED_NAME" ;;
        remove)
            if confirm_change_preview "删除容器 $DOCKER_SELECTED_NAME" "容器数据卷不会自动删除"; then
                docker rm -f "$DOCKER_SELECTED_ID" && info "容器已删除"
            fi
            ;;
    esac
    ui_pause
}

docker_menu() {
    while true; do
        local STATE LABEL COUNT="0"
        STATE=$(docker_status)
        case "$STATE" in
            running) LABEL="运行中"; COUNT=$(docker ps -a -q 2>/dev/null | wc -l | tr -d ' ') ;;
            stopped) LABEL="已安装 · 服务停止" ;;
            *) LABEL="未安装" ;;
        esac
        print_header "Docker 管理"
        echo -e "  状态：${BOLD}$LABEL${NC}    容器：${BOLD}$COUNT${NC}"
        echo ""; menu_div
        menu_pair "1" "一键安装 / 修复" "2" "查看全部容器"
        menu_pair "3" "查看容器详情" "4" "启动容器"
        menu_pair "5" "停止容器" "6" "重启容器"
        menu_pair "7" "查看最近日志" "8" "进入容器 Shell"
        menu_pair "9" "升级容器镜像" "d" "删除容器" "$CYAN" "$YELLOW"
        menu_item "10" "拉取 Compose 文件并部署" "$BLUE"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div; echo ""
        menu_read CH '选择功能 [0-10 / d]: ' || return 0
        case "$CH" in
            1) docker_install; ui_pause ;;
            2) docker_require_ready && docker_list_containers; ui_pause ;;
            3) docker_container_action inspect ;;
            4) docker_container_action start ;;
            5) docker_container_action stop ;;
            6) docker_container_action restart ;;
            7) docker_container_action logs ;;
            8) docker_container_action shell ;;
            9) docker_container_action upgrade ;;
            10) docker_compose_fetch_and_deploy; ui_pause ;;
            d|D) docker_container_action remove ;;
            0) return ;;
            00) exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}
