#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export VPS_TOOLS_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"

confirm_change_preview "test" "reject" <<< "n" >/dev/null 2>&1 && { echo "Preview accepted rejection" >&2; exit 1; }
confirm_change_preview "test" "accept" <<< "y" >/dev/null 2>&1 || { echo "Preview rejected confirmation" >&2; exit 1; }

# Reinstall must reject container environments and malformed downloads.
systemd-detect-virt() { echo lxc; }
reinstall_is_container || { echo "Container detection did not reject LXC" >&2; exit 1; }
# shellcheck disable=SC2329 # test stub used indirectly by download helpers
curl() {
    local OUT="" PREV="" arg
    for arg in "$@"; do [ "$PREV" = "-o" ] && OUT="$arg"; PREV="$arg"; done
    printf 'if broken\n' > "$OUT"
}
reinstall_download_engine "$TMP/broken-reinstall.sh" >/dev/null 2>&1 && {
    echo "Malformed reinstall engine passed validation" >&2
    exit 1
}

# The Docker installer must reject malformed downloaded scripts.
docker_download_installer "$TMP/broken-docker.sh" >/dev/null 2>&1 && {
    echo "Malformed Docker installer passed validation" >&2
    exit 1
}
docker() { [ "$1" = "inspect" ] && printf '<no value>\n'; }
[ -z "$(docker_inspect_label fake-id com.docker.compose.project)" ] || {
    echo "Missing Compose label was treated as a real value" >&2
    exit 1
}

[ "$(docker_compose_basename 'https://example.com/path/app.yml?token=1')" = "app.yml" ] || {
    echo "Compose basename parsing failed" >&2
    exit 1
}
[ "$(docker_compose_basename 'https://example.com/path/unknown')" = "compose.yaml" ] || {
    echo "Compose default filename parsing failed" >&2
    exit 1
}

# A broken sshd validation must restore the previous configuration.
SSHD_CONFIG="$TMP/sshd_config"
LAST_SSHD_BACKUP="$TMP/sshd_config.bak"
printf 'Port 2222\n' > "$SSHD_CONFIG"
printf 'Port 22\n' > "$LAST_SSHD_BACKUP"
sshd() { return 1; }
restart_ssh() { return 0; }
apply_and_restart >/dev/null 2>&1 && { echo "Expected SSH validation failure" >&2; exit 1; }
grep -qx 'Port 22' "$SSHD_CONFIG" || { echo "SSH rollback did not restore backup" >&2; exit 1; }

# A tar failure must not leave a partial backup archive.
VPS_DATA_DIR="$TMP/data"
VPS_BACKUP_DIR="$VPS_DATA_DIR/backups"
export VPS_AUDIT_LOG="$TMP/audit.log"
# shellcheck disable=SC2329 # test stub overrides the sourced function for config_backup_create
config_backup_paths() { printf 'tmp/does-not-exist-vps-tools-test\n'; }
config_backup_create injected_failure true >/dev/null 2>&1 && { echo "Expected backup failure" >&2; exit 1; }
if find "$VPS_BACKUP_DIR" -type f -name '*.tar.gz' 2>/dev/null | grep -q .; then
    echo "Partial backup archive was left behind" >&2
    exit 1
fi

# Retention must remove old archives after the configured limit.
mkdir -p "$TMP/source"
printf 'config\n' > "$TMP/source/value"
config_backup_paths() { printf '%s/source/value\n' "${TMP#/}"; }
export VPS_BACKUP_KEEP=2
config_backup_create one true >/dev/null
config_backup_create two true >/dev/null
config_backup_create three true >/dev/null
COUNT=$(find "$VPS_BACKUP_DIR" -type f -name '*.tar.gz' | wc -l | tr -d ' ')
[ "$COUNT" -eq 2 ] || { echo "Backup retention kept $COUNT archives instead of 2" >&2; exit 1; }

# Export/import helpers must validate paths and write archives to a caller-specified destination.
EXPORT_PATH="$TMP/exported-config.tar.gz"
config_export_archive "$EXPORT_PATH" test >/dev/null || { echo "Export helper failed" >&2; exit 1; }
[ -f "$EXPORT_PATH" ] || { echo "Export helper did not create archive" >&2; exit 1; }
config_import_archive() { [ "$1" = "$EXPORT_PATH" ]; }
config_import_archive "$EXPORT_PATH" >/dev/null || { echo "Import helper failed" >&2; exit 1; }

