#!/usr/bin/env bash
# Keep all public offline-download examples aligned with the shipped script.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
README_FILE="${RELEASE_README_FILE:-$ROOT/README.md}"
fail() { echo "Release version check failed: $*" >&2; exit 1; }
VERSION=$(sed -nE 's/^APP_VERSION="(V[0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$ROOT/SSH-Hardening.sh")
[ -n "$VERSION" ] || fail 'missing script version'
TAG="v${VERSION#V}"
grep -Fqx "# VPS 开荒脚本 $VERSION" "$README_FILE" || fail 'README heading differs from script version'
SECTION=$(awk '/^### 离线安装包/{section=1;next} /^## / && section{exit} section{print}' "$README_FILE")
[ -n "$SECTION" ] || fail 'missing offline install section'
PACKAGE_VERSIONS=$(printf '%s\n' "$SECTION" | grep -oE 'vps-tools-offline-V[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
[ "$PACKAGE_VERSIONS" = "vps-tools-offline-$VERSION" ] || fail 'offline package/extract examples differ from script version'
LINK_TAGS=$(printf '%s\n' "$SECTION" | grep -oE 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
[ "$LINK_TAGS" = "releases/download/$TAG" ] || fail 'offline release URLs differ from script version'
BASE="https://github.com/chnnic/SSH-Hardening/releases/download/$TAG/vps-tools-offline-$VERSION.tar.gz"
for PREFIX in '' 'https://gh-proxy.org/'; do
    for SUFFIX in '' '.sha256'; do
        printf '%s\n' "$SECTION" | grep -Fqx "curl -fLO ${PREFIX}${BASE}${SUFFIX}" || fail 'missing direct/proxy download command'
    done
done
printf '%s\n' "$SECTION" | grep -Fqx "sha256sum -c vps-tools-offline-$VERSION.tar.gz.sha256" || fail 'missing checksum verification'
printf '%s\n' "$SECTION" | awk '/^```bash/{block=1;next} /^```/{block=0;next} block{print}' | bash -n
echo "README and offline examples match $VERSION."
