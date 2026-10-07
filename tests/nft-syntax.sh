#!/usr/bin/env bash
# Validate the generated NFT forwarding ruleset with the real nft parser (check mode only, nothing is applied).
# Needs root and nft; skips otherwise unless NFT_SYNTAX_REQUIRED=1 (CI).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ "$(id -u)" != 0 ] || ! command -v nft >/dev/null 2>&1; then
    [ "${NFT_SYNTAX_REQUIRED:-0}" != 1 ] || { echo "nft syntax test needs root and nft" >&2; exit 1; }
    echo "NFT syntax test skipped (needs root and nft)."
    exit 0
fi

export VPS_TOOLS_TEST_MODE=1
export NFT_STATE_DIR="$TMP/state" NFT_CONFIG_FILE="$TMP/nftables.conf" NFT_MANAGED_FILE="$TMP/managed.nft"
# shellcheck source=/dev/null
source "$ROOT/SSH-Hardening.sh"
NFT_RULES_FILE="$NFT_STATE_DIR/rules.db"
NFT_ACCESS_FILE="$NFT_STATE_DIR/access.conf"
mkdir -p "$NFT_STATE_DIR"
cat > "$NFT_RULES_FILE" <<'EOF'
1|ipv4||10080|10080|ip|192.0.2.10|192.0.2.10|80|80|single
2|ipv4|198.51.100.5|20000|20009|ip|192.0.2.11|192.0.2.11|20000|20009|range_1_to_1
3|ipv4||30000|30002|ip|192.0.2.12|192.0.2.12|40000|40002|range_offset
4|ipv6||10443|10443|ip|2001:db8::10|2001:db8::10|443|443|single
EOF

check() {
    local label="$1"
    nft_generate_config > "$TMP/$label.nft"
    nft -c -f "$TMP/$label.nft" || { echo "nft rejected the $label ruleset:" >&2; cat "$TMP/$label.nft" >&2; exit 1; }
}

printf 'mode=off\n' > "$NFT_ACCESS_FILE"
check plain
printf 'mode=whitelist\nentry=ipv4|203.0.113.0/24\nentry=ipv6|2001:db8:1::/48\n' > "$NFT_ACCESS_FILE"
check whitelist
printf 'mode=whitelist\n' > "$NFT_ACCESS_FILE"
check whitelist-empty
printf 'mode=blacklist\nentry=ipv4|203.0.113.7\n' > "$NFT_ACCESS_FILE"
check blacklist

grep -q "ct mark set ct mark or $NFT_DNAT_MARK" "$TMP/plain.nft" || { echo "DNAT rules do not mark their connections" >&2; exit 1; }
! grep -qE 'ct status dnat masquerade$' "$TMP/plain.nft" || { echo "postrouting still masquerades every DNAT connection" >&2; exit 1; }
grep -q 'ct state new' "$TMP/whitelist.nft" || { echo "access control also drops reply traffic" >&2; exit 1; }

echo "NFT ruleset syntax tests passed."
