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
    local KEY="${2%%=*}" VALUE="${2#*=}" PATHNAME
    PATHNAME=$(bbr_sysctl_path "$KEY")
    [ -f "$PATHNAME" ] || return 1
    case "$1" in
        -n) cat "$PATHNAME" ;;
        -w)
            printf '%s\n' "$2" >> "$WRITE_LOG"
            [ "$2" != "$BBR_FAIL_WRITE" ] || { echo 'permission denied' >&2; return 1; }
            [ "$2" != "$BBR_IGNORE_WRITE" ] || return 0
            printf '%s\n' "$VALUE" > "$PATHNAME"
            [ "$2" != "$BBR_SIGNAL" ] || sh -c 'kill -TERM "$PPID"'
            if [ "$2" = "$BBR_SIDE_EFFECT" ]; then
                printf '9\n' > "$(bbr_sysctl_path net.core.rmem_max)"
            fi
            ;;
        *) return 1 ;;
    esac
}

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
mkdir "${SYSCTL_FILE}.lock"
! bbr_tcp_set TFO on >/dev/null 2>&1 || fail 'concurrent apply ignored lock'
[ ! -s "$WRITE_LOG" ] || fail 'locked apply changed runtime'
rmdir "${SYSCTL_FILE}.lock"

fixture concurrent_change
! bbr_apply_sysctl 'net.ipv4.tcp_fastopen = 3' preserve '' net.ipv4.tcp_fastopen net.ipv4.tcp_fastopen 'stale config' >/dev/null 2>&1 || fail 'stale enhancement request overwrote newer config'
[ ! -s "$WRITE_LOG" ] || fail 'stale request wrote runtime'

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