# Imported archives may contain only the explicit VPS Tools configuration allowlist.
mkdir -p "$TMP/archive-source/etc"
printf 'not allowed\n' > "$TMP/archive-source/etc/passwd"
tar -czf "$TMP/malicious-config.tar.gz" -C "$TMP/archive-source" etc/passwd
config_archive_validate "$TMP/malicious-config.tar.gz" >/dev/null 2>&1 && {
    echo "Config import accepted a path outside the allowlist" >&2
    exit 1
}
mkdir -p "$TMP/archive-source/root"
printf 'valid\n' > "$TMP/archive-source/root/.vps-monitor"
tar -czf "$TMP/valid-config.tar.gz" -C "$TMP/archive-source" root/.vps-monitor
config_archive_validate "$TMP/valid-config.tar.gz" >/dev/null \
    || { echo "Config import rejected an allowlisted path" >&2; exit 1; }
(
    export CONFIG_RESTORE_ROOT="$TMP/restored-root"
    config_archive_extract "$TMP/valid-config.tar.gz" >/dev/null
    grep -qx valid "$CONFIG_RESTORE_ROOT/root/.vps-monitor" \
        || { echo "Allowlisted config archive was not restored" >&2; exit 1; }
)

# Firewall installation must never enable UFW when the SSH allow rule failed.
(
    UFW_LOG="$TMP/ufw.log"
    print_header() { :; }
    info() { :; }
    error() { :; }
    pkg_install() { return 0; }
    safety_arm() { return 0; }
    safety_confirm() { :; }
    get_config() { echo 2222; }
    ufw() {
        printf '%s\n' "$*" >> "$UFW_LOG"
        [ "$1 $2" != "allow 2222/tcp" ]
    }
    fw_install ufw >/dev/null 2>&1 && { echo "UFW install succeeded after SSH allow failure" >&2; exit 1; }
    ! grep -q -- '--force enable' "$UFW_LOG" || { echo "UFW was enabled without its SSH rule" >&2; exit 1; }
)

# Atomic replacement must leave the destination untouched when staging fails.
(
    SOURCE="$TMP/update-source"
    DEST="$TMP/update-dest"
    printf 'new\n' > "$SOURCE"
    printf 'old\n' > "$DEST"
    install() { return 1; }
    ! self_atomic_replace "$SOURCE" "$DEST" || { echo "Atomic update ignored install failure" >&2; exit 1; }
    grep -qx old "$DEST" || { echo "Atomic update damaged the current script" >&2; exit 1; }
)

# Caddy startup failure must propagate instead of reporting success.
(
    CADDYFILE="$TMP/Caddyfile"
    : > "$CADDYFILE"
    info() { :; }
    error() { :; }
    svc_is_active() { return 1; }
    svc_start() { return 1; }
    caddy() { [ "$1" = validate ]; }
    ! caddy_reload_config >/dev/null 2>&1 || { echo "Caddy reload hid a startup failure" >&2; exit 1; }
)

# Fail2ban DEFAULT changes must not rewrite the same key in another jail.
(
    export F2B_JAIL_LOCAL="$TMP/jail.local"
    cat > "$F2B_JAIL_LOCAL" <<'EOF'
[DEFAULT]
bantime = 3600
[sshd]
bantime = 120
enabled = true
EOF
    fail2ban-client() { return 0; }
    f2b_set_param bantime 7200 >/dev/null
    [ "$(awk '/^\[DEFAULT\]/{s=1;next} /^\[/{s=0} s && /^bantime/{print $3}' "$F2B_JAIL_LOCAL")" = 7200 ] || exit 1
    [ "$(awk '/^\[sshd\]/{s=1;next} /^\[/{s=0} s && /^bantime/{print $3}' "$F2B_JAIL_LOCAL")" = 120 ] \
        || { echo "Fail2ban DEFAULT update changed sshd override" >&2; exit 1; }
)

