#!/usr/bin/env bash
# Hermetic sysctl/diagnostic fixtures: never read or write the host's Linux settings.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1 BBR_TUNE_TEST_MODE=1
# shellcheck source=/dev/null
source "${BBR_TEST_SCRIPT:-$ROOT/SSH-Hardening.sh}"

fail() { echo "BBR enhancement test failed: $*" >&2; exit 1; }
ensure_sysctl() { :; }
bbr_default_ipv6_iface() { echo ''; }

fixture() {
    TEST_CASE="$TMP/$1"
    mkdir -p "$TEST_CASE"
    export TMPDIR="$TEST_CASE"
    export BBR_PROC_SYS="$TEST_CASE/proc/sys"
    BBR_PROC_NET="$TEST_CASE/proc/net"
    export BBR_BASELINE_FILE="$TEST_CASE/baseline.conf"
    SYSCTL_FILE="$TEST_CASE/99-vps-bbr.conf"
    export TC_STATE_FILE="$TEST_CASE/no-tc.state"
    WRITE_LOG="$TEST_CASE/writes"
    : > "$WRITE_LOG"
    BBR_FAIL_WRITE=''
    BBR_IGNORE_WRITE=''
    BBR_SIDE_EFFECT=''
    BBR_SIGNAL=''
    BBR_FORWARD_MODEL=0
    BBR_FAIL_READ=''
    local KEY VALUE PATHNAME
    while IFS='=' read -r KEY VALUE; do
        PATHNAME=$(bbr_sysctl_path "$KEY")
        mkdir -p "$(dirname "$PATHNAME")"
        printf '%s\n' "$VALUE" > "$PATHNAME"
    done <<'EOF'
net.core.default_qdisc=fq_codel
net.ipv4.tcp_congestion_control=cubic
net.core.rmem_max=4096
net.core.wmem_max=4096
net.ipv4.tcp_rmem=4096 131072 4096
net.ipv4.tcp_wmem=4096 16384 4096
net.ipv4.tcp_fastopen=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_ecn_fallback=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.ip_forward=0
EOF
    printf 'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic\n' > "$SYSCTL_FILE"
    cp "$SYSCTL_FILE" "$TEST_CASE/original.conf"
}

# shellcheck disable=SC2329 # called by production functions
sysctl() {
    local KEY="${2%%=*}" VALUE="${2#*=}" PATHNAME EFFECT
    PATHNAME=$(bbr_sysctl_path "$KEY")
    [ -f "$PATHNAME" ] || return 1
    case "$1" in
        -n) [ "$KEY" != "$BBR_FAIL_READ" ] && cat "$PATHNAME" ;;
        -w)
            printf '%s\n' "$2" >> "$WRITE_LOG"
            [ "$2" != "$BBR_FAIL_WRITE" ] || { echo 'permission denied' >&2; return 1; }
            [ "$2" != "$BBR_IGNORE_WRITE" ] || return 0
            printf '%s\n' "$VALUE" > "$PATHNAME"
            [ "$2" != "$BBR_SIGNAL" ] || sh -c 'kill -TERM "$PPID"'
            if [ "$2" = "$BBR_SIDE_EFFECT" ]; then
                printf '9\n' > "$(bbr_sysctl_path net.core.rmem_max)"
            fi
            if [ "$BBR_FORWARD_MODEL" = 1 ]; then
                case "$KEY" in
                    net.ipv6.conf.all.forwarding)
                        for EFFECT in "$BBR_PROC_SYS"/net/ipv6/conf/*/forwarding; do
                            printf '%s\n' "$VALUE" > "$EFFECT"
                        done
                        if [ "$VALUE" = 0 ]; then
                            printf '0\n' > "$BBR_PROC_SYS/net/ipv6/conf/wg0/force_forwarding"
                        fi ;;
                    net.ipv4.ip_forward)
                        for EFFECT in "$BBR_PROC_SYS"/net/ipv4/conf/*/forwarding; do
                            printf '%s\n' "$VALUE" > "$EFFECT"
                        done
                        printf '%s\n' "$((1 - VALUE))" > "$BBR_PROC_SYS/net/ipv4/conf/all/accept_redirects" ;;
                esac
                case "$KEY:$VALUE" in
                    net.ipv6.conf.default.forwarding:*) ;;
                    net.ipv6.conf.*.forwarding:1)
                        if [ "$(cat "$BBR_PROC_SYS/net/ipv6/conf/eth0/accept_ra")" != 2 ]; then
                            printf 'absent\n' > "$TEST_CASE/ra-route"
                        fi ;;
                esac
            fi
            ;;
        *) return 1 ;;
    esac
}

