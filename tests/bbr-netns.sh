#!/usr/bin/env bash
# Real Linux-kernel regression checks. Never run in the host network namespace.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ "${1:-}" != --inside ]; then
    [ "$(uname -s)" = Linux ] || { echo 'SKIP: BBR netns tests require Linux.'; exit 0; }
    for TOOL in unshare ip sysctl python3 flock; do
        command -v "$TOOL" >/dev/null || { echo "Missing test dependency: $TOOL" >&2; exit 1; }
    done
    exec unshare --net -- bash "$0" --inside
fi
[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ] || {
    echo 'Refusing to modify the host network namespace.' >&2
    exit 1
}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"
SYSCTL_FILE="$TMP/bbr.conf"
export BBR_BASELINE_FILE="$TMP/baseline.conf"
export TC_STATE_FILE="$TMP/no-tc.state"
export TMPDIR="$TMP"
fail() { echo "BBR netns test failed: $*" >&2; exit 1; }

# These sysctls are all network-namespaced. The production apply inputs below
# also contain network keys only; baseline reads do not change global settings.
sysctl -qw net.ipv6.conf.all.forwarding=0 net.ipv6.conf.default.forwarding=0
sysctl -qw net.ipv6.conf.default.accept_ra=1 net.ipv6.conf.default.accept_dad=0
ip link add eth0 type veth peer name ra-peer
ip link add wg0 type veth peer name wg-peer
for DEV in lo eth0 ra-peer wg0 wg-peer; do ip link set "$DEV" up; done

advertise() {
    # Send a genuine Router Advertisement over the isolated veth pair. The
    # gateway is not assigned locally, so accept_ra_from_local remains disabled.
    python3 - <<'PY'
import json
import socket
import struct
import subprocess
import time

link = json.loads(subprocess.check_output(['ip', '-j', 'link', 'show', 'ra-peer']))[0]
mac = bytes.fromhex(link['address'].replace(':', ''))
src = socket.inet_pton(socket.AF_INET6, 'fe80::1234')
dst = socket.inet_pton(socket.AF_INET6, 'ff02::1')
body = struct.pack('!BBHBBHII', 134, 0, 0, 64, 0, 1800, 0, 0) + b'\x01\x01' + mac
pseudo = src + dst + struct.pack('!I3xB', len(body), 58)
words = struct.unpack('!%dH' % ((len(pseudo) + len(body)) // 2), pseudo + body)
checksum = sum(words)
while checksum >> 16:
    checksum = (checksum & 0xffff) + (checksum >> 16)
body = body[:2] + struct.pack('!H', (~checksum) & 0xffff) + body[4:]
packet = b'\x33\x33\x00\x00\x00\x01' + mac + b'\x86\xdd'
packet += struct.pack('!IHBB16s16s', 6 << 28, len(body), 58, 255, src, dst) + body
with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x86dd)) as sock:
    sock.bind(('ra-peer', 0))
    for _ in range(3):
        sock.send(packet)
        time.sleep(0.1)
PY
    ip -6 route show default dev eth0 | grep -q 'via fe80::1234' || fail 'test RA did not install a route'
}

advertise
CONFIG=$'net.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.eth0.accept_ra = 2\nnet.ipv6.conf.default.accept_ra = 2'
bbr_apply_sysctl "$CONFIG" preserve >/dev/null || fail 'apply forwarding profile'
ip -6 route show default dev eth0 | grep -q 'via fe80::1234' || fail 'runtime planner purged RA route'

# Check the actual persistent-loader order, not just the runtime planner.
sysctl -qw net.ipv6.conf.all.forwarding=0 net.ipv6.conf.eth0.accept_ra=1
advertise
sysctl -p "$SYSCTL_FILE" >/dev/null
ip -6 route show default dev eth0 | grep -q 'via fe80::1234' || fail 'saved config purged RA route'

# A failed transaction must restore mixed interface forwarding and RA routes.
sysctl -qw net.ipv6.conf.all.forwarding=0 net.ipv6.conf.eth0.accept_ra=1 net.ipv6.conf.default.accept_ra=1
sysctl -qw net.ipv6.conf.wg0.forwarding=1 net.ipv4.tcp_fastopen=1
advertise
cp "$SYSCTL_FILE" "$TMP/original.conf"
(
    # shellcheck disable=SC2329 # called by production helper
    sysctl() {
        [ "${1:-} ${2:-}" != '-w net.ipv4.tcp_fastopen=3' ] || return 1
        command sysctl "$@"
    }
    CONFIG=$'net.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.eth0.accept_ra = 2\nnet.ipv4.tcp_fastopen = 3'
    ! bbr_apply_sysctl "$CONFIG" preserve > "$TMP/rollback.log" 2>&1 || fail 'failure injection accepted'
)
[ "$(sysctl -n net.ipv6.conf.all.forwarding)" = 0 ] || fail 'global forwarding not restored'
[ "$(sysctl -n net.ipv6.conf.default.forwarding)" = 0 ] || fail 'default forwarding not restored'
[ "$(sysctl -n net.ipv6.conf.eth0.forwarding)" = 0 ] || fail 'eth0 forwarding not restored'
[ "$(sysctl -n net.ipv6.conf.wg0.forwarding)" = 1 ] || fail 'wg0 forwarding not restored'
[ "$(sysctl -n net.ipv6.conf.eth0.accept_ra)" = 1 ] || fail 'temporary RA guard not restored'
ip -6 route show default dev eth0 | grep -q 'via fe80::1234' || fail 'rollback purged RA route'
cmp -s "$SYSCTL_FILE" "$TMP/original.conf" || fail 'failed transaction changed persistent config'
grep -q '本次运行参数修改已回滚' "$TMP/rollback.log" || { cat "$TMP/rollback.log"; fail 'rollback was incomplete'; }
echo 'BBR real-kernel network namespace tests passed.'