# DDNS cron write errors must propagate.
(
    crontab() { return 1; }
    ! ddns_install_cron_job '* * * * * /root/ddns.sh' >/dev/null 2>&1 \
        || { echo "DDNS cron helper hid a write failure" >&2; exit 1; }
)
(
    CRONTAB_DATA="$TMP/ddns-cron-start"
    : > "$CRONTAB_DATA"
    crontab() {
        if [ "${1:-}" = -l ]; then cat "$CRONTAB_DATA"; elif [ "${1:-}" = - ]; then cat > "$CRONTAB_DATA"; else cp "$1" "$CRONTAB_DATA"; fi
    }
    ddns_start_cron_service() { return 1; }
    ! ddns_install_cron_job '* * * * * /root/ddns.sh # VPS_TOOLS_DDNS' >/dev/null 2>&1 \
        || { echo "DDNS cron helper accepted a stopped daemon" >&2; exit 1; }
    ! grep -Fq VPS_TOOLS_DDNS "$CRONTAB_DATA" || { echo "DDNS cron startup failure left a managed job" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-status-script"
    : > "$DDNS_SCRIPT"
    crontab() { [ "${1:-}" = -l ] && printf '* * * * * %s %s\n' "$DDNS_SCRIPT" "$DDNS_CRON_MARKER"; }
    ddns_cron_service_running() { return 1; }
    [ "$(ddns_status)" = cron_stopped ] || { echo "DDNS status hid a stopped cron daemon" >&2; exit 1; }
)

# DDNS local configuration changes must be fully reversible, including root crontab.
(
    DDNS_TX_TEST="$TMP/ddns-transaction"
    mkdir -p "$DDNS_TX_TEST"
    DDNS_SCRIPT="$DDNS_TX_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TX_TEST/cf-token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TX_TEST/huawei-keys"
    DDNS_ZONE_FILE="$DDNS_TX_TEST/zone"
    CRONTAB_DATA="$DDNS_TX_TEST/crontab"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-keys\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'old-zone\n' > "$DDNS_ZONE_FILE"
    printf '5 * * * * /usr/local/bin/unrelated\n' > "$CRONTAB_DATA"
    crontab() {
        if [ "${1:-}" = -l ]; then
            cat "$CRONTAB_DATA"
        elif [ "${1:-}" = - ]; then
            cat > "$CRONTAB_DATA"
        else
            cp "$1" "$CRONTAB_DATA"
        fi
    }
    ddns_install_tx_begin || { echo "DDNS transaction snapshot failed" >&2; exit 1; }
    printf 'new-script\n' > "$DDNS_SCRIPT"
    printf 'new-token\n' > "$DDNS_TOKEN_FILE"
    rm -f "$DDNS_HUAWEI_KEY_FILE"
    printf 'new-zone\n' > "$DDNS_ZONE_FILE"
    printf 'managed-cron\n' > "$CRONTAB_DATA"
    ddns_install_tx_restore || { echo "DDNS transaction rollback failed" >&2; exit 1; }
    grep -qx old-script "$DDNS_SCRIPT" || { echo "DDNS rollback did not restore the script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "DDNS rollback did not restore the Cloudflare token" >&2; exit 1; }
    grep -qx old-keys "$DDNS_HUAWEI_KEY_FILE" || { echo "DDNS rollback did not restore Huawei credentials" >&2; exit 1; }
    grep -qx old-zone "$DDNS_ZONE_FILE" || { echo "DDNS rollback did not restore provider config" >&2; exit 1; }
    grep -Fq /usr/local/bin/unrelated "$CRONTAB_DATA" || { echo "DDNS rollback did not restore crontab" >&2; exit 1; }
)

# Failed provider test runs must restore the previously working local configuration.
(
    DDNS_TEST="$TMP/ddns-cloudflare-rollback"
    mkdir -p "$DDNS_TEST"
    DDNS_SCRIPT="$DDNS_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TEST/cf-token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TEST/huawei-keys"
    DDNS_ZONE_FILE="$DDNS_TEST/zone"
    # shellcheck disable=SC2034 # consumed by the sourced DDNS installer
    DDNS_LOG="$DDNS_TEST/ddns.log"
    CRONTAB_DATA="$DDNS_TEST/crontab"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-huawei\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'PROVIDER=huawei\n' > "$DDNS_ZONE_FILE"
    printf '*/5 * * * * old-ddns\n' > "$CRONTAB_DATA"
    ddns_ensure_cron() { return 0; }
    ddns_start_cron_service() { return 0; }
    ddns_fetch_public_ip() { echo 198.51.100.10; }
    crontab() {
        if [ "${1:-}" = -l ]; then cat "$CRONTAB_DATA"; elif [ "${1:-}" = - ]; then cat > "$CRONTAB_DATA"; else cp "$1" "$CRONTAB_DATA"; fi
    }
    curl() {
        case "$*" in
            *'/zones?name=example.com'*) printf '%s\n' '{"success":true,"result":[{"id":"zone-id"}]}' ;;
            *'/dns_records?'*) printf '%s\n' '{"success":true,"result":[{"id":"record-id","type":"A","name":"home.example.com","content":"198.51.100.10"}]}' ;;
            *) return 1 ;;
        esac
    }
    bash() { [ "${1:-}" = -n ]; }
    ! ddns_install_cloudflare <<'EOF' >/dev/null 2>&1 || { echo "Cloudflare failed test run returned success" >&2; exit 1; }
example.com

home

token