forwarding_fixture() {
    local FAMILY IFACE
    BBR_FORWARD_MODEL=1
    for FAMILY in ipv4 ipv6; do
        for IFACE in all default eth0 wg0 eth0.100; do
            mkdir -p "$BBR_PROC_SYS/net/$FAMILY/conf/$IFACE"
            printf '0\n' > "$BBR_PROC_SYS/net/$FAMILY/conf/$IFACE/forwarding"
            printf '1\n' > "$BBR_PROC_SYS/net/$FAMILY/conf/$IFACE/accept_ra"
        done
    done
    printf '0\n' > "$BBR_PROC_SYS/net/ipv4/conf/all/accept_redirects"
    printf '1\n' > "$BBR_PROC_SYS/net/ipv6/conf/wg0/force_forwarding"
    printf 'present\n' > "$TEST_CASE/ra-route"
}

fixture tcp_status
while IFS='=' read -r KEY VALUE; do
    printf '%s\n' "$VALUE" > "$(bbr_sysctl_path "$KEY")"
    printf '%s = %s\n' "$KEY" "$VALUE" >> "$SYSCTL_FILE"
done <<'EOF'
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_ecn=1
net.ipv4.tcp_ecn_fallback=1
net.ipv4.tcp_mtu_probing=1
EOF
printf 'net.ipv4.tcp_fastopen = 1\nnet.ipv4.tcp_mtu_probing = 0\n' > "$BBR_BASELINE_FILE"
cp "$SYSCTL_FILE" "$TEST_CASE/display-before.conf"
cp "$BBR_BASELINE_FILE" "$TEST_CASE/display-before.baseline"
OUTPUT=$(bbr_tcp_status)
[[ "$OUTPUT" = *'当前: 3（已开启：客户端 + 服务端）'* ]] || fail 'TFO enabled status missing'
[[ "$OUTPUT" = *'当前: 1（已开启：入站 + 出站 ECN）'* ]] || fail 'ECN enabled status missing'
[[ "$OUTPUT" = *'当前: 1（已开启：ECN 异常时允许回退）'* ]] || fail 'ECN fallback status missing'
[[ "$OUTPUT" = *'当前: 1（已开启按需模式：检测到黑洞后探测）'* ]] || fail 'MTU on-demand mode shown as disabled'
[[ "$OUTPUT" = *'已保存: 3 · 首次基线: 1'* ]] || fail 'saved/baseline values lost'
[ "$(printf '%s\n' "$OUTPUT" | grep -c '推荐:')" = 4 ] || fail 'recommendations missing'
[[ "$OUTPUT" = *'推荐: 3（客户端 + 服务端；需应用支持）'* ]] || fail 'TFO recommendation missing'
[[ "$OUTPUT" = *'推荐: 1（主动启用增强时；配合 fallback=1）'* ]] || fail 'ECN recommendation lost compatibility context'
[[ "$OUTPUT" = *'推荐: 1（允许异常回退；ECN 关闭时不生效）'* ]] || fail 'fallback recommendation missing'
[[ "$OUTPUT" = *'推荐: 1（按需探测，非始终探测）'* ]] || fail 'MTU recommendation missing'
[ "$(bbr_tcp_value_description net.ipv4.tcp_fastopen 1)" = '仅客户端开启' ] || fail 'TFO client-only state'
[ "$(bbr_tcp_value_description net.ipv4.tcp_fastopen 2)" = '仅服务端开启' ] || fail 'TFO server-only state'
[ "$(bbr_tcp_value_description net.ipv4.tcp_ecn 2)" = '仅入站 ECN；出站不主动启用' ] || fail 'passive ECN state'
[ "$(bbr_tcp_value_description net.ipv4.tcp_mtu_probing 2)" = '始终探测' ] || fail 'MTU always-on state'
[[ "$(bbr_tcp_value_description net.ipv4.tcp_ecn 3)" = *AccECN* ]] || fail 'AccECN state'
[[ "$(bbr_tcp_value_description net.ipv4.tcp_ecn 4)" = *'出站 ECN'* ]] || fail 'mixed ECN state'
[[ "$(bbr_tcp_value_description net.ipv4.tcp_ecn 5)" = *'出站不主动启用'* ]] || fail 'passive AccECN state'
for GROUP in TFO ECN MTU; do
    for KEY in $(bbr_tcp_keys "$GROUP"); do
        [[ "$(bbr_tcp_value_description "$KEY" 0)" = 已关闭* ]] || fail "off status for $KEY"
    done
