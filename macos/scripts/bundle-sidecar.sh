#!/usr/bin/env bash
# Stage the "Burrow over iMessage" sidecar into the app bundle's Resources.
#   bundle-sidecar.sh <sidecar-src-dir> <resources-dir>
# Copies the TS sources + node_modules + a `bun` binary into Resources/sidecar/,
# then codesigns the nested bun Mach-O so the app signature validates (Xcode's
# CodeSign phase re-seals the app afterward; scripts/build.sh / the release
# pipeline finalize it).
set -euo pipefail

SRC="${1:?sidecar source dir}"
RES="${2:?resources dir}"
SRC="$(cd "$SRC" && pwd)"
mkdir -p "$RES"
RES="$(cd "$RES" && pwd)"
DEST="$RES/sidecar"

BUN="${BUN_BIN:-$(command -v bun || true)}"
if [ -z "$BUN" ] || [ ! -x "$BUN" ]; then
  echo "error: missing Bun runtime; run macos/scripts/fetch-sidecar-bun.sh and set BUN_BIN to its bun output." >&2
  exit 1
fi
BUN="$(cd "$(dirname "$BUN")" && pwd)/$(basename "$BUN")"
for ARCH in ${ARCHS:-$(uname -m)}; do
  lipo "$BUN" -verify_arch "$ARCH" || { echo "error: Bun does not support target $ARCH; use fetch-sidecar-bun.sh" >&2; exit 1; }
done

rm -rf "$DEST"
mkdir -p "$DEST/bin"

# Runtime files only (skip dev/test/secret/heavy artifacts).
/usr/bin/rsync -a \
  --exclude '.git' --exclude '.scguard' --exclude 'logs' \
  --exclude '*.test.ts' --exclude 'config.local.json' --exclude '*.state.json' \
  --exclude 'launchd' --exclude 'FRICTION.md' \
  "$SRC/agent.ts" "$SRC/check.ts" "$SRC/package.json" "$SRC/bun.lock" "$SRC/config.example.json" \
  "$SRC/src" "$SRC/agent" "$SRC/assets" "$DEST/"

# Install the reviewed lockfile, including both supported CPU architectures.
( cd "$DEST" && "$BUN" install --production --frozen-lockfile --ignore-scripts --os darwin --cpu '*' )

cp "$BUN" "$DEST/bin/bun"
chmod +x "$DEST/bin/bun"

# Codesign the nested binary (adhoc if no identity, matching engine bundling).
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
codesign --force --timestamp=none --preserve-metadata=entitlements --sign "${IDENTITY:--}" "$DEST/bin/bun"
codesign --verify --strict "$DEST/bin/bun"
(cd "$DEST" && "$DEST/bin/bun" -e 'await import("spectrum-ts"); await import("spectrum-ts/providers/imessage");')

echo "bundled iMessage sidecar → $DEST"