EOF
    grep -qx old-script "$DDNS_SCRIPT" || { echo "Cloudflare failure did not restore the old script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "Cloudflare failure did not restore the old token" >&2; exit 1; }
    grep -qx old-huawei "$DDNS_HUAWEI_KEY_FILE" || { echo "Cloudflare failure removed Huawei credentials too early" >&2; exit 1; }
    grep -qx 'PROVIDER=huawei' "$DDNS_ZONE_FILE" || { echo "Cloudflare failure did not restore provider config" >&2; exit 1; }
    grep -Fq old-ddns "$CRONTAB_DATA" || { echo "Cloudflare failure did not restore crontab" >&2; exit 1; }
)
(
    DDNS_TEST="$TMP/ddns-huawei-rollback"
    mkdir -p "$DDNS_TEST"
    DDNS_SCRIPT="$DDNS_TEST/ddns.sh"
    DDNS_TOKEN_FILE="$DDNS_TEST/cf-token"
    DDNS_HUAWEI_KEY_FILE="$DDNS_TEST/huawei-keys"
    DDNS_ZONE_FILE="$DDNS_TEST/zone"
    # shellcheck disable=SC2034 # consumed by the sourced DDNS installer
    DDNS_LOG="$DDNS_TEST/ddns.log"
    CRONTAB_DATA="$DDNS_TEST/crontab"
    printf 'old-script\n' > "$DDNS_SCRIPT"
    printf 'old-token\n' > "$DDNS_TOKEN_FILE"
    printf 'old-huawei\n' > "$DDNS_HUAWEI_KEY_FILE"
    printf 'PROVIDER=cloudflare\n' > "$DDNS_ZONE_FILE"
    printf '*/5 * * * * old-ddns\n' > "$CRONTAB_DATA"
    ddns_ensure_cron() { return 0; }
    ddns_start_cron_service() { return 0; }
    crontab() {
        if [ "${1:-}" = -l ]; then cat "$CRONTAB_DATA"; elif [ "${1:-}" = - ]; then cat > "$CRONTAB_DATA"; else cp "$1" "$CRONTAB_DATA"; fi
    }
    bash() { [ "${1:-}" = -n ]; }
    ! ddns_install_huawei <<'EOF' >/dev/null 2>&1 || { echo "Huawei failed test run returned success" >&2; exit 1; }
example.com


home

test-ak
test-sk



EOF
    grep -qx old-script "$DDNS_SCRIPT" || { echo "Huawei failure did not restore the old script" >&2; exit 1; }
    grep -qx old-token "$DDNS_TOKEN_FILE" || { echo "Huawei failure removed Cloudflare credentials too early" >&2; exit 1; }
    grep -qx old-huawei "$DDNS_HUAWEI_KEY_FILE" || { echo "Huawei failure did not restore AK/SK" >&2; exit 1; }
    grep -qx 'PROVIDER=cloudflare' "$DDNS_ZONE_FILE" || { echo "Huawei failure did not restore provider config" >&2; exit 1; }
    grep -Fq old-ddns "$CRONTAB_DATA" || { echo "Huawei failure did not restore crontab" >&2; exit 1; }
)

