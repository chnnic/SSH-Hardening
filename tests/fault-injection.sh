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
        # Fixed past timestamp keeps this mtime fixture portable across GNU/BSD/BusyBox.
        touch -t 200001010000 "$RUN_MARK"
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

# Changing Port must disable unmanaged Port lines; Port is cumulative in sshd.
(
    CFG="$TMP/sshd-port-dup"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n  port 2200\nPasswordAuthentication yes\nMatch User backup\n    PasswordAuthentication no\n' > "$CFG"
    set_config_file "$CFG" Port 2222
    sshd_comment_unmanaged_directive "$CFG" Port
    [ "$(grep -cE '^[[:space:]]*[Pp]ort[[:space:]]' "$CFG")" -eq 1 ] \
        || { echo "Old Port lines stayed active after port change" >&2; exit 1; }
    grep -qx 'Port 2222' "$CFG" || { echo "Managed Port line missing" >&2; exit 1; }
    grep -qx '    PasswordAuthentication no' "$CFG" || { echo "Match block was modified" >&2; exit 1; }
)

# Socket-activated sshd (Ubuntu 22.10+) must reload the generator and restart ssh.socket.
(
    unset -f restart_ssh
    eval "$(sed -n '/^restart_ssh() {/,/^}/p' "$ROOT/src/lib/core.sh")"
    CALLS="$TMP/systemctl-calls"
    : > "$CALLS"
    systemd_available() { return 0; }
    systemctl() { echo "$*" >> "$CALLS"; return 0; }
    restart_ssh || { echo "Socket-activated SSH restart failed" >&2; exit 1; }
    grep -qx 'daemon-reload' "$CALLS" && grep -qx 'restart ssh.socket' "$CALLS" \
        || { echo "restart_ssh ignored ssh.socket activation" >&2; exit 1; }
)

# Arming a new rollback must not orphan or silently cancel a pending one.
(
    warn() { :; }; error() { :; }; info() { :; }; audit_action() { :; }
    SAFETY_SCRIPT="$TMP/pending-rollback.sh"
    printf 'sleep 30\n' > "$SAFETY_SCRIPT"
    bash "$SAFETY_SCRIPT" &
    SAFETY_PID=$!
    ! safety_resolve_pending <<< "n" >/dev/null 2>&1 \
        || { echo "Pending rollback was replaced without confirmation" >&2; exit 1; }
    kill -0 "$SAFETY_PID" 2>/dev/null || { echo "Pending rollback was cancelled without confirmation" >&2; exit 1; }
    ! ip_source_safety_arm 4 'default via 192.0.2.1 dev eth0' <<< "n" >/dev/null 2>&1 \
        || { echo "IP source switch cancelled a pending rollback" >&2; exit 1; }
    kill -0 "$SAFETY_PID" 2>/dev/null || { echo "IP source switch killed a pending rollback" >&2; exit 1; }
    safety_resolve_pending <<< "y" >/dev/null 2>&1 || { echo "Confirmed rollback still blocked new changes" >&2; exit 1; }
    [ -z "$SAFETY_PID" ] || { echo "Confirmed rollback was not cleared" >&2; exit 1; }
)

# The rollback script must be self-contained and never reload the full nftables.conf.
(
    VPS_DATA_DIR="$TMP/rollback-script"
    mkdir -p "$VPS_DATA_DIR"
    eval "$(sed -n '/^restart_ssh() {/,/^}/p' "$ROOT/src/lib/core.sh")"
    warn() { :; }; audit_action() { :; }
    config_backup_create() { echo "$TMP/snap.tar.gz"; }
    nohup() { return 0; }
    safety_arm ssh_port >/dev/null
    bash -n "$SAFETY_SCRIPT" || { echo "Rollback script has a syntax error" >&2; exit 1; }
    grep -q '^restart_ssh ()' "$SAFETY_SCRIPT" && grep -q 'rc-service sshd restart' "$SAFETY_SCRIPT" \
        || { echo "Rollback script cannot restart sshd on OpenRC" >&2; exit 1; }
    ! grep -q 'nft -f /etc/nftables.conf' "$SAFETY_SCRIPT" \
        || { echo "Rollback script reloads the full nftables ruleset" >&2; exit 1; }
    grep -q "nft_reload_managed_tables '$NFT_MANAGED_FILE'" "$SAFETY_SCRIPT" \
        || { echo "Rollback script does not restore managed nft tables" >&2; exit 1; }
    cancel_safety_timer
)

# Fail2ban must protect the real SSH port and follow port changes.
(
    F2B_JAIL_LOCAL="$TMP/jail.local"
    info() { :; }; warn() { :; }; error() { :; }
    f2b_status() { echo not_installed; }
    get_config() { echo 2222; }
    [ "$(f2b_ssh_port_value)" = 2222 ] || { echo "Fail2ban jail ignored the custom SSH port" >&2; exit 1; }
    printf '[DEFAULT]\nbantime = 3600\n\n[sshd]\nenabled = true\nport     = ssh\n' > "$F2B_JAIL_LOCAL"
    f2b_sync_ssh_port 22 2222
    [ "$(f2b_section_value sshd port)" = 2222 ] || { echo "Fail2ban port was not synced" >&2; exit 1; }
    printf '[sshd]\nport = 22,8022\n' > "$F2B_JAIL_LOCAL"
    f2b_sync_ssh_port 22 2222
    [ "$(f2b_section_value sshd port)" = "22,8022" ] || { echo "Custom fail2ban ports were overwritten" >&2; exit 1; }
)

