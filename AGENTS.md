# Repository Instructions

## BBR synchronization

`src/modules/bbr.sh` is also published as the standalone `chnnic/BBR-tune` repository.

When `src/modules/bbr.sh` or a core helper used by that module changes:

1. Commit and validate `SSH-Hardening` first.
2. In a local `BBR-tune` checkout, run `scripts/sync-from-upstream.sh /path/to/SSH-Hardening`.
3. Update the standalone README when behavior or compatibility changed.
4. Run Bash syntax checks, ShellCheck, the sync check, and `tests/smoke.sh` in `BBR-tune`.
5. Commit and push both repositories in the same work item.

Do not copy the generated module block by hand. Do not place GitHub tokens in either repository or command history.

## Required offline release delivery

The user requires an offline package with every script version update. Pushing
source code alone is not a completed delivery.

1. Keep APP_VERSION, the generated script, README heading, and every offline
   download/extract example on the same version. Keep both GitHub direct links
   and the `https://gh-proxy.org/` prefixed download links, including SHA256 files.
2. Run `./build.sh --check`, `tests/release-version.sh`, the applicable regression
   checks, `tests/offline-package.sh`, and `./build-offline-package.sh`.
3. Commit and push the validated version. Create and push its matching lowercase
   `vX.Y.Z` tag to trigger `.github/workflows/release-offline.yml`; wait for that
   release workflow to succeed. Never move an existing published tag or replace
   an existing release asset to hide a versioning mistake; use a new version.
4. Before reporting completion, verify the GitHub Release contains the script,
   its SHA256, the versioned offline archive, and the archive SHA256. Download
   and verify the archive, and confirm both README proxy links work. If publishing
   or verification fails, report the delivery as incomplete, not released.
5. When BBR also changes, complete the standalone synchronization in this same
   work item. The offline installer is the SSH-Hardening package, not a separate
   BBR-tune installer. Documentation-only changes do not require a new version.