# PID-lock fallback must recover stale locks and return 75 for a live owner.
DDNS_LOCK_HELPER="$TMP/ddns-lock-helper.sh"
awk 'p{print} /^acquire_lock\(\) \{/{p=1; print; next} p && /^}$/{exit}' "$ROOT/SSH-Hardening.sh" > "$DDNS_LOCK_HELPER"
(
    # shellcheck source=/dev/null
    source "$DDNS_LOCK_HELPER"
    LOCK_FILE="$TMP/ddns-stale.lockfile"
    LOCK_DIR="$TMP/ddns-stale.lock"
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then return 1; fi
        builtin command "$@"
    }
    mkdir -p "$LOCK_DIR"
    printf '99999999\n' > "$LOCK_DIR/pid"
    acquire_lock || { echo "DDNS did not recover a stale PID lock" >&2; exit 1; }
    grep -qx "$$" "$LOCK_DIR/pid" || { echo "DDNS stale lock owner was not replaced" >&2; exit 1; }
)
(
    # shellcheck source=/dev/null
    source "$DDNS_LOCK_HELPER"
    # shellcheck disable=SC2034 # consumed by the extracted acquire_lock helper
    LOCK_FILE="$TMP/ddns-live.lockfile"
    LOCK_DIR="$TMP/ddns-live.lock"
    command() {
        if [ "${1:-}" = -v ] && [ "${2:-}" = flock ]; then return 1; fi
        builtin command "$@"
    }
    mkdir -p "$LOCK_DIR"
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    if acquire_lock; then
        echo "DDNS accepted a live PID lock" >&2
        exit 1
    else
        RC=$?
    fi
    [ "$RC" -eq 75 ] || { echo "DDNS live lock did not return 75" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-running-script"
    DDNS_ZONE_FILE="$TMP/ddns-running-zone"
    cat > "$DDNS_SCRIPT" <<'EOF'
DOMAIN4="v4.example.com"
DOMAIN6=""
ENABLE_A="true"
ENABLE_AAAA="false"
EOF
    cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=
ENABLE_A=true
ENABLE_AAAA=false
EOF
    bash() { return 75; }
    OUTPUT=$(ddns_run_now)
    grep -Fq '已有一次 DDNS 更新正在运行' <<< "$OUTPUT" || { echo "DDNS manual run hid lock contention" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-dual-run-script"
    DDNS_ZONE_FILE="$TMP/ddns-dual-run-zone"
    DDNS_STATE_DIR="$TMP/ddns-dual-run-state"
    mkdir -p "$DDNS_STATE_DIR"
    cat > "$DDNS_SCRIPT" <<'EOF'
DOMAIN4="v4.example.com"
DOMAIN6="v6.example.com"
ENABLE_A="true"
ENABLE_AAAA="true"
EOF
    cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=v6.example.com
ENABLE_A=true
ENABLE_AAAA=true
EOF
    bash() {
        touch -d '1 second ago' "$RUN_MARK"
        printf '2026-08-02 12:00:00|A|v4.example.com|unchanged|198.51.100.10|198.51.100.10\n' > "$DDNS_STATE_DIR/.cf_last_status_A"
        printf '2026-08-02 12:00:01|AAAA|v6.example.com|updated|2001:4860::1|2001:4860::2\n' > "$DDNS_STATE_DIR/.cf_last_status_AAAA"
    }
    OUTPUT=$(ddns_run_now)
    grep -Fq '本次 IPv4:' <<< "$OUTPUT" || { echo "DDNS manual dual-stack run hid IPv4 status" >&2; exit 1; }
    grep -Fq 'A v4.example.com 未变化 198.51.100.10' <<< "$OUTPUT" || { echo "DDNS manual dual-stack IPv4 result is wrong" >&2; exit 1; }
    grep -Fq '本次 IPv6:' <<< "$OUTPUT" || { echo "DDNS manual dual-stack run hid IPv6 status" >&2; exit 1; }
    grep -Fq 'AAAA v6.example.com 更新成功 2001:4860::1 → 2001:4860::2' <<< "$OUTPUT" || { echo "DDNS manual dual-stack IPv6 result is wrong" >&2; exit 1; }
)
(
    DDNS_SCRIPT="$TMP/ddns-mismatch-script"
    DDNS_ZONE_FILE="$TMP/ddns-mismatch-zone"
    cat > "$DDNS_SCRIPT" <<'EOF'
DOMAIN4=""
DOMAIN6="v6.example.com"
ENABLE_A="false"
ENABLE_AAAA="true"
EOF
    cat > "$DDNS_ZONE_FILE" <<'EOF'
DOMAIN=v4.example.com
DOMAIN4=v4.example.com
DOMAIN6=v6.example.com
ENABLE_A=true
ENABLE_AAAA=true
EOF
    bash() { echo "runtime should not execute" >&2; return 1; }
    ! ddns_run_now >/dev/null 2>&1 || { echo "DDNS manual run accepted stale runtime config" >&2; exit 1; }
)

# Pause and uninstall must preserve DDNS when crontab removal fails.
(
    DDNS_SCRIPT="$TMP/ddns-preserve.sh"
    DDNS_TOKEN_FILE="$TMP/ddns-preserve-token"
    DDNS_HUAWEI_KEY_FILE="$TMP/ddns-preserve-huawei"
    DDNS_ZONE_FILE="$TMP/ddns-preserve-zone"
    : > "$DDNS_SCRIPT"
    : > "$DDNS_TOKEN_FILE"
    : > "$DDNS_HUAWEI_KEY_FILE"
    : > "$DDNS_ZONE_FILE"
    ddns_remove_cron_job() { return 1; }
    ! ddns_pause >/dev/null 2>&1 || { echo "DDNS pause ignored crontab removal failure" >&2; exit 1; }
    ! ddns_uninstall <<< y >/dev/null 2>&1 || { echo "DDNS uninstall ignored crontab removal failure" >&2; exit 1; }
    [ -f "$DDNS_SCRIPT" ] && [ -f "$DDNS_TOKEN_FILE" ] && [ -f "$DDNS_HUAWEI_KEY_FILE" ] && [ -f "$DDNS_ZONE_FILE" ] \
        || { echo "DDNS uninstall deleted files after crontab failure" >&2; exit 1; }
)

# Cross-type Cloudflare records are deleted by default, while an explicit "n" keeps them.
(
    CF_DELETE_LOG="$TMP/cloudflare-delete.log"
    curl() {
        case "$*" in
            *" -X DELETE "*) printf '%s\n' "$*" >> "$CF_DELETE_LOG"; printf '%s\n' '{"success":true}' ;;
            *) printf '%s\n' '{"success":true,"result":[{"id":"stale-aaaa","type":"AAAA","name":"v4.example.com","content":"2001:db8::4"}]}' ;;
        esac
    }
    ddns_cf_cleanup_cross_record zone token AAAA v4.example.com "测试交叉记录" <<< "" >/dev/null
    grep -Fq '/dns_records/stale-aaaa' "$CF_DELETE_LOG" || { echo "DDNS default cross-type cleanup did not delete the selected record" >&2; exit 1; }
    : > "$CF_DELETE_LOG"
    ddns_cf_cleanup_cross_record zone token AAAA v4.example.com "测试交叉记录" <<< "n" >/dev/null
    [ ! -s "$CF_DELETE_LOG" ] || { echo "DDNS declined cross-type cleanup still deleted a record" >&2; exit 1; }
    ddns_cf_cleanup_cross_record zone token AAAA v4.example.com "测试交叉记录" <<< "y" >/dev/null
    grep -Fq '/dns_records/stale-aaaa' "$CF_DELETE_LOG" || { echo "DDNS confirmed cross-type cleanup did not delete the selected record" >&2; exit 1; }
)