# Pasted keys are validated and deduplicated one line at a time.
(
    command -v ssh-keygen >/dev/null 2>&1 || exit 0
    AUTH_KEYS="$TMP/keys/authorized_keys"
    print_header() { :; }; menu_div() { :; }; info() { :; }; warn() { :; }; error() { :; }
    ssh-keygen -q -t ed25519 -N '' -C one -f "$TMP/k1" && ssh-keygen -q -t ed25519 -N '' -C two -f "$TMP/k2"
    mkdir -p "$TMP/keys"
    printf '%s' "$(cat "$TMP/k1.pub")" > "$AUTH_KEYS"
    printf '\n%s\r\n\n%s\n' "$(cat "$TMP/k1.pub")" "$(cat "$TMP/k2.pub")" | add_key >/dev/null
    [ "$(ssh_key_count)" -eq 2 ] || { echo "add_key skipped a new key next to an existing one" >&2; exit 1; }
    printf '%s\nroot@vps:~# junk\n' "$(cat "$TMP/k1.pub" | sed 's/one/three/')" | add_key >/dev/null
    ! grep -q junk "$AUTH_KEYS" || { echo "add_key wrote a non-key line" >&2; exit 1; }
    [ "$(wc -l < "$AUTH_KEYS")" -eq 2 ] || { echo "add_key wrote a partial batch" >&2; exit 1; }
)

# Public keys: ECDSA/FIDO and option-prefixed lines are real keys; comments are not.
(
    AUTH_KEYS="$TMP/keytypes/authorized_keys"
    mkdir -p "$TMP/keytypes"
    printf '%s\n' '# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICommented old' \
        'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTY= ecdsa-user' \
        'sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAA fido-user' \
        'no-port-forwarding,command="echo hi" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC= restricted' > "$AUTH_KEYS"
    [ "$(ssh_key_count)" = 3 ] || { echo "Key counter missed ECDSA/FIDO/option-prefixed keys" >&2; exit 1; }
    [ "$(ssh_pubkey_entries | awk -F '\t' '$4 == 1 {print $2}')" = ssh-rsa ] \
        || { echo "Option-prefixed key was not flagged" >&2; exit 1; }
)

# Appending keys must not glue the new key onto a last line without a newline.
(
    AUTH_KEYS="$TMP/append/authorized_keys"
    mkdir -p "$TMP/append"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld' > "$AUTH_KEYS"
    ssh_auth_keys_append 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINew new' || { echo "Key append failed" >&2; exit 1; }
    [ "$(ssh_key_count)" = 2 ] && [ "$(wc -l < "$AUTH_KEYS" | tr -d ' ')" = 2 ] \
        || { echo "Appended key was glued onto the previous line" >&2; exit 1; }
    [ "$(ls -ld "$AUTH_KEYS" | cut -c1-10)" = "-rw-------" ] || { echo "authorized_keys lost mode 600" >&2; exit 1; }
)

# generate_key must use the newline-safe append.
(
    command -v ssh-keygen >/dev/null 2>&1 || exit 0
    AUTH_KEYS="$TMP/genkey/authorized_keys"
    mkdir -p "$TMP/genkey"
    print_header() { :; }; menu_div() { :; }; menu_item() { :; }; menu_pair() { :; }
    info() { :; }; warn() { :; }; error() { :; }; audit_action() { :; }
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld' > "$AUTH_KEYS"
    printf '1\ngen\ny\n' | generate_key >/dev/null 2>&1
    [ "$(ssh_key_count)" = 2 ] || { echo "generate_key glued the new key onto the last line" >&2; exit 1; }
)

# Deleting the last key without password login, or the key of this session, needs DELETE and the rollback timer.
(
    AUTH_KEYS="$TMP/delkey/authorized_keys"
    mkdir -p "$TMP/delkey"
    ARMED="$TMP/delkey/armed"
    print_header() { :; }; menu_div() { :; }; menu_pair() { :; }; info() { :; }; warn() { :; }; error() { :; }
    audit_action() { :; }
    get_config() { case "$1" in PasswordAuthentication) echo no ;; PermitRootLogin) echo prohibit-password ;; esac; }
    ssh_current_session_fingerprint() { return 1; }
    safety_arm() { echo armed >> "$ARMED"; }
    safety_confirm() { :; }
    printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOnly only' > "$AUTH_KEYS"
    printf '1\ny\n' | delete_key >/dev/null 2>&1
    [ "$(ssh_key_count)" = 1 ] || { echo "Last key was deleted without the DELETE confirmation" >&2; exit 1; }
    printf '1\nDELETE\n' | delete_key >/dev/null 2>&1
    [ "$(ssh_key_count)" = 0 ] && [ -s "$ARMED" ] || { echo "Confirmed last-key deletion did not run under the rollback timer" >&2; exit 1; }

    : > "$ARMED"
    printf '%s\n' '# keep me' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOne one' \
        'command="x" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo two' > "$AUTH_KEYS"
    printf '1\ny\n' | delete_key >/dev/null 2>&1
    grep -qx '# keep me' "$AUTH_KEYS" && grep -q 'ITwo two' "$AUTH_KEYS" && ! grep -q 'IOne' "$AUTH_KEYS" \
        || { echo "delete_key removed the wrong lines" >&2; exit 1; }
    ssh_current_session_fingerprint() { ssh_pubkey_fingerprint ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo; }
    command -v ssh-keygen >/dev/null 2>&1 || exit 0
    if [ -n "$(ssh_pubkey_fingerprint ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITwo)" ]; then
        printf '1\ny\n' | delete_key >/dev/null 2>&1
        [ "$(ssh_key_count)" = 1 ] || { echo "Current session key was deleted without DELETE" >&2; exit 1; }
    fi
)