done
[[ "$(bbr_tcp_value_description net.ipv4.tcp_fastopen 1027)" = *'需核对 TFO 位标志'* ]] || fail 'advanced TFO flags misclassified'
[[ "$(bbr_tcp_value_description net.ipv4.tcp_ecn 99)" = 未知取值* ]] || fail 'unknown ECN value misclassified'
BBR_FAIL_READ=net.ipv4.tcp_fastopen
OUTPUT=$(bbr_tcp_status)
[[ "$OUTPUT" = *'当前: 不支持或不可读（无法判断开关状态）'* ]] || fail 'unreadable value shown as off'
BBR_FAIL_READ=''
(
    print_header() { printf '%s\n' "$1"; }
    bbr_tcp_set() { fail 'viewing/cancelling menu changed TCP settings'; }
    OUTPUT=$(bbr_tcp_menu <<< $'1\n0\n2\n0\n3\n0\n0')
    [[ "$OUTPUT" = *'启用（推荐 3：客户端 + 服务端）'* ]] || fail 'TFO action recommendation missing'
    [[ "$OUTPUT" = *'ECN=1 + fallback=1'* ]] || fail 'ECN action values missing'
    [[ "$OUTPUT" = *'ECN=0；保留 fallback=1'* ]] || fail 'ECN off action hides retained fallback'
    [[ "$OUTPUT" = *'启用按需探测（推荐 1）'* ]] || fail 'MTU action recommendation missing'
    [[ "$OUTPUT" = *'不代表每条连接已使用或一定提速'* ]] || fail 'kernel configuration caveat missing'
)
[ ! -s "$WRITE_LOG" ] || fail 'status display wrote sysctl values'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/display-before.conf" || fail 'status display changed saved config'
cmp -s "$BBR_BASELINE_FILE" "$TEST_CASE/display-before.baseline" || fail 'status display changed baseline'

fixture preferences
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
! bbr_config_has_key "$CONFIG" net.ipv4.tcp_ecn || fail 'default profile enabled ECN'
bbr_tcp_set TFO off >/dev/null || fail 'disable TFO'
bbr_tcp_set ECN on >/dev/null || fail 'enable ECN pair'
[ "$(sysctl -n net.ipv4.tcp_ecn)" = 1 ] || fail 'ECN did not enable'
[ "$(sysctl -n net.ipv4.tcp_ecn_fallback)" = 1 ] || fail 'ECN fallback did not enable'
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
[ "$(bbr_config_value "$CONFIG" net.ipv4.tcp_fastopen)" = 0 ] || fail 'preset lost TFO off'
[ "$(bbr_config_value "$CONFIG" net.ipv4.tcp_ecn)" = 1 ] || fail 'preset lost ECN on'
bbr_apply_sysctl "$CONFIG" baseline >/dev/null || fail 'preset with enhancement preferences'
bbr_tcp_set TFO system >/dev/null || fail 'restore original TFO'
[ "$(sysctl -n net.ipv4.tcp_fastopen)" = 1 ] || fail 'TFO baseline replaced by tuned value'
bbr_tcp_set ECN system >/dev/null || fail 'restore ECN pair'
[ "$(sysctl -n net.ipv4.tcp_ecn)" = 2 ] || fail 'ECN original value lost'
[ "$(sysctl -n net.ipv4.tcp_ecn_fallback)" = 0 ] || fail 'fallback original value lost'
CONFIG=$(bbr_generate_config 16384 16384 4096 10 throughput 0)
! bbr_config_has_key "$CONFIG" net.ipv4.tcp_fastopen || fail 'preset took over restored TFO'
! bbr_config_has_key "$CONFIG" net.ipv4.tcp_ecn || fail 'preset took over restored ECN'
bbr_apply_sysctl "$CONFIG" baseline >/dev/null || fail 'preset after restore'
[ "$(sysctl -n net.ipv4.tcp_fastopen)" = 1 ] || fail 'restored TFO changed on next preset'
bbr_tcp_set MTU off >/dev/null || fail 'disable MTU'
bbr_tcp_set MTU on >/dev/null || fail 'enable MTU'
bbr_tcp_set MTU system >/dev/null || fail 'restore MTU'
[ "$(sysctl -n net.ipv4.tcp_mtu_probing)" = 0 ] || fail 'MTU did not restore original value'

fixture missing_fallback
mv "$(bbr_sysctl_path net.ipv4.tcp_ecn_fallback)" "$TEST_CASE/absent-fallback"
! bbr_tcp_set ECN on >/dev/null 2>&1 || fail 'enabled ECN without supported fallback'
[ ! -s "$WRITE_LOG" ] || fail 'unsupported pair changed runtime'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/original.conf" || fail 'unsupported pair changed persistence'