# Swap deletion must stop before touching fstab/files when swapoff fails.
(
    print_header() { :; }
    menu_div() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    swapon() {
        case "$*" in
            '--show --noheadings') echo '/tmp/vps-tools-test.swap' ;;
            '--show --bytes --noheadings') echo '/tmp/vps-tools-test.swap file 1048576 0 -2' ;;
        esac
    }
    swapoff() { return 1; }
    ! swap_delete <<< $'1\ny' >/dev/null 2>&1 || { echo "Swap delete ignored swapoff failure" >&2; exit 1; }
)

# NTP enablement must report a timedatectl failure.
(
    print_header() { :; }
    info() { :; }
    error() { :; }
    sleep() { :; }
    timedatectl() { [ "${1:-}" = show ] && echo yes && return 0; return 1; }
    systemctl() {
        case "$1" in
            list-unit-files) echo 'systemd-timesyncd.service enabled'; return 0 ;;
            *) return 0 ;;
        esac
    }
    ! ts_enable_ntp >/dev/null 2>&1 || { echo "NTP enablement hid timedatectl failure" >&2; exit 1; }
)

# Multi-IP source switching must arm an exact route rollback and restore on verification failure.
(
    VPS_DATA_DIR="$TMP/ip-source-safety"
    mkdir -p "$VPS_DATA_DIR"
    audit_action() { :; }
    warn() { :; }
    nohup() { return 0; }
    ip_source_safety_arm 4 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' >/dev/null
    grep -Fq 'ip -4 route replace default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100' "$SAFETY_SCRIPT" \
        || { echo "Multi-IP safety timer did not preserve the original route" >&2; exit 1; }
    cancel_safety_timer
)
(
    APPLIED=0
    RESTORED=0
    print_header() { :; }
    menu_div() { :; }
    menu_item() { :; }
    ui_prompt() { printf '%s' "$1"; }
    error() { :; }
    warn() { :; }
    confirm_change_preview() { return 0; }
    ip_source_default_iface() { echo eth0; }
    ip_source_default_route() { echo 'default via 192.0.2.1 dev eth0 proto dhcp src 198.51.100.10 metric 100'; }
    ip_source_addresses() { printf '%s\n' 198.51.100.10 198.51.100.11; }
    ip_source_current() { echo 198.51.100.10; }
    ip_source_safety_arm() { return 0; }
    ip_source_route_replace() { APPLIED=1; }
    ip_source_verify() { return 1; }
    ip_source_route_restore() { RESTORED=1; }
    cancel_safety_timer() { :; }
    ! ip_source_switch_family 4 <<< 2 >/dev/null 2>&1 \
        || { echo "Multi-IP switch accepted a failed HTTPS verification" >&2; exit 1; }
    [ "$APPLIED" -eq 1 ] || { echo "Multi-IP switch did not apply the selected route" >&2; exit 1; }
    [ "$RESTORED" -eq 1 ] || { echo "Multi-IP switch did not restore the route after verification failure" >&2; exit 1; }
)

# HTTPS synchronization must not set the clock without enough trusted responses.
(
    print_header() { :; }
    info() { :; }
    warn() { :; }
    error() { :; }
    # shellcheck disable=SC2329 # test stub used indirectly by ts_sync_https
    ts_https_fetch_epoch() { return 1; }
    ! ts_sync_https fallback >/dev/null 2>&1 || { echo "HTTPS time sync accepted zero valid sources" >&2; exit 1; }
)