# A rollback that already started must finish and be reported as rolled back, never as cancelled.
(
    warn() { :; }; error() { :; }; info() { :; }; audit_action() { :; }
    SAFETY_SCRIPT="$TMP/firing-rollback.sh"
    {
        safety_rollback_prologue "$SAFETY_SCRIPT"
        printf 'sleep 2\n: > %q\n' "$TMP/rollback-finished"
    } > "$SAFETY_SCRIPT"
    bash "$SAFETY_SCRIPT" 0 &
    SAFETY_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "${SAFETY_SCRIPT}.fired" ] && break; sleep 0.2; done
    if safety_confirm <<< "y" >/dev/null 2>&1; then
        echo "Confirmation after the rollback started was reported as a cancel" >&2; exit 1
    fi
    [ -e "$TMP/rollback-finished" ] || { echo "Cancelling interrupted a running rollback" >&2; exit 1; }
    [ -z "$SAFETY_PID" ] || { echo "Fired rollback was not cleared" >&2; exit 1; }
)

# change_port must not sync Fail2ban or close the old port when the rollback already ran.
(
    CALLS="$TMP/change-port-calls"
    : > "$CALLS"
    SSHD_CONFIG="$TMP/change-port-sshd_config"
    printf 'Port 22\n' > "$SSHD_CONFIG"
    print_header() { :; }; menu_div() { :; }; info() { :; }; warn() { :; }; error() { :; }; audit_action() { :; }
    get_config() { echo 22; }
    backup_config() { :; }; set_config_file() { :; }; sshd_comment_unmanaged_directive() { :; }
    confirm_file_diff() { return 0; }; sshd() { return 0; }; firewall_allow_port() { :; }
    apply_and_restart() { return 0; }; ssh_port_report_listeners() { :; }
    safety_arm() {
        SAFETY_SCRIPT="$TMP/expired-rollback.sh"
        : > "${SAFETY_SCRIPT}.fired"
        true & SAFETY_PID=$!
        wait "$SAFETY_PID"
    }
    f2b_sync_ssh_port() { echo f2b >> "$CALLS"; }
    ufw() { echo "ufw $*" >> "$CALLS"; }
    if printf '2222\ny\ny\n' | change_port >/dev/null 2>&1; then
        echo "change_port reported success after the rollback ran" >&2; exit 1
    fi
    [ ! -s "$CALLS" ] || { echo "change_port acted on an already rolled-back port change: $(cat "$CALLS")" >&2; exit 1; }
)

# Disabling IPv6 is refused over an IPv6 SSH session, and the rollback restores runtime IPv6 state.
(
    print_header() { :; }; warn() { :; }; error() { :; }; info() { :; }
    APPLIED="$TMP/v6-applied"
    ip_apply_v6_state() { echo "$1" > "$APPLIED"; }
    safety_arm() { :; }; safety_confirm() { :; }; confirm_change_preview() { return 0; }
    ip() { echo 'default via 192.0.2.1 dev eth0'; }
    SSH_CONNECTION='2001:db8::10 50000 2001:db8::1 22'
    if printf 'y\n' | ip_disable_v6 >/dev/null 2>&1; then echo "IPv6 disable over IPv6 SSH succeeded" >&2; exit 1; fi
    [ ! -e "$APPLIED" ] || { echo "IPv6 was disabled over an IPv6 SSH session" >&2; exit 1; }
    ip() { :; }
    SSH_CONNECTION='198.51.100.10 50000 192.0.2.10 22'
    if printf 'y\n' | ip_disable_v6 >/dev/null 2>&1; then echo "IPv6 disable without IPv4 route succeeded" >&2; exit 1; fi
    [ ! -e "$APPLIED" ] || { echo "IPv6 was disabled without an IPv4 default route" >&2; exit 1; }
)
(
    VPS_DATA_DIR="$TMP/v6-rollback"
    mkdir -p "$VPS_DATA_DIR"
    warn() { :; }; audit_action() { :; }
    config_backup_create() { echo "$TMP/snap.tar.gz"; }
    nohup() { return 0; }
    sysctl() { [ "$1" = -n ] && echo 0; }
    safety_arm disable_v6 >/dev/null
    grep -qx 'sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true' "$SAFETY_SCRIPT" \
        || { echo "Rollback does not restore runtime disable_ipv6" >&2; exit 1; }
    bash -n "$SAFETY_SCRIPT" || { echo "Rollback script has a syntax error" >&2; exit 1; }
    SAFETY_PID="" SAFETY_SCRIPT=""
)

# DD reinstall must pass every supported key, not only the first line.
(
    AUTH_KEYS="$TMP/reinstall/authorized_keys"
    mkdir -p "$TMP/reinstall"
    reinstall_bilingual_info() { :; }; reinstall_bilingual_warn() { :; }
    get_config() { echo 2222; }
    printf '%s\n' 'command="x" ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC= panel' \
        'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTY= mine' \
        'sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAA fido' > "$AUTH_KEYS"
    reinstall_collect_auth_args <<< "y" >/dev/null 2>&1 || { echo "Reinstall rejected confirmed keys" >&2; exit 1; }
    ARGS=" ${REINSTALL_AUTH_ARGS[*]} "
    case "$ARGS" in *"--ssh-key ssh-rsa "*"--ssh-key ecdsa-sha2-nistp256 "*) ;; *) echo "Reinstall did not pass every key: $ARGS" >&2; exit 1 ;; esac
    case "$ARGS" in *sk-ssh*|*--password*) echo "Reinstall passed an unsupported key or a password: $ARGS" >&2; exit 1 ;; esac
    if reinstall_collect_auth_args <<< "n" >/dev/null 2>&1; then echo "Reinstall continued without key confirmation" >&2; exit 1; fi
)

