#!/usr/bin/env bash
# Menu fixtures only: never install, alter networking, DD a disk or reboot.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1 LC_ALL=C
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"
fail() { echo "Menu test failed: $*" >&2; exit 1; }
safe_clear() { :; }
audit_action() { :; }
sleep() { :; }
python3() { fail 'layout invoked Python'; }

[[ $(vis_len 'SSH 工具集') = 10 ]] || fail 'CJK cell width'
[[ $(vis_len '●  防火墙  未安装') = 17 ]] || fail 'status cell width'
[[ $(vis_len $'\033[31m中文\033[0m é') = 6 ]] || fail 'ANSI/combining width'
[[ $(vis_len '') = 0 ]] || fail 'empty width'
for COLS in 36 65 66 76; do
    export COLUMNS=$COLS
    for LABEL in 'SSH 工具集' 'BBR TCP 调优' 'DNS 优化' '系统换源' 'Caddy 管理' 'Docker 管理'; do
        OUT=$(menu_pair 1 "$LABEL" '@R@' 'DDNS')
        if [ "$COLS" -ge 66 ]; then
            [[ "$OUT" != *$'\n'* ]] || fail "unexpected stacking: $LABEL/$COLS"
            PREFIX=${OUT%%@R@*}
            [[ $(vis_len "$PREFIX") = "$((COLS / 2))" ]] || fail "right column: $LABEL/$COLS"
        else
            [[ "$OUT" = *$'\n'* ]] || fail "compact menu: $COLS"
        fi
    done
    for LABEL in SSH BBR 防火墙 DDNS; do
        OUT=$(status_pair "$LABEL" 未安装 inactive RIGHT 未安装 inactive)
        if [ "$COLS" -ge 66 ]; then
            PREFIX=${OUT%%RIGHT*}
            [[ $(vis_len "$PREFIX") = "$((COLS / 2 + 3))" ]] || fail "status column: $LABEL/$COLS"
        else
            [[ "$OUT" = *$'\n'* ]] || fail "compact status: $COLS"
        fi
    done
done
export COLUMNS=76
OUT=$(menu_pair 1 '这是一段很长很长很长很长的菜单标签' 2 DDNS)
[[ "$OUT" = *$'\n'* ]] || fail 'long left menu must stack'
OUT=$(status_pair SSH '58585 · 超长公钥状态说明超长公钥状态说明' active RIGHT okay active)
[[ "$OUT" = *$'\n'* ]] || fail 'long status must stack'
OUT=$(menu_pair 1 SSH 2 '这是一段很长很长很长很长很长的右列菜单标签')
[[ "$OUT" = *$'\n'* ]] || fail 'long right menu must stack'
menu_pair 1 单项 >/dev/null || fail 'single menu returned failure'
status_pair SSH okay active >/dev/null || fail 'single status returned failure'

CHOICE=stale
menu_read CHOICE 'test' <<< 0
[[ "$CHOICE" = 0 ]] || fail '0 must return to caller'
if menu_read CHOICE 'test' </dev/null; then fail 'EOF must propagate'; fi
OUT=$(menu_read CHOICE 'test' <<< 00; echo SURVIVED)
[[ "$OUT" != *SURVIVED* ]] || fail '00 did not exit'
menu_read CHOICE 'test' defer-exit <<< 00
[[ "$CHOICE" = 00 ]] || fail 'deferred exit lost cleanup opportunity'
OUT=$(ui_pause <<< 00; echo SURVIVED)
[[ "$OUT" != *SURVIVED* ]] || fail '00 swallowed by pause'
menu_read CHOICE 'test' <<< 0
ui_pause <<< 00 # The return pause must not consume another key or exit.