# HTTPS scheduling must render, activate, replace, and remove a systemd timer safely.
(
    SCHEDULE_DIR="$TMP/https-systemd"
    mkdir -p "$SCHEDULE_DIR/data"
    VPS_DATA_DIR="$SCHEDULE_DIR/data"
    LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
    TS_HTTPS_SERVICE_FILE="$SCHEDULE_DIR/vps-tools-https-time.service"
    TS_HTTPS_TIMER_FILE="$SCHEDULE_DIR/vps-tools-https-time.timer"
    TS_HTTPS_INTERVAL_FILE="$SCHEDULE_DIR/data/interval"
    TS_HTTPS_STATE_FILE="$SCHEDULE_DIR/data/state"
    TS_HTTPS_LOCK_FILE="$SCHEDULE_DIR/data/lock"
    SYSTEMCTL_LOG="$SCHEDULE_DIR/systemctl.log"
    systemd_available() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
        [ "${1:-}" = is-active ] && return 0
        return 0
    }
    ts_https_scheduled_run() { return 0; }
    ts_https_schedule_enable 3 >/dev/null || { echo "HTTPS systemd schedule creation failed" >&2; exit 1; }
    grep -q '^OnUnitActiveSec=3h$' "$TS_HTTPS_TIMER_FILE" || { echo "HTTPS systemd interval is wrong" >&2; exit 1; }
    grep -Fq "ExecStart=$LOCAL_SCRIPT --https-time-sync-run" "$TS_HTTPS_SERVICE_FILE" || { echo "HTTPS systemd command is wrong" >&2; exit 1; }
    grep -q '^3$' "$TS_HTTPS_INTERVAL_FILE" || { echo "HTTPS systemd interval state is missing" >&2; exit 1; }
    [ "$(ts_https_schedule_backend)" = systemd ] || { echo "HTTPS systemd schedule status is wrong" >&2; exit 1; }
    ts_https_schedule_disable >/dev/null
    [ ! -e "$TS_HTTPS_TIMER_FILE" ] && [ ! -e "$TS_HTTPS_SERVICE_FILE" ] || { echo "HTTPS systemd schedule was not removed" >&2; exit 1; }
)

# Non-systemd systems must use root crontab without deleting unrelated entries.
(
    SCHEDULE_DIR="$TMP/https-cron"
    mkdir -p "$SCHEDULE_DIR/data"
    VPS_DATA_DIR="$SCHEDULE_DIR/data"
    LOCAL_SCRIPT="$ROOT/SSH-Hardening.sh"
    TS_HTTPS_SERVICE_FILE="$SCHEDULE_DIR/vps-tools-https-time.service"
    TS_HTTPS_TIMER_FILE="$SCHEDULE_DIR/vps-tools-https-time.timer"
    TS_HTTPS_INTERVAL_FILE="$SCHEDULE_DIR/data/interval"
    TS_HTTPS_STATE_FILE="$SCHEDULE_DIR/data/state"
    TS_HTTPS_LOCK_FILE="$SCHEDULE_DIR/data/lock"
    CRONTAB_DATA="$SCHEDULE_DIR/crontab"
    printf '5 4 * * * /usr/local/bin/unrelated\n' > "$CRONTAB_DATA"
    systemd_available() { return 1; }
    systemctl() { return 1; }
    crontab() {
        if [ "${1:-}" = -l ]; then
            cat "$CRONTAB_DATA"
        else
            cp "$1" "$CRONTAB_DATA"
        fi
    }
    ts_https_cron_daemon_enable() { return 0; }
    ts_https_scheduled_run() { return 0; }
    ts_https_schedule_enable 12 >/dev/null || { echo "HTTPS cron schedule creation failed" >&2; exit 1; }
    grep -Fq '17 */12 * * *' "$CRONTAB_DATA" || { echo "HTTPS cron interval is wrong" >&2; exit 1; }
    grep -Fq "$TS_HTTPS_CRON_MARKER" "$CRONTAB_DATA" || { echo "HTTPS cron marker is missing" >&2; exit 1; }
    grep -Fq '/usr/local/bin/unrelated' "$CRONTAB_DATA" || { echo "HTTPS cron replaced an unrelated entry" >&2; exit 1; }
    [ "$(ts_https_schedule_backend)" = cron ] || { echo "HTTPS cron schedule status is wrong" >&2; exit 1; }
    ts_https_schedule_disable >/dev/null
    ! grep -Fq "$TS_HTTPS_CRON_MARKER" "$CRONTAB_DATA" || { echo "HTTPS cron schedule was not removed" >&2; exit 1; }
    grep -Fq '/usr/local/bin/unrelated' "$CRONTAB_DATA" || { echo "HTTPS cron removal deleted an unrelated entry" >&2; exit 1; }
    ts_https_cron_daemon_enable() { return 1; }
    ! ts_https_schedule_enable_cron 6 >/dev/null 2>&1 || { echo "HTTPS cron accepted a stopped daemon" >&2; exit 1; }
    ! grep -Fq "$TS_HTTPS_CRON_MARKER" "$CRONTAB_DATA" || { echo "HTTPS cron daemon failure left a managed entry" >&2; exit 1; }
)

# Scheduled failures must be persisted for the status screen.
(
    VPS_DATA_DIR="$TMP/https-state"
    TS_HTTPS_STATE_FILE="$VPS_DATA_DIR/state"
    TS_HTTPS_LOCK_FILE="$VPS_DATA_DIR/lock"
    ts_sync_https() { return 1; }
    logger() { :; }
    ! ts_https_scheduled_run >/dev/null 2>&1 || { echo "HTTPS scheduled failure was hidden" >&2; exit 1; }
    grep -Fq $'\t失败\tHTTPS' "$TS_HTTPS_STATE_FILE" || { echo "HTTPS scheduled failure state is missing" >&2; exit 1; }
)