# Exporting to a directory writes a file inside it and never changes the directory mode.
(
    info() { :; }; error() { :; }; audit_action() { :; }
    mkdir -p "$TMP/export-dir"
    chmod 1777 "$TMP/export-dir"
    OUT=$(config_export_archive "$TMP/export-dir" dirtest) || { echo "Export to a directory failed" >&2; exit 1; }
    [ "$(ls -ld "$TMP/export-dir" | cut -c1-10)" = "drwxrwxrwt" ] || { echo "Export changed the directory mode" >&2; exit 1; }
    [ -f "$OUT" ] && [ "$(dirname "$OUT")" = "$TMP/export-dir" ] || { echo "Export did not create a file in the directory" >&2; exit 1; }
)

# Firewall removal must never delete SSH allow rules from INPUT.
! grep -q 'iptables -D INPUT -p tcp --dport' "$ROOT/SSH-Hardening.sh" \
    || { echo "Firewall uninstall still deletes SSH ACCEPT rules" >&2; exit 1; }

# Forwarding rules must not capture the SSH port; kernel forwarding is per family and RA-safe.
(
    error() { :; }; warn() { :; }; info() { :; }; audit_action() { :; }
    sshd_effective_ports() { echo 22; }
    SSH_CONNECTION='198.51.100.10 50000 192.0.2.10 22222'
    if nft_reject_ssh_port 10000 60000 >/dev/null 2>&1; then echo "Port range over the session SSH port was accepted" >&2; exit 1; fi
    if nft_reject_ssh_port 22 22 >/dev/null 2>&1; then echo "Forwarding the configured SSH port was accepted" >&2; exit 1; fi
    nft_reject_ssh_port 8080 8090 >/dev/null 2>&1 || { echo "Unrelated port range was rejected" >&2; exit 1; }

    NFT_PROC_SYS="$TMP/procsys"
    NFT_SYSCTL_FILE="$TMP/sysctl.d/99-vps-nftpf-forward.conf"
    mkdir -p "$NFT_PROC_SYS/net/ipv4" "$NFT_PROC_SYS/net/ipv6/conf/all" "$NFT_PROC_SYS/net/ipv6/conf/eth0"
    echo 0 > "$NFT_PROC_SYS/net/ipv4/ip_forward"
    echo 0 > "$NFT_PROC_SYS/net/ipv6/conf/all/forwarding"
    echo 1 > "$NFT_PROC_SYS/net/ipv6/conf/eth0/accept_ra"
    ip() { echo 'default via fe80::1 dev eth0 proto ra metric 1024 expires 1790sec pref medium'; }
    confirm_change_preview() { return 1; }
    if nft_prepare_ip_forward ipv6 >/dev/null 2>&1; then echo "Declined forwarding preview still succeeded" >&2; exit 1; fi
    [ "$(cat "$NFT_PROC_SYS/net/ipv6/conf/all/forwarding")" = 0 ] || { echo "IPv6 forwarding changed without confirmation" >&2; exit 1; }
    confirm_change_preview() { return 0; }
    nft_prepare_ip_forward ipv4 >/dev/null 2>&1 || { echo "IPv4 forwarding failed" >&2; exit 1; }
    [ "$(cat "$NFT_PROC_SYS/net/ipv6/conf/all/forwarding")" = 0 ] || { echo "IPv4 rule enabled IPv6 forwarding" >&2; exit 1; }
    nft_prepare_ip_forward ipv6 >/dev/null 2>&1 || { echo "IPv6 forwarding failed" >&2; exit 1; }
    [ "$(cat "$NFT_PROC_SYS/net/ipv6/conf/eth0/accept_ra")" = 2 ] && [ "$(cat "$NFT_PROC_SYS/net/ipv6/conf/all/forwarding")" = 1 ] \
        || { echo "IPv6 forwarding was enabled without accept_ra=2 on the RA interface" >&2; exit 1; }
    grep -qx 'net/ipv6/conf/eth0/accept_ra = 2' "$NFT_SYSCTL_FILE" && grep -qx 'net.ipv4.ip_forward = 1' "$NFT_SYSCTL_FILE" \
        || { echo "Forwarding settings were not persisted" >&2; exit 1; }
)

# Rollback removes config files that appeared after the snapshot, and never runs on an unreadable snapshot.
(
    FAKE="$TMP/fake-root"
    mkdir -p "$FAKE/etc/ssh/sshd_config.d"
    printf 'old\n' > "$FAKE/etc/ssh/sshd_config.d/10-old.conf"
    tar -czf "$TMP/cleanup-snap.tar.gz" -C "$FAKE" etc/ssh/sshd_config.d
    mkdir -p "$FAKE/etc/systemd/resolved.conf.d" "$FAKE/etc/sysctl.d"
    printf 'PasswordAuthentication no\n' > "$FAKE/etc/ssh/sshd_config.d/99-new.conf"
    printf '[Resolve]\nFallbackDNS=\n' > "$FAKE/etc/systemd/resolved.conf.d/99-vps-tools.conf"
    printf 'precedence ::ffff:0:0/96 100\n' > "$FAKE/etc/gai.conf"
    printf 'keep\n' > "$FAKE/etc/sysctl.d/50-user.conf"
    if safety_rollback_cleanup "$TMP/missing-snap.tar.gz" "$FAKE" 2>/dev/null; then
        echo "Rollback cleanup ran without a readable snapshot" >&2; exit 1
    fi
    [ -f "$FAKE/etc/ssh/sshd_config.d/99-new.conf" ] || { echo "Cleanup deleted files without a snapshot" >&2; exit 1; }
    safety_rollback_cleanup "$TMP/cleanup-snap.tar.gz" "$FAKE" || { echo "Rollback cleanup failed" >&2; exit 1; }
    [ -f "$FAKE/etc/ssh/sshd_config.d/10-old.conf" ] || { echo "Cleanup removed a snapshotted file" >&2; exit 1; }
    [ ! -e "$FAKE/etc/ssh/sshd_config.d/99-new.conf" ] && [ ! -e "$FAKE/etc/systemd/resolved.conf.d/99-vps-tools.conf" ] \
        && [ ! -e "$FAKE/etc/gai.conf" ] || { echo "Rollback left new drop-in files active" >&2; exit 1; }
    [ -f "$FAKE/etc/sysctl.d/50-user.conf" ] || { echo "Cleanup touched an unmanaged file" >&2; exit 1; }
)