fixture backup_preferences
bbr_tcp_set ECN on >/dev/null || fail 'prepare backup preferences'
bbr_tcp_set TFO system >/dev/null || fail 'prepare unmanaged TFO backup'
bbr_backup_sysctl >/dev/null || fail 'backup preferences'
bbr_tcp_set ECN off >/dev/null || fail 'change after backup'
bbr_tcp_set TFO on >/dev/null || fail 'change TFO after backup'
printf '1\n' | bbr_restore_sysctl >/dev/null || fail 'restore preferences snapshot'
[ "$(sysctl -n net.ipv4.tcp_ecn)" = 1 ] || fail 'backup lost enabled ECN'
[ "$(sysctl -n net.ipv4.tcp_fastopen)" = 1 ] || fail 'backup lost original TFO runtime'
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
[ "$(bbr_config_value "$CONFIG" net.ipv4.tcp_ecn)" = 1 ] || fail 'backup lost ECN management preference'
! bbr_config_has_key "$CONFIG" net.ipv4.tcp_fastopen || fail 'backup lost TFO system preference'

fixture preset_missing_fallback
bbr_tcp_set ECN on >/dev/null || fail 'initial ECN setting'
mv "$(bbr_sysctl_path net.ipv4.tcp_ecn_fallback)" "$TEST_CASE/absent-fallback"
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
: > "$WRITE_LOG"
! bbr_apply_sysctl "$CONFIG" baseline >/dev/null 2>&1 || fail 'preset accepted half an ECN pair'
[ ! -s "$WRITE_LOG" ] || fail 'incomplete preset changed runtime'

fixture isolated_toggle
printf 'fq\n' > "$(bbr_sysctl_path net.core.default_qdisc)"
bbr_tcp_set ECN on >/dev/null || fail 'isolated ECN change'
[ "$(sysctl -n net.core.default_qdisc)" = fq ] || fail 'enhancement reverted unrelated runtime drift'
! grep -q net.core.default_qdisc "$WRITE_LOG" || fail 'enhancement wrote an unrelated key'

fixture legacy_baseline
printf 'net.ipv4.tcp_ecn = 1\n' >> "$SYSCTL_FILE"
printf '1\n' > "$(bbr_sysctl_path net.ipv4.tcp_ecn)"
bbr_ensure_baseline
! bbr_baseline_value net.ipv4.tcp_ecn >/dev/null || fail 'legacy tuned value presented as original ECN'
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
bbr_apply_sysctl "$CONFIG" baseline >/dev/null || fail 'legacy ECN migration'
[ "$(sysctl -n net.ipv4.tcp_ecn)" = 1 ] || fail 'legacy ECN baseline was guessed'

fixture pair_rollback
BBR_FAIL_WRITE='net.ipv4.tcp_ecn_fallback=1'
! bbr_tcp_set ECN on >/dev/null 2>&1 || fail 'accepted ECN fallback write failure'
[ "$(sysctl -n net.ipv4.tcp_ecn)" = 2 ] || fail 'failed pair did not restore ECN'
[ "$(sysctl -n net.ipv4.tcp_ecn_fallback)" = 0 ] || fail 'failed pair changed fallback'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/original.conf" || fail 'failed pair persisted'
[ ! -d "${SYSCTL_FILE}.lock" ] || fail 'failed transaction leaked lock'

fixture retired_cleanup
mkdir -p "$BBR_PROC_SYS/vm"
printf '262144\n' > "$BBR_PROC_SYS/vm/min_free_kbytes"
printf '1\n' > "$BBR_PROC_SYS/net/ipv4/tcp_tw_reuse"
printf 'vm.min_free_kbytes = 262144\nnet.ipv4.tcp_tw_reuse = 1\n' >> "$SYSCTL_FILE"
printf 'vm.min_free_kbytes = 32768\nnet.ipv4.tcp_tw_reuse = 2\n' > "$BBR_BASELINE_FILE"
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
bbr_apply_sysctl "$CONFIG" baseline >/dev/null || fail 'retired parameter migration'
[ "$(sysctl -n vm.min_free_kbytes)" = 32768 ] || fail 'retired min_free_kbytes not restored'
[ "$(sysctl -n net.ipv4.tcp_tw_reuse)" = 2 ] || fail 'retired tcp_tw_reuse not restored'
! bbr_config_has_key "$(cat "$SYSCTL_FILE")" vm.min_free_kbytes || fail 'retired memory value persisted'
! bbr_config_has_key "$(cat "$SYSCTL_FILE")" net.ipv4.tcp_tw_reuse || fail 'retired TCP value persisted'