# Offline bundle creation must package a local script and offline install must place it at the target path.
LOCAL_SCRIPT="$TMP/local-script"
cat > "$LOCAL_SCRIPT" <<'EOF'
#!/bin/bash
echo offline
EOF
chmod 700 "$LOCAL_SCRIPT"
if ! self_offline_bundle_create >/dev/null; then
    echo "Offline bundle creation failed" >&2
    exit 1
fi
OFFLINE_BUNDLE=$(find "$VPS_DATA_DIR/offline" -type f -name '*.tar.gz' | head -1)
[ -f "$OFFLINE_BUNDLE" ] || { echo "Offline bundle was not created" >&2; exit 1; }
LOCAL_SCRIPT="$TMP/installed-script.sh"
LOCAL_BIN_DIR="$TMP/bin"
self_offline_bundle_install "$OFFLINE_BUNDLE" >/dev/null || { echo "Offline install failed" >&2; exit 1; }
[ -f "$LOCAL_SCRIPT" ] || { echo "Offline install did not place script" >&2; exit 1; }
[ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Offline install did not create an isolated shortcut" >&2; exit 1; }

# Process-substitution descriptors are streams, not complete reusable script files.
if self_resolve_script_source /dev/fd/0 >/dev/null 2>&1; then
    echo "Installer accepted a process-substitution descriptor as a complete script" >&2
    exit 1
fi
BROKEN_LINK_TARGET="$TMP/removed-script.sh"
rm -f "$LOCAL_BIN_DIR/v"
ln -s "$BROKEN_LINK_TARGET" "$LOCAL_BIN_DIR/v"
self_install_shortcut v >/dev/null
[ "$(readlink "$LOCAL_BIN_DIR/v")" = "$LOCAL_SCRIPT" ] || { echo "Installer did not repair a dangling shortcut" >&2; exit 1; }
FOREIGN_SCRIPT="$TMP/foreign-command"
printf '#!/bin/sh\nexit 0\n' > "$FOREIGN_SCRIPT"
chmod +x "$FOREIGN_SCRIPT"
rm -f "$LOCAL_BIN_DIR/V"
ln -s "$FOREIGN_SCRIPT" "$LOCAL_BIN_DIR/V"
self_install_shortcut V >/dev/null
[ "$(readlink "$LOCAL_BIN_DIR/V")" = "$FOREIGN_SCRIPT" ] || { echo "Installer overwrote a foreign shortcut" >&2; exit 1; }

# The real updater must reject a mismatched checksum without replacing the local script.
LOCAL_SCRIPT="$TMP/local-script"
export SCRIPT_URL="mock://script"
CHECKSUM_URL="mock://checksum"
printf 'original\n' > "$LOCAL_SCRIPT"
curl() {
    local URL="" OUT="" PREV=""
    for arg in "$@"; do
        [ "$PREV" = "-o" ] && OUT="$arg"
        case "$arg" in mock://*) URL="$arg" ;; esac
        PREV="$arg"
    done
    if [ "$URL" = "$CHECKSUM_URL" ]; then
        printf '%064d  SSH-Hardening.sh\n' 0 > "$OUT"
    else
        cp "$ROOT/SSH-Hardening.sh" "$OUT"
    fi
}
self_update >/dev/null 2>&1
grep -qx 'original' "$LOCAL_SCRIPT" || { echo "Updater replaced script after checksum mismatch" >&2; exit 1; }

# Post-update tc reconciliation must execute the newly installed script, not a function from the old process.
TC_STATE_FILE="$TMP/update-tc.state"
LOCAL_SCRIPT="$TMP/newly-installed-vps-tools"
UPDATE_TC_MARKER="$TMP/update-tc.marker"
export UPDATE_TC_MARKER
printf 'DEV=eth0\nRATE=2200\nBURST_KB=2200\nFORCE=0\n' > "$TC_STATE_FILE"
cat > "$LOCAL_SCRIPT" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--bbr-reconcile-tc" ] || exit 1
[ "${VPS_TOOLS_TEST_MODE:-}" = 0 ] || exit 1
[ "${BBR_TUNE_TEST_MODE:-}" = 0 ] || exit 1
: > "$UPDATE_TC_MARKER"
EOF
chmod +x "$LOCAL_SCRIPT"
self_reconcile_tc_after_update >/dev/null \
    || { echo "Updater could not invoke the new tc reconciliation endpoint" >&2; exit 1; }
[ -f "$UPDATE_TC_MARKER" ] \
    || { echo "Updater reconciled tc through the old process" >&2; exit 1; }

echo "Fault injection tests passed."