# The rollback script reloads an active ufw, runs cleanup and caller-specific undo commands.
(
    VPS_DATA_DIR="$TMP/rollback-v4"
    mkdir -p "$VPS_DATA_DIR"
    warn() { :; }; audit_action() { :; }
    config_backup_create() { echo "$TMP/snap.tar.gz"; }
    nohup() { return 0; }
    ufw() { [ "$1" = status ] && echo 'Status: active'; }
    safety_arm dns 'resolvconf -d vps-tools >/dev/null 2>&1 || true' >/dev/null
    bash -n "$SAFETY_SCRIPT" || { echo "Rollback script has a syntax error" >&2; exit 1; }
    grep -q 'ufw reload' "$SAFETY_SCRIPT" || { echo "Rollback does not reload an active ufw" >&2; exit 1; }
    grep -q "^safety_rollback_cleanup '$TMP/snap.tar.gz' /" "$SAFETY_SCRIPT" || { echo "Rollback does not remove new files" >&2; exit 1; }
    grep -qx 'resolvconf -d vps-tools >/dev/null 2>&1 || true' "$SAFETY_SCRIPT" || { echo "Rollback dropped the extra undo command" >&2; exit 1; }
    SAFETY_PID="" SAFETY_SCRIPT=""
)

# A failed change rolls back immediately instead of leaving a timer that later clobbers other edits.
(
    warn() { :; }; error() { :; }; info() { :; }; audit_action() { :; }
    SAFETY_SCRIPT="$TMP/now-rollback.sh"
    {
        printf '#!/bin/bash\n'
        safety_rollback_prologue "$SAFETY_SCRIPT"
        printf ': > %q\n' "$TMP/restored-now"
    } > "$SAFETY_SCRIPT"
    bash "$SAFETY_SCRIPT" &
    SAFETY_PID=$!
    TIMER=$SAFETY_PID
    sleep 0.3
    safety_rollback_now
    [ -e "$TMP/restored-now" ] || { echo "Immediate rollback did not restore" >&2; exit 1; }
    ! kill -0 "$TIMER" 2>/dev/null || { echo "Immediate rollback left the 180s timer running" >&2; exit 1; }
    [ -z "$SAFETY_PID" ] && [ ! -e "$SAFETY_SCRIPT" ] || { echo "Immediate rollback did not clear its state" >&2; exit 1; }
)

# SSH failures (unwritable sshd_config, bad syntax, restart failure) roll back now and never report success.
(
    CALLS="$TMP/ssh-fail-calls"
    SSHD_CONFIG="$TMP/ssh-fail/sshd_config"
    mkdir -p "$TMP/ssh-fail"
    print_header() { :; }; menu_div() { :; }; menu_item() { :; }; menu_pair() { :; }; info() { :; }; warn() { :; }; error() { :; }
    audit_action() { echo "audit $2 $1" >> "$CALLS"; }
    get_config() { echo 22; }; ssh_key_count() { echo 1; }
    backup_config() { :; }; set_config_file() { :; }; sshd_comment_unmanaged_directive() { :; }
    confirm_file_diff() { return 0; }; firewall_allow_port() { :; }; ssh_port_report_listeners() { :; }
    safety_arm() { SAFETY_PID=1; }
    safety_rollback_now() { echo rollback-now >> "$CALLS"; SAFETY_PID=""; }
    safety_confirm() { echo confirm >> "$CALLS"; }

    : > "$CALLS"; printf 'Port 22\n' > "$SSHD_CONFIG"
    cp() { return 1; }
    if printf '2222\n' | change_port >/dev/null 2>&1; then echo "change_port succeeded with an unwritable sshd_config" >&2; exit 1; fi
    unset -f cp
    grep -qx rollback-now "$CALLS" && ! grep -q 'audit SUCCESS' "$CALLS" \
        || { echo "Unwritable sshd_config was not rolled back or was reported as success" >&2; exit 1; }

    : > "$CALLS"
    sshd() { return 1; }
    if printf '2222\n' | change_port >/dev/null 2>&1; then echo "change_port succeeded with bad syntax" >&2; exit 1; fi
    grep -qx rollback-now "$CALLS" || { echo "Syntax failure left the rollback timer pending" >&2; exit 1; }

    : > "$CALLS"
    sshd() { return 0; }; apply_and_restart() { return 1; }
    if printf '2222\n' | change_port >/dev/null 2>&1; then echo "change_port succeeded after restart failure" >&2; exit 1; fi
    grep -qx rollback-now "$CALLS" || { echo "Restart failure left the rollback timer pending" >&2; exit 1; }

    : > "$CALLS"
    printf '1\n' | set_login_mode >/dev/null 2>&1 || true
    grep -qx rollback-now "$CALLS" && ! grep -qx confirm "$CALLS" \
        || { echo "Login mode failure left the rollback timer pending" >&2; exit 1; }
)