fixture noncore_readback
BBR_IGNORE_WRITE='net.core.wmem_max=8192'
CONFIG=$'net.core.rmem_max = 8192\nnet.core.wmem_max = 8192'
! bbr_apply_sysctl "$CONFIG" preserve >/dev/null 2>&1 || fail 'noncore readback mismatch accepted'
[ "$(sysctl -n net.core.rmem_max)" = 4096 ] || fail 'noncore mismatch did not roll back earlier write'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/original.conf" || fail 'mismatch persisted'

fixture final_readback
CONFIG=$'net.core.rmem_max = 8192\nnet.core.wmem_max = 8192'
BBR_SIDE_EFFECT='net.core.wmem_max=8192'
! bbr_apply_sysctl "$CONFIG" preserve >/dev/null 2>&1 || fail 'side effect escaped final verification'
[ "$(sysctl -n net.core.rmem_max)" = 4096 ] || fail 'side effect not restored'
[ "$(sysctl -n net.core.wmem_max)" = 4096 ] || fail 'side effect transaction partly persisted'

fixture save_failure
(
    # shellcheck disable=SC2329 # inject failure only at the final persistent rename
    mv() { [ "${2:-}" != "$SYSCTL_FILE" ] || return 1; command mv "$@"; }
    ! bbr_tcp_set TFO on >/dev/null 2>&1 || fail 'save failure accepted'
)
[ "$(sysctl -n net.ipv4.tcp_fastopen)" = 1 ] || fail 'save failure did not roll back runtime'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/original.conf" || fail 'save failure replaced config'

fixture interrupted
BBR_SIGNAL='net.ipv4.tcp_fastopen=3'
! bbr_tcp_set TFO on >/dev/null 2>&1 || fail 'interrupted apply reported success'
[ "$(sysctl -n net.ipv4.tcp_fastopen)" = 1 ] || fail 'interruption did not roll back runtime'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/original.conf" || fail 'interruption committed config'
[ ! -d "${SYSCTL_FILE}.lock" ] || fail 'interruption leaked lock'

fixture restore_save_failure
bbr_tcp_set ECN on >/dev/null || fail 'prepare restore failure'
cp "$SYSCTL_FILE" "$TEST_CASE/before-restore.conf"
(
    # shellcheck disable=SC2329 # failing restore must keep the previously enabled pair
    mv() { [ "${2:-}" != "$SYSCTL_FILE" ] || return 1; command mv "$@"; }
    ! bbr_tcp_set ECN system >/dev/null 2>&1 || fail 'restore-save failure accepted'
)
[ "$(sysctl -n net.ipv4.tcp_ecn)" = 1 ] || fail 'failed restore left runtime at baseline'
[ "$(sysctl -n net.ipv4.tcp_ecn_fallback)" = 1 ] || fail 'failed restore split ECN pair'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/before-restore.conf" || fail 'failed restore lost preferences'

fixture stage_failure
(
    # shellcheck disable=SC2329 # staging must fail before any runtime write
    mktemp() { case "${1:-}" in "${SYSCTL_FILE}.tmp."*) return 1 ;; *) command mktemp "$@" ;; esac; }
    ! bbr_tcp_set ECN on >/dev/null 2>&1 || fail 'stage failure accepted'
)
[ ! -s "$WRITE_LOG" ] || fail 'stage failure modified runtime'

fixture missing_baseline
printf 'net.ipv4.tcp_fastopen = 3\n' >> "$SYSCTL_FILE"
! bbr_tcp_set TFO system >/dev/null 2>&1 || fail 'restore guessed a missing baseline'
[ ! -s "$WRITE_LOG" ] || fail 'missing baseline changed runtime'

fixture optional_unsupported
bbr_apply_sysctl $'net.core.rmem_max = 8192\nnet.ipv4.not_a_real_key = 1' preserve >/dev/null || fail 'optional unsupported key rejected entire profile'
grep -qx '# skipped unsupported: net.ipv4.not_a_real_key = 1' "$SYSCTL_FILE" || fail 'missing key not annotated'
BBR_FAIL_WRITE='net.core.rmem_max=16384'
OUTPUT=$(bbr_apply_sysctl 'net.core.rmem_max = 16384' preserve 2>&1) && fail 'permission failure accepted'
[[ "$OUTPUT" = *'无写入权限'* ]] || fail 'permission failure mislabeled as unsupported'

