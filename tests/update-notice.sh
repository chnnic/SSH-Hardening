#!/usr/bin/env bash
# Offline fixtures: no real network calls or host update-cache modifications.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"
VPS_UPDATE_CACHE="$TMP/latest-version"
MOCK_LOG="$TMP/curl.log"
: > "$MOCK_LOG"
export APP_VERSION=V3.12.7
MOCK_CURL_STATUS=0
MOCK_REMOTE_SCRIPT='APP_VERSION="V3.12.8"'
fail() { echo "Update notice test failed: $*" >&2; exit 1; }
# shellcheck disable=SC2329 # called by the background-check function
curl() {
    printf 'called\n' >> "$MOCK_LOG"
    printf '%s\n' "$MOCK_REMOTE_SCRIPT"
    return "$MOCK_CURL_STATUS"
}

# Numerical comparison, not unequal strings or lexicographic sorting.
self_version_newer V3.12.10 V3.12.9 || fail 'patch comparison'
self_version_newer V3.13.0 V3.12.99 || fail 'minor comparison'
self_version_newer V4.0.0 V3.99.99 || fail 'major comparison'
! self_version_newer V3.12.7 V3.12.7 || fail 'identical versions are newer'
! self_version_newer v3.12.07 V3.12.7 || fail 'equivalent formatting is newer'
! self_version_newer V3.12 V3.12.0 || fail 'two-part versions are not equivalent'
! self_version_newer V3.12.9 V3.12.10 || fail 'old patch is newer'
for INVALID in '' unknown V3.12.9-beta $'V3.12.9\ninvalid' $'V3.12.9\033[31m' V3.12.9999999999; do
    ! self_version_newer "$INVALID" V3.12.7 || fail 'invalid version accepted'
done

# Reproduce the reported screenshot: equal-version stale cache, no Internet.
printf 'V3.12.7\n' > "$VPS_UPDATE_CACHE"
MOCK_CURL_STATUS=28
[ -z "$(self_update_notice)" ] || fail 'same-version cache displayed before network check'
[ ! -s "$MOCK_LOG" ] || fail 'rendering the banner made a network request'
self_check_update
[ ! -e "$VPS_UPDATE_CACHE" ] || fail 'same-version cache survives offline check'
[ -z "$(self_update_notice)" ] || fail 'same-version offline banner persists'

printf 'V3.12.6\n' > "$VPS_UPDATE_CACHE"
[ -z "$(self_update_notice)" ] || fail 'old cached version displayed'
self_check_update
[ ! -e "$VPS_UPDATE_CACHE" ] || fail 'old offline cache not cleared'

# A genuinely newer previously checked version can still be shown offline.
printf 'V3.12.8\n' > "$VPS_UPDATE_CACHE"
self_check_update
[ "$(self_cached_update_version)" = V3.12.8 ] || fail 'valid newer offline cache lost'

# Revalidate on every render, including a late write by an older process.
APP_VERSION=V3.12.8
[ -z "$(self_update_notice)" ] || fail 'upgraded running version sees stale notice'
APP_VERSION=V3.12.7
MOCK_CURL_STATUS=0
MOCK_REMOTE_SCRIPT=$'# VPS 开荒脚本 V99.99.99\nAPP_VERSION="V3.12.7"'
self_check_update
[ ! -e "$VPS_UPDATE_CACHE" ] || fail 'comment version overrode APP_VERSION'
MOCK_REMOTE_SCRIPT='APP_VERSION="V3.12.6"'
self_check_update
[ -z "$(self_update_notice)" ] || fail 'older CDN response shown as update'

# $0 is this test file, not the installed script; the loaded version is truth.
MOCK_REMOTE_SCRIPT='APP_VERSION="V3.12.10"'
self_check_update
[ "$(self_cached_update_version)" = V3.12.10 ] || fail 'new remote version not cached'
[[ "$(self_update_notice)" = *'新版本 V3.12.10 可用'* ]] || fail 'genuine update missing'
[ "$(find "$TMP" -name '*.tmp.*' | wc -l | tr -d ' ')" = 0 ] || fail 'cache staging file leaked'

for MOCK_REMOTE_SCRIPT in '<html>unavailable</html>' $'APP_VERSION="V3.12.8"\nAPP_VERSION="V9.0.0"'; do
    self_check_update
    [ "$(self_cached_update_version)" = V3.12.10 ] || fail 'invalid response replaced validated cache'
done
MOCK_REMOTE_SCRIPT='APP_VERSION="V9.0.0"'
MOCK_CURL_STATUS=18
self_check_update
[ "$(self_cached_update_version)" = V3.12.10 ] || fail 'partial failed download changed cache'

printf 'invalid\033[31m\n' > "$VPS_UPDATE_CACHE"
[ -z "$(self_update_notice)" ] || fail 'invalid cache was rendered'
self_check_update
[ ! -e "$VPS_UPDATE_CACHE" ] || fail 'invalid cache survives offline check'

# Atomic cache writes must not follow a symlink to an unrelated file.
printf 'do-not-overwrite\n' > "$TMP/unrelated"
ln -s "$TMP/unrelated" "$VPS_UPDATE_CACHE"
MOCK_CURL_STATUS=0
MOCK_REMOTE_SCRIPT='APP_VERSION="V3.12.8"'
self_check_update
[ "$(cat "$TMP/unrelated")" = do-not-overwrite ] || fail 'cache write followed symlink'
[ ! -L "$VPS_UPDATE_CACHE" ] || fail 'cache symlink not replaced safely'

# Exercise the real main-menu rendering with isolated status providers.
(
    # shellcheck disable=SC2034 # consumed by production menu
    TC_STATE_FILE="$TMP/no-tc.state"
    get_config() { case "$1" in Port) echo 58585 ;; PasswordAuthentication) echo no ;; *) echo yes ;; esac; }
    ssh_key_count() { echo 2; }
    f2b_status() { echo running; }
    fw_detect() { echo none; }
    sysctl() { echo bbr; }
    default_iface() { echo eth0; }
    bbr_tc_rate_display() { echo 2048Mbit; }
    caddy_status() { echo not_installed; }
    ddns_status() { echo not_installed; }
    docker_status() { echo running; }
    timedatectl() { echo Asia/Shanghai; }
    audit_action() { :; }
    safe_clear() { :; }
    printf 'V3.12.7\n' > "$VPS_UPDATE_CACHE"
    OUTPUT=$(main_menu <<< 0)
    [[ "$OUTPUT" != *'新版本'* ]] || fail 'main menu displayed same-version cache'
    printf 'V3.12.8\n' > "$VPS_UPDATE_CACHE"
    OUTPUT=$(main_menu <<< 0)
    [[ "$OUTPUT" = *'新版本 V3.12.8 可用'* ]] || fail 'main menu lost real update notice'
)
echo 'Update notice and offline-cache tests passed.'