# DNS rollback restores NetworkManager and systemd-resolved runtime settings, not only files.
(
    svc_is_active() { return 0; }
    default_iface() { echo eth0; }
    dns_systemd_resolved_linked() { return 0; }
    nmcli() {
        case "$*" in
            "-g NAME connection show --active") echo 'Wired 1' ;;
            "-g ipv4.ignore-auto-dns,ipv4.dns,ipv6.ignore-auto-dns,ipv6.dns connection show Wired 1") printf 'no\n\nno\n\n' ;;
        esac
    }
    resolvectl() {
        case "$1" in
            dns) echo 'Link 2 (eth0): 10.0.0.53 10.0.0.54' ;;
            domain) echo 'Link 2 (eth0): example.internal' ;;
        esac
    }
    resolvconf() { :; }
    OUT=$(dns_rollback_commands /etc/resolv.conf)
    printf '%s\n' "$OUT" | grep -qx "nmcli connection modify Wired\\\\ 1 ipv4.ignore-auto-dns no ipv4.dns '' ipv6.ignore-auto-dns no ipv6.dns '' >/dev/null 2>&1 || true" \
        || { echo "DNS rollback does not restore NetworkManager DNS: $OUT" >&2; exit 1; }
    printf '%s\n' "$OUT" | grep -qx 'resolvectl dns eth0 10.0.0.53 10.0.0.54 >/dev/null 2>&1 || true' \
        && printf '%s\n' "$OUT" | grep -qx 'resolvectl domain eth0 example.internal >/dev/null 2>&1 || true' \
        || { echo "DNS rollback does not restore systemd-resolved link DNS: $OUT" >&2; exit 1; }
    printf '%s\n' "$OUT" | grep -qx 'resolvconf -d vps-tools >/dev/null 2>&1 || true' \
        || { echo "DNS rollback does not drop the resolvconf record" >&2; exit 1; }
)

# Exiting with 00 or self-updating while a rollback is pending must ask first.
(
    MARK="$TMP/exit-confirm"
    SAFETY_PID=12345
    safety_confirm() { echo asked > "$MARK"; SAFETY_PID=""; }
    safe_clear() { :; }; warn() { :; }
    menu_read CH 'x' <<< "00" >/dev/null 2>&1
) || true
[ -s "$TMP/exit-confirm" ] || { echo "00 exit skipped the pending rollback confirmation" >&2; exit 1; }
(
    print_header() { :; }
    safety_resolve_pending() { return 1; }
    curl() { echo "download attempted" > "$TMP/update-download"; return 1; }
    if self_update >/dev/null 2>&1; then echo "self_update ran with an unconfirmed rollback" >&2; exit 1; fi
    [ ! -e "$TMP/update-download" ] || { echo "self_update downloaded before resolving the pending rollback" >&2; exit 1; }
)

# Caddyfile replacements keep a readable mode for User=caddy, and errors never go to a fixed /tmp path.
(
    CADDYFILE="$TMP/caddy/Caddyfile"
    mkdir -p "$TMP/caddy"
    printf 'example.com {\n}\n' > "$CADDYFILE"
    chmod 644 "$CADDYFILE"
    error() { :; }
    caddy() { return 0; }
    caddy_append_safe 'b.example.com {
}' || { echo "Caddy append failed" >&2; exit 1; }
    [ "$(ls -l "$CADDYFILE" | cut -c1-10)" = "-rw-r--r--" ] || { echo "Caddyfile lost its 644 mode after an edit" >&2; exit 1; }
    caddy() { echo 'bad directive' >&2; return 1; }
    if caddy_append_safe 'c.example.com {' >/dev/null 2>&1; then echo "Invalid Caddy block was accepted" >&2; exit 1; fi
    [ "$CADDY_VALIDATE_ERR" = 'bad directive' ] || { echo "Caddy validation error was not captured" >&2; exit 1; }
)
! grep -q '/tmp/caddy_err' "$ROOT/SSH-Hardening.sh" || { echo "Caddy still writes errors to a fixed /tmp path" >&2; exit 1; }

# Ubuntu's relative resolv.conf link restores; links escaping the allowlist are still rejected.
(
    mkdir -p "$TMP/rel-src/etc"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$TMP/rel-src/etc/resolv.conf"
    tar -czf "$TMP/rel-link.tar.gz" -C "$TMP/rel-src" etc/resolv.conf
    export CONFIG_RESTORE_ROOT="$TMP/rel-restore"
    error() { :; }; warn() { :; }; info() { :; }
    config_archive_extract "$TMP/rel-link.tar.gz" >/dev/null 2>&1 \
        || { echo "Ubuntu relative resolv.conf link was rejected" >&2; exit 1; }
    [ "$(readlink "$CONFIG_RESTORE_ROOT/etc/resolv.conf")" = ../run/systemd/resolve/stub-resolv.conf ] \
        || { echo "Relative resolv.conf link was not restored" >&2; exit 1; }
    mkdir -p "$TMP/bad-src/etc/ssh"
    ln -s ../../root/.ssh/authorized_keys "$TMP/bad-src/etc/ssh/sshd_config"
    tar -czf "$TMP/bad-link.tar.gz" -C "$TMP/bad-src" etc/ssh/sshd_config
    if config_archive_extract "$TMP/bad-link.tar.gz" >/dev/null 2>&1; then echo "Relative link outside the allowlist was accepted" >&2; exit 1; fi
    if config_link_normalize etc ../../../x >/dev/null; then echo "Link above the root was normalized" >&2; exit 1; fi
)