fixture whitespace_and_duplicates
bbr_apply_sysctl $'net.ipv4.tcp_rmem = 4096\t131072\t8192\nnet.core.rmem_max = 8192\nnet.core.rmem_max = 16384' preserve >/dev/null || fail 'whitespace or duplicate normalization'
[ "$(bbr_config_value "$(cat "$SYSCTL_FILE")" net.core.rmem_max)" = 16384 ] || fail 'last assignment did not win'

fixture locked
(
    exec 8>>"${SYSCTL_FILE}.lock"
    flock -n 8 || fail 'acquire competing lock'
    ! bbr_tcp_set TFO on >/dev/null 2>&1 || fail 'concurrent apply ignored lock'
)
[ ! -s "$WRITE_LOG" ] || fail 'locked apply changed runtime'
bbr_tcp_set TFO on >/dev/null || fail 'released lock still blocks apply'

fixture legacy_directory_lock
mkdir "${SYSCTL_FILE}.lock"
OUTPUT=$(bbr_tcp_set TFO on 2>&1) && fail 'bypassed unidentifiable legacy owner'
[[ "$OUTPUT" = *'旧版 BBR 目录锁'* ]] || fail 'missing legacy lock recovery instructions'
[ ! -s "$WRITE_LOG" ] || fail 'legacy lock changed runtime'
rmdir "${SYSCTL_FILE}.lock"

fixture killed_lock
(
    # Kill only the transaction subshell, after lock acquisition and before writes.
    bbr_ensure_baseline() { sh -c 'kill -KILL "$PPID"'; }
    ! bbr_apply_sysctl 'net.ipv4.tcp_fastopen = 3' preserve >/dev/null 2>&1 || fail 'kill injection did not fire'
)
bbr_tcp_set TFO on >/dev/null || fail 'SIGKILL left a stale kernel lock'

fixture absent_restore
printf 'net.ipv4.tcp_adv_win_scale = 2\nnet.ipv6.conf.old0.accept_ra = 2\n' >> "$SYSCTL_FILE"
printf 'net.ipv4.tcp_adv_win_scale = 1\nnet.ipv6.conf.old0.accept_ra = 1\n' > "$BBR_BASELINE_FILE"
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
bbr_apply_sysctl "$CONFIG" baseline >/dev/null || fail 'obsolete restore blocked migration'
! grep -qE '^(net.ipv4.tcp_adv_win_scale|net.ipv6.conf.old0.accept_ra)=' "$WRITE_LOG" || fail 'wrote an absent restore key'
! bbr_config_has_key "$(cat "$SYSCTL_FILE")" net.ipv6.conf.old0.accept_ra || fail 'retained obsolete interface'

fixture restore_permission
printf 'vm.min_free_kbytes = 32768\n' > "$BBR_BASELINE_FILE"
mkdir -p "$BBR_PROC_SYS/vm"
printf '65536\n' > "$BBR_PROC_SYS/vm/min_free_kbytes"
printf 'vm.min_free_kbytes = 65536\n' >> "$SYSCTL_FILE"
cp "$SYSCTL_FILE" "$TEST_CASE/before.conf"
BBR_FAIL_WRITE=vm.min_free_kbytes=32768
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0)
! bbr_apply_sysctl "$CONFIG" baseline >/dev/null 2>&1 || fail 'restore permission failure was skipped'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/before.conf" || fail 'restore permission failure persisted'

fixture required_restore_missing
bbr_tcp_set ECN on >/dev/null
mv "$(bbr_sysctl_path net.ipv4.tcp_ecn_fallback)" "$TEST_CASE/absent-fallback"
: > "$WRITE_LOG"
! bbr_tcp_set ECN system >/dev/null 2>&1 || fail 'explicit restore silently dropped required key'
[ ! -s "$WRITE_LOG" ] || fail 'missing required restore changed runtime'

fixture ipv6_order
forwarding_fixture
CONFIG=$'# order regression\nnet.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.eth0.accept_ra = 2\n# VPS_TOOLS_TCP_ECN=system\nnet.ipv6.conf.default.accept_ra = 2'
bbr_apply_sysctl "$CONFIG" preserve >/dev/null || fail 'IPv6 forwarding apply'
[ "$(cat "$TEST_CASE/ra-route")" = present ] || fail 'apply purged the RA route'
grep -qx '# VPS_TOOLS_TCP_ECN=system' "$SYSCTL_FILE" || fail 'ordering lost management metadata'
# Simulate a reboot loader reading the saved file without the runtime planner.
forwarding_fixture
while IFS='=' read -r KEY VALUE; do
    KEY=$(printf '%s' "$KEY" | bbr_sysctl_normalize)
    VALUE=$(printf '%s' "$VALUE" | bbr_sysctl_normalize)
    case "$KEY" in ''|\#*) continue ;; esac
    sysctl -w "$KEY=$VALUE"