# All menu selectors must use the central reader, show both navigation keys,
# and handle EOF. This also catches newly added menus forgetting their footer.
awk '
    /^[a-zA-Z_][a-zA-Z_0-9]*\(\) \{/ { nav=0 }
    /menu_pair "0" .*"00"/ || /reinstall_menu_item "00"/ { nav=1 }
    /^[[:space:]]*menu_read / {
        if (!nav || $0 !~ /\|\|/) { print FILENAME ":" FNR ": missing navigation/EOF guard"; bad=1 }
        nav=0; count++
    }
    /read -rp.*(选择|编号|规则 ID|协议 \[)/ { print FILENAME ":" FNR ": unmanaged selector"; bad=1 }
    END { if (count<90) { print "selector inventory unexpectedly small: " count; bad=1 }; exit bad }
' "$ROOT"/src/modules/*.sh || fail 'menu inventory'

print_header() { printf 'HEADER:%s\n' "$1"; }
software_package_manager() { echo apt; }
software_install_packages() { fail 'unexpected package installation'; }
reinstall_download_engine() { fail 'unexpected download'; }
for FN in software_reinstall_menu common_software_menu system_reinstall_menu; do
    OUT=$("$FN" <<< 0; echo RETURNED)
    [[ "$OUT" = *RETURNED* ]] || fail "$FN 0"
    OUT=$("$FN" <<< 00; echo SURVIVED)
    [[ "$OUT" != *SURVIVED* ]] || fail "$FN 00"
    "$FN" </dev/null >/dev/null || fail "$FN EOF"
done
common_software_menu <<< $'1 00\n0' >/dev/null
common_software_menu <<< $'1,0\n0' >/dev/null
common_software_menu <<< $'1\t00\n0' >/dev/null

# All monitor pages share isolated defaults; cancel/exit must not save or send.
(
    monitor_alert_cfg() { echo "$TMP/monitor.conf"; }
    monitor_alert_load_cfg || true # missing optional settings use defaults
    monitor_alert_load_cfg() { :; }
    monitor_alert_save_cfg() { fail 'navigation saved monitor config'; }
    monitor_alert_install_cron() { fail 'navigation installed cron'; }
    monitor_alert_test_snapshot() { fail 'navigation sent a notification'; }
    monitor_traffic_ensure_baseline() { :; }
    monitor_traffic_cycle_ensure_baseline() { :; }
    monitor_traffic_usage_text() { echo 0; }
    monitor_traffic_usage_triplet() { echo '0 0 0'; }
    monitor_alert_cron_status() { echo absent; }
    monitor_alert_next_daily_time() { echo none; }
    monitor_alert_host_label() { echo fixture; }
    monitor_alert_configured_without_cron() { return 1; }
    for FN in monitor_alert_home_menu monitor_alert_service_menu monitor_alert_notify_menu \
        monitor_alert_resource_menu monitor_alert_service_checks_menu monitor_alert_traffic_menu \
        monitor_alert_daily_menu monitor_alert_renew_menu monitor_alert_advanced_menu \
        monitor_alert_quick_setup_menu monitor_alert_legacy_config_menu \
        system_toolbox_menu config_transfer_menu stun_nat_menu login_security_logs; do
        OUT=$("$FN" <<< 0; echo RETURNED)
        [[ "$OUT" = *RETURNED* ]] || fail "$FN 0"
        OUT=$("$FN" <<< 00; echo SURVIVED)
        [[ "$OUT" != *SURVIVED* ]] || fail "$FN 00"
        "$FN" </dev/null >/dev/null || fail "$FN EOF"
    done
    for SUBMENU in 2 3 4 7; do
        OUT=$(monitor_alert_legacy_config_menu <<< "$SUBMENU"$'\n0\n0')
        [[ $(printf '%s\n' "$OUT" | grep -c '^HEADER:监控告警配置') = 2 ]] || fail 'legacy monitor skipped parent'
    done
)
(
    ufw() { [ "$1" = status ] || fail 'navigation deleted firewall rule'; echo '[1] 22 ALLOW'; }
    for FN in ufw_del_port ufw_del_ip; do
        "$FN" <<< 0 >/dev/null
        OUT=$("$FN" <<< 00; echo SURVIVED)
        [[ "$OUT" != *SURVIVED* ]] || fail "$FN 00"
    done
    docker() { echo 'fixture|fixture|running|image'; }
    if docker_select_container <<< 0 >/dev/null; then fail 'cancel selected a container'; fi
    OUT=$(docker_select_container <<< 00; echo SURVIVED)
    [[ "$OUT" != *SURVIVED* ]] || fail 'container selector swallowed 00'
)

# Real DD post-preparation menu; mocked reboot backend records every request.
reinstall_request_reboot() { printf 'reboot\n' >> "$TMP/reboots"; return "${REBOOT_RC:-0}"; }
for INPUT in 0 00 '' $'1\n\n0' $'1\nno\n0'; do
    (reinstall_reboot_menu <<< "$INPUT") >/dev/null
    [[ ! -e "$TMP/reboots" ]] || fail 'unconfirmed reboot'
done
reinstall_reboot_menu </dev/null >/dev/null
reinstall_reboot_menu <<< $'1\nREBOOT' >/dev/null
[[ $(wc -l < "$TMP/reboots" | tr -d ' ') = 1 ]] || fail 'confirmed reboot count'
REBOOT_RC=1
if reinstall_reboot_menu <<< $'1\nREBOOT' > "$TMP/failed-reboot"; then fail 'failed reboot reported success'; fi
[[ $(wc -l < "$TMP/reboots" | tr -d ' ') = 2 ]] || fail 'failed reboot retried'
grep -q '重启请求失败' "$TMP/failed-reboot" || fail 'reboot failure message'

# Upstream success is mandatory. No real downloader/engine/host introspection.
(
    reinstall_is_container() { return 1; }
    findmnt() { echo /dev/mock1; }
    lsblk() { echo mock; }
    systemd-detect-virt() { echo kvm; }
    get_config() { echo 58585; }
    # shellcheck disable=SC2034 # production runner consumes this array
    reinstall_collect_auth_args() { REINSTALL_AUTH_ARGS=(--ssh-port 58585); }
    reinstall_download_engine() { return "${DOWNLOAD_RC:-0}"; }
    bash() { printf '%s\n' "$*" >> "$TMP/engine"; return "$ENGINE_RC"; }
    reinstall_reboot_menu() { echo ready >> "$TMP/ready"; }
    ENGINE_RC=1
    if reinstall_run_target Debian debian 13 <<< ERASE-ALL-DATA >/dev/null; then fail 'failed engine accepted'; fi
    [[ ! -e "$TMP/ready" ]] || fail 'failed engine exposed reboot'
    ENGINE_RC=0
    DOWNLOAD_RC=1
    if reinstall_run_target Debian debian 13 <<< ERASE-ALL-DATA >/dev/null; then fail 'failed download accepted'; fi
    [[ ! -e "$TMP/ready" ]] || fail 'failed download exposed reboot'
    DOWNLOAD_RC=0
    reinstall_run_target Debian debian 13 <<< cancel >/dev/null
    [[ ! -e "$TMP/ready" ]] || fail 'cancelled engine exposed reboot'
    reinstall_run_target Debian debian 13 <<< ERASE-ALL-DATA >/dev/null
    [[ $(wc -l < "$TMP/ready" | tr -d ' ') = 1 ]] || fail 'success omitted reboot menu'
    reinstall_run_target RAW dd --img https://example.invalid/image.raw <<< ERASE-ALL-DATA >/dev/null
    [[ $(wc -l < "$TMP/ready" | tr -d ' ') = 2 ]] || fail 'DD omitted reboot menu'
    grep -q 'dd --img https://example.invalid/image.raw --ssh-port 58585' "$TMP/engine" || fail 'DD arguments changed'
)

# The preset subpage must return to parameters, not the Fail2ban root menu.
(
    ui_pause() { :; }
    f2b_set_param() { fail 'preset cancellation changed config'; }
    restart_fail2ban() { fail 'preset cancellation restarted service'; }
    OUT=$(f2b_config_params <<< $'5\n0\n0')
    [[ $(printf '%s\n' "$OUT" | grep -c '^HEADER:Fail2ban 基础参数配置') = 2 ]] || fail 'Fail2ban skipped parent'
)
echo 'Menu layout, navigation inventory and DD reboot safety tests passed.'