# DDNS credentials go to curl through stdin, never through argv.
(
    curl() { printf '%s\n' "$*" > "$TMP/curl-argv"; cat > "$TMP/curl-stdin"; }
    ddns_cf_curl 'cf-SECRET' -s 'https://api.cloudflare.com/client/v4/zones?name=x' >/dev/null
    ! grep -q 'SECRET' "$TMP/curl-argv" && grep -qx 'header = "Authorization: Bearer cf-SECRET"' "$TMP/curl-stdin" \
        || { echo "Cloudflare token was exposed in curl arguments" >&2; exit 1; }
    ddns_tg_curl '123:BOT-SECRET' sendMessage -fsS --data-urlencode 'text=hi' >/dev/null
    ! grep -q 'SECRET' "$TMP/curl-argv" && grep -qx 'url = "https://api.telegram.org/bot123:BOT-SECRET/sendMessage"' "$TMP/curl-stdin" \
        || { echo "Telegram bot token was exposed in curl arguments" >&2; exit 1; }
)
! grep -qE '\-H "Authorization: Bearer|api\.telegram\.org/bot\$\{' "$ROOT/SSH-Hardening.sh" \
    || { echo "A curl call still puts credentials on the command line" >&2; exit 1; }

# Ubuntu mirrors use ubuntu-ports on non-x86, and an update without usable indexes is not success.
(
    dpkg() { echo arm64; }
    [ "$(mirror_ubuntu_arch_url https://mirrors.aliyun.com/ubuntu)" = https://mirrors.aliyun.com/ubuntu-ports ] \
        && [ "$(mirror_ubuntu_arch_url http://archive.ubuntu.com/ubuntu)" = http://ports.ubuntu.com/ubuntu-ports ] \
        || { echo "arm64 Ubuntu mirror did not switch to ubuntu-ports" >&2; exit 1; }
    dpkg() { echo amd64; }
    [ "$(mirror_ubuntu_arch_url https://mirrors.aliyun.com/ubuntu)" = https://mirrors.aliyun.com/ubuntu ] \
        || { echo "amd64 Ubuntu mirror was rewritten" >&2; exit 1; }
    apt-cache() { printf 'coreutils:\n  Installed: 9.4-3\n  Candidate: (none)\n'; }
    if mirror_apt_index_usable; then echo "Missing package candidates counted as a usable mirror" >&2; exit 1; fi
    apt-cache() { printf 'coreutils:\n  Installed: 9.4-3\n  Candidate: 9.4-3\n'; }
    mirror_apt_index_usable || { echo "Usable mirror was rejected" >&2; exit 1; }
)

# fstab edits never glue onto a last line without a newline; swappiness persists to its own sysctl.d file.
(
    SWAP_FSTAB="$TMP/fstab"
    printf 'UUID=abc / ext4 defaults 0 1\nUUID=def /boot ext4 defaults 0 2' > "$SWAP_FSTAB"
    swap_fstab_update add /swapfile || { echo "fstab add failed" >&2; exit 1; }
    grep -qx 'UUID=def /boot ext4 defaults 0 2' "$SWAP_FSTAB" && grep -qx '/swapfile none swap sw 0 0' "$SWAP_FSTAB" \
        || { echo "fstab swap line was glued onto the previous entry" >&2; exit 1; }
    swap_fstab_update remove /swapfile || { echo "fstab remove failed" >&2; exit 1; }
    ! grep -q swapfile "$SWAP_FSTAB" && grep -qx 'UUID=def /boot ext4 defaults 0 2' "$SWAP_FSTAB" \
        || { echo "fstab remove damaged other entries" >&2; exit 1; }

    SWAP_SYSCTL_CONF="$TMP/sysctl.conf"
    SWAP_SYSCTL_DROPIN="$TMP/sysctl.d/99-vps-swappiness.conf"
    printf '#vm.swappiness=10\n  vm.swappiness = 60\n' > "$SWAP_SYSCTL_CONF"
    swap_persist_swappiness 30 || { echo "swappiness persistence failed" >&2; exit 1; }
    grep -qx 'vm.swappiness = 30' "$SWAP_SYSCTL_DROPIN" || { echo "swappiness drop-in was not written" >&2; exit 1; }
    grep -qx '#vm.swappiness=10' "$SWAP_SYSCTL_CONF" && grep -qx 'vm.swappiness = 30' "$SWAP_SYSCTL_CONF" \
        && ! grep -q '= 60' "$SWAP_SYSCTL_CONF" || { echo "sysctl.conf kept a conflicting swappiness line" >&2; exit 1; }
)

# Fail2ban whitelists loopback and the current SSH client, keeping existing ignoreip entries.
(
    F2B_JAIL_LOCAL="$TMP/f2b-ignore/jail.local"
    mkdir -p "$TMP/f2b-ignore"
    printf '[DEFAULT]\nignoreip = 10.0.0.0/8 127.0.0.1/8\n' > "$F2B_JAIL_LOCAL"
    SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 22'
    [ "$(f2b_ignoreip_value)" = '127.0.0.1/8 ::1 10.0.0.0/8 203.0.113.9' ] \
        || { echo "Fail2ban ignoreip misses the SSH client: $(f2b_ignoreip_value)" >&2; exit 1; }
)
! grep -q 'fail2ban-server -xf start &' "$ROOT/SSH-Hardening.sh" || { echo "Fail2ban install still starts an unmanaged server" >&2; exit 1; }

# A distro-installed Fail2ban without jail.local still follows the new SSH port.
(
    F2B_JAIL_LOCAL="$TMP/f2b-missing/jail.local"
    mkdir -p "$TMP/f2b-missing"
    info() { :; }; warn() { :; }; error() { :; }
    fail2ban-client() { return 0; }
    f2b_status() { echo stopped; }
    f2b_sync_ssh_port 22 2222 || { echo "Port sync failed without jail.local" >&2; exit 1; }
    [ "$(f2b_section_value sshd port)" = 2222 ] || { echo "Fail2ban kept watching port 22 after an SSH port change" >&2; exit 1; }
)

# ufw blocks go to the top of the rule list; firewall helpers open every SSH port.
(
    LOG="$TMP/ufw-calls"
    : > "$LOG"
    print_header() { :; }; info() { :; }; warn() { :; }; error() { :; }; audit_action() { :; }
    ufw() { echo "$*" >> "$LOG"; }
    ufw_block_ip <<< '198.51.100.7' >/dev/null
    grep -qx 'prepend deny from 198.51.100.7 to any' "$LOG" || { echo "ufw deny was appended after allow rules: $(cat "$LOG")" >&2; exit 1; }
    : > "$LOG"
    sshd_effective_ports() { printf '22\n2222\n'; }
    SSH_CONNECTION='203.0.113.9 50000 192.0.2.1 52222'
    fw_allow_ssh_ports ufw || { echo "SSH port allow failed" >&2; exit 1; }
    ssh_protected_ports() { :; }
    if fw_allow_ssh_ports ufw 2>/dev/null; then echo "Empty SSH port list counted as allowed" >&2; exit 1; fi
    unset -f ssh_protected_ports
    eval "$(sed -n '/^ssh_protected_ports() {/,/^}/p' "$ROOT/src/lib/core.sh")"
    [ "$(LC_ALL=C sort "$LOG" | paste -sd, -)" = 'allow 22/tcp,allow 2222/tcp,allow 52222/tcp' ] \
        || { echo "Firewall did not open every SSH port: $(paste -sd, "$LOG")" >&2; exit 1; }
)

# NFT: only this tool's DNAT is masqueraded, access control only drops new connections, listen IPs are validated.
(
    error() { :; }
    NFT_STATE_DIR="$TMP/nft-render"; NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"; NFT_ACCESS_FILE="$NFT_STATE_DIR/access.conf"
    mkdir -p "$NFT_STATE_DIR"
    printf '1|ipv4||10080|10080|ip|192.0.2.10|192.0.2.10|80|80|single\n' > "$NFT_RULES_FILE"
    printf 'mode=whitelist\nentry=ipv4|203.0.113.0/24\n' > "$NFT_ACCESS_FILE"
    OUT=$(nft_generate_config)
    grep -q "th dport 10080 ct mark set ct mark or $NFT_DNAT_MARK dnat to 192.0.2.10:80" <<< "$OUT" \
        || { echo "DNAT rule does not mark its connections" >&2; exit 1; }
    ! grep -qE 'ct status dnat masquerade$' <<< "$OUT" && grep -q "ct mark and $NFT_DNAT_MARK == $NFT_DNAT_MARK masquerade" <<< "$OUT" \
        || { echo "Postrouting masquerades every DNAT connection (Docker loses client IPs)" >&2; exit 1; }
    grep -q 'th dport 10080 ct state new ip saddr != @sources drop' <<< "$OUT" || { echo "Whitelist also drops reply traffic" >&2; exit 1; }
    for BAD in 10.0.0.256 host.example.com ::ffff:192.0.2.1; do
        if nft_validate_listen_ip "$BAD"; then echo "Invalid listen IP accepted: $BAD" >&2; exit 1; fi
    done
    nft_validate_listen_ip 192.0.2.5 && nft_validate_listen_ip 2001:db8::5 && nft_validate_listen_ip '' \
        || { echo "Valid listen IP rejected" >&2; exit 1; }
    getent() { printf '::ffff:192.0.2.1 STREAM v4only.example\n'; }
    if nft_resolve_domain v4only.example ipv6 >/dev/null; then echo "IPv4-mapped address used as IPv6 target" >&2; exit 1; fi
)

# gai.conf: single-space rules count, failed writes roll back, IPv6 egress is not reported as success.
(
    printf 'precedence ::ffff:0:0/96 100\n' > "$TMP/gai-single.conf"
    ip_gai_prefers_v4 "$TMP/gai-single.conf" || { echo "Single-space IPv4 precedence shown as IPv6 default" >&2; exit 1; }
    CALLS="$TMP/gai-calls"
    : > "$CALLS"
    print_header() { :; }; error() { :; }; warn() { echo "warn $*" >> "$CALLS"; }; info() { echo "info $*" >> "$CALLS"; }
    confirm_change_preview() { return 0; }; safety_arm() { :; }; safety_confirm() { :; }
    safety_rollback_now() { echo rollback-now >> "$CALLS"; }
    audit_action() { echo "audit $2" >> "$CALLS"; }
    ip_gai_supported() { return 0; }
    IP_GAI_CONF="$TMP/missing-dir/gai.conf"
    if ip_prefer_v4 >/dev/null 2>&1; then echo "IPv4 preference reported success after a failed write" >&2; exit 1; fi
    grep -qx rollback-now "$CALLS" && ! grep -qx 'audit SUCCESS' "$CALLS" \
        || { echo "Failed gai.conf write was not rolled back" >&2; exit 1; }
    : > "$CALLS"
    IP_GAI_CONF="$TMP/gai.conf"
    curl() { echo 2001:db8::123; }
    ip_prefer_v4 >/dev/null 2>&1 || { echo "IPv4 preference failed" >&2; exit 1; }
    ip_gai_prefers_v4 "$IP_GAI_CONF" || { echo "IPv4 preference rule not written" >&2; exit 1; }
    ! grep -q 'IPv4 优先已生效' "$CALLS" && grep -q '出口仍是 IPv6' "$CALLS" \
        || { echo "IPv6 egress was reported as IPv4 preference success" >&2; exit 1; }
)

echo "Fault injection tests passed."