done < "$SYSCTL_FILE"
[ "$(cat "$TEST_CASE/ra-route")" = present ] || fail 'persistent order purged the RA route'

fixture ipv6_rollback
forwarding_fixture
printf '1\n' > "$BBR_PROC_SYS/net/ipv6/conf/wg0/forwarding"
printf '1\n' > "$BBR_PROC_SYS/net/ipv6/conf/eth0.100/forwarding"
BBR_FAIL_WRITE=net.core.wmem_max=8192
CONFIG=$'net.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.eth0.accept_ra = 2\nnet.core.wmem_max = 8192'
! bbr_apply_sysctl "$CONFIG" preserve >/dev/null 2>&1 || fail 'IPv6 failed apply succeeded'
for KEY in all default eth0; do
    [ "$(cat "$BBR_PROC_SYS/net/ipv6/conf/$KEY/forwarding")" = 0 ] || fail "IPv6 $KEY forwarding not restored"
done
[ "$(sysctl -n net.ipv6.conf.wg0.forwarding)" = 1 ] || fail 'mixed wg0 forwarding lost'
[ "$(sysctl -n net.ipv6.conf.eth0/100.forwarding)" = 1 ] || fail 'dotted interface forwarding lost'
[ "$(sysctl -n net.ipv6.conf.wg0.force_forwarding)" = 1 ] || fail 'force_forwarding lost'
[ "$(sysctl -n net.ipv6.conf.eth0.accept_ra)" = 1 ] || fail 'RA guard not restored'
[ "$(cat "$TEST_CASE/ra-route")" = present ] || fail 'rollback purged RA route'
cmp -s "$SYSCTL_FILE" "$TEST_CASE/original.conf" || fail 'IPv6 rollback persisted'

fixture ipv4_rollback
forwarding_fixture
printf '1\n' > "$BBR_PROC_SYS/net/ipv4/conf/wg0/forwarding"
BBR_FAIL_WRITE=net.core.wmem_max=8192
! bbr_apply_sysctl $'net.ipv4.ip_forward = 1\nnet.core.wmem_max = 8192' preserve >/dev/null 2>&1 || fail 'IPv4 failed apply succeeded'
[ "$(sysctl -n net.ipv4.conf.wg0.forwarding)" = 1 ] || fail 'IPv4 interface forwarding lost'
[ "$(sysctl -n net.ipv4.conf.all.accept_redirects)" = 0 ] || fail 'IPv4 redirect value lost'

fixture affected_unreadable
forwarding_fixture
BBR_FAIL_READ=net.ipv6.conf.wg0.forwarding
! bbr_apply_sysctl 'net.ipv6.conf.all.forwarding = 1' preserve >/dev/null 2>&1 || fail 'accepted missing affected snapshot value'
[ ! -s "$WRITE_LOG" ] || fail 'incomplete snapshot modified runtime'

fixture rollback_final_readback
printf '8192\n' > "$(bbr_sysctl_path net.core.rmem_max)"
printf '8192\n' > "$(bbr_sysctl_path net.core.wmem_max)"
printf 'net.core.rmem_max = 4096\nnet.core.wmem_max = 4096\n' > "$TEST_CASE/snapshot"
BBR_SIDE_EFFECT=net.core.wmem_max=4096
! bbr_restore_runtime_snapshot "$TEST_CASE/snapshot" >/dev/null 2>&1 || fail 'rollback claimed success despite final mismatch'

fixture dotted_interface_profile
(
    bbr_default_ipv6_iface() { echo eth0.100; }
    CONFIG=$(bbr_generate_config 8192 8192 4096 10 relay 1)
    bbr_config_has_key "$CONFIG" net.ipv6.conf.eth0/100.accept_ra || fail 'dotted RA key not escaped'
)

fixture concurrent_change
! bbr_apply_sysctl 'net.ipv4.tcp_fastopen = 3' preserve '' net.ipv4.tcp_fastopen net.ipv4.tcp_fastopen 'stale config' >/dev/null 2>&1 || fail 'stale enhancement request overwrote newer config'
[ ! -s "$WRITE_LOG" ] || fail 'stale request wrote runtime'

