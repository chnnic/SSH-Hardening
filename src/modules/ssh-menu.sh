# ── SSH 工具集子菜单 ──────────────────────────────────────
ssh_tools_menu() {
    while true; do
        local CUR_PORT CUR_PWD CUR_PUBKEY KEYCOUNT
        CUR_PORT=$(get_config "Port")
        CUR_PWD=$(get_config "PasswordAuthentication")
        CUR_PUBKEY=$(get_config "PubkeyAuthentication")
        KEYCOUNT=$(ssh_key_count)

        print_header "SSH 工具集"
        box_line "  端口 ${CUR_PORT:-22}  |  公钥数 ${KEYCOUNT}" \
                 "  端口 ${BOLD}${CUR_PORT:-22}${NC}  |  公钥数 ${BOLD}${KEYCOUNT}${NC}"
        box_line "  密码登录 ${CUR_PWD:-未设置}  |  公钥认证 ${CUR_PUBKEY:-未设置}" \
                 "  密码登录 ${BOLD}${CUR_PWD:-未设置}${NC}  |  公钥认证 ${BOLD}${CUR_PUBKEY:-未设置}${NC}"
        echo ""
        menu_div
        menu_pair "1" "查看已有公钥" "2" "添加公钥"
        menu_pair "3" "删除公钥" "4" "生成密钥对"
        menu_pair "5" "设置登录方式" "6" "修改 SSH 端口"
        menu_pair "0" "返回主菜单" "00" "退出脚本" "$RED" "$RED"
        menu_div
        echo ""
        menu_read CHOICE '选择操作 [0-6]: ' || return 0

        local NEED_PAUSE=1
        case "$CHOICE" in
            1) show_keys ;;
            2) add_key ;;
            3) delete_key ;;
            4) generate_key ;;
            5) set_login_mode ;;
            6) change_port ;;
            0) return ;;
            00) safe_clear; echo -e "${GREEN}已退出。${NC}"; exit 0 ;;
            *) warn "无效选项"; sleep 1; NEED_PAUSE=0 ;;
        esac

        [ "$NEED_PAUSE" -eq 1 ] && ui_pause
    done
}
