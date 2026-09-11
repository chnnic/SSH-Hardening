#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$ROOT/build-offline-package.sh" --output "$TMP/out" >/dev/null

(
    cd "$TMP/out"
    sha256sum -c vps-tools-offline-*.tar.gz.sha256
)

tar -xzf "$TMP/out"/vps-tools-offline-*.tar.gz -C "$TMP"
PACKAGE_DIR=$(find "$TMP" -maxdepth 1 -type d -name 'vps-tools-offline-V*' | head -1)
[ -n "$PACKAGE_DIR" ] || { echo "Offline package directory missing" >&2; exit 1; }

bash "$PACKAGE_DIR/install.sh" --bin-dir "$TMP/bin" >/dev/null
[ -x "$TMP/bin/vps-tools" ] || { echo "Offline installer did not install the script" >&2; exit 1; }
[ "$(readlink "$TMP/bin/v")" = "$TMP/bin/vps-tools" ] || { echo "Offline installer did not create v shortcut" >&2; exit 1; }
[ "$(readlink "$TMP/bin/V")" = "$TMP/bin/vps-tools" ] || { echo "Offline installer did not create V shortcut" >&2; exit 1; }
"$TMP/bin/vps-tools" --help >/dev/null

# An offline install may leave an old "new version" cache for this same version.
(
    export VPS_TOOLS_TEST_MODE=1 VPS_UPDATE_CACHE="$TMP/latest-version"
    # shellcheck source=/dev/null
    source "$TMP/bin/vps-tools"
    printf '%s\n' "$APP_VERSION" > "$VPS_UPDATE_CACHE"
    # shellcheck disable=SC2329 # called by self_check_update
    curl() { return 28; }
    [ -z "$(self_update_notice)" ] || { echo 'Offline install shows same-version update notice' >&2; exit 1; }
    self_check_update
    [ ! -e "$VPS_UPDATE_CACHE" ] || { echo 'Offline startup kept stale same-version cache' >&2; exit 1; }
)

printf '# tampered\n' >> "$PACKAGE_DIR/SSH-Hardening.sh"
if bash "$PACKAGE_DIR/install.sh" --bin-dir "$TMP/tampered-bin" >/dev/null 2>&1; then
    echo "Offline installer accepted a tampered script" >&2
    exit 1
fi

echo "Offline package test passed."