fixture concurrent_preset
bbr_tcp_set TFO off >/dev/null
(
    bbr_preflight() { :; }
    bbr_backup_sysctl() { :; }
    # Change the file after the confirmation path captured its original version.
    bbr_generate_config() {
        bbr_tcp_set TFO on >/dev/null
        printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_fastopen = 0\n'
    }
    ! bbr_confirm_apply 8192 8192 4096 10 test test balanced <<< $'n\ny' >/dev/null 2>&1 || fail 'preset overwrote concurrent toggle'
)
[ "$(sysctl -n net.ipv4.tcp_fastopen)" = 3 ] || fail 'concurrent TFO preference lost'
[ "$(bbr_config_value "$(cat "$SYSCTL_FILE")" net.ipv4.tcp_fastopen)" = 3 ] || fail 'concurrent preference persistence lost'

fixture consistent_generation
ORIGINAL=$(cat "$SYSCTL_FILE")
bbr_tcp_set TFO off >/dev/null
CONFIG=$(bbr_generate_config 8192 8192 4096 10 balanced 0 "$ORIGINAL")
[ "$(bbr_config_value "$CONFIG" net.ipv4.tcp_fastopen)" = 3 ] || fail 'generation reread preferences outside captured version'

fixture diagnostics
mkdir -p "$TEST_CASE/etc" "$TEST_CASE/usr" "$BBR_PROC_NET"
export BBR_SYSCTL_DIRS="$TEST_CASE/etc:$TEST_CASE/usr"
BBR_SYSCTL_MAIN="$TEST_CASE/sysctl.conf"
printf 'net.core.default_qdisc = cake\n' > "$TEST_CASE/usr/10-vendor.conf"
ln -s /dev/null "$TEST_CASE/etc/10-vendor.conf"
printf 'net/core/default_qdisc = fq\n-net.ipv4.tcp_* = 7\n' > "$TEST_CASE/etc/20-user.conf"
printf 'net.core.default_qdisc = fq_codel\n' > "$BBR_SYSCTL_MAIN"
OUTPUT=$(bbr_sysctl_conflicts)
[[ "$OUTPUT" != *'cake'* ]] || fail 'masked vendor file reported as effective'
[[ "$OUTPUT" = *'20-user.conf:1'* && "$OUTPUT" = *'20-user.conf:2'* ]] || fail 'slash or glob assignment not identified'
[[ "$OUTPUT" = *'重复同值'* && "$OUTPUT" = *'不同值'* ]] || fail 'conflict values not classified'
printf 'Tcp: OutSegs RetransSegs\nTcp: 1000 12\n' > "$BBR_PROC_NET/snmp"
printf 'TcpExt: ListenOverflows ListenDrops TCPSynRetrans TCPTimeouts\nTcpExt: 3 4 5 6\n' > "$BBR_PROC_NET/netstat"
printf '00000001 0000000a 0000000b\n00000002 00000001 00000002\n' > "$BBR_PROC_NET/softnet_stat"
OUTPUT=$(bbr_network_counters)
[[ "$OUTPUT" = *'RetransSegs: 12'* && "$OUTPUT" = *'ListenOverflows: 3'* ]] || fail 'TCP counter parsing'
[[ "$OUTPUT" = *'接收队列丢包 11'* && "$OUTPUT" = *'轮询预算耗尽 13'* ]] || fail 'softnet hex counters'
OUTPUT=$(bbr_sysctl_drift)
[[ "$OUTPUT" = *'一致'* ]] || fail 'false config drift'
printf 'fq\n' > "$(bbr_sysctl_path net.core.default_qdisc)"
OUTPUT=$(bbr_sysctl_drift)
[[ "$OUTPUT" = *'已保存 fq_codel / 当前 fq'* ]] || fail 'missing actual drift'
[ ! -s "$WRITE_LOG" ] || fail 'diagnostics wrote sysctl'
(
    # shellcheck disable=SC2329 # complete diagnostic must never probe with a sysctl write
    has_sysctl_write() { fail 'diagnostic attempted a write-permission probe'; }
    default_iface() { echo eth0; }
    systemd_available() { return 1; }
    tc() { printf 'qdisc fq 0: root\n Sent 1000 bytes 10 pkt (dropped 0)\n'; }
    OUTPUT=$(bbr_diagnose)
    [[ "$OUTPUT" = *'qdisc fq 0: root'* && "$OUTPUT" = *'RetransSegs: 12'* ]] || fail 'full diagnostic omitted actual queue/counters'
)
[ ! -s "$WRITE_LOG" ] || fail 'full diagnostic wrote sysctl'

echo 'BBR enhancement and transaction tests passed.'
