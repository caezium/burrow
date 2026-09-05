#!/usr/bin/env bash
# Prepare a universal, checksum-pinned Bun runtime without a global install.
set -euo pipefail
DEST="${1:?runtime output directory}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
WORK="$(mktemp -d "$DEST/download.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
VERSION=1.3.14
for FLAVOR in aarch64 x64-baseline; do
  case "$FLAVOR" in
    aarch64) HASH=d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620 ;;
    x64-baseline) HASH=3e35ad6f53971a9834bf9e6786e2adf72b5f1921cc9a9c5fde073d2972944076 ;;
  esac
  ARCHIVE="bun-darwin-$FLAVOR.zip"
  curl --fail --location --silent --show-error --retry 2 --max-time 120 \
    "https://github.com/oven-sh/bun/releases/download/bun-v$VERSION/$ARCHIVE" -o "$WORK/$ARCHIVE"
  (cd "$WORK" && printf '%s  %s\n' "$HASH" "$ARCHIVE" | shasum -a 256 -c -)
  unzip -q "$WORK/$ARCHIVE" -d "$WORK"
done
lipo -create "$WORK/bun-darwin-aarch64/bun" "$WORK/bun-darwin-x64-baseline/bun" -output "$DEST/bun"
chmod +x "$DEST/bun"
codesign --force --preserve-metadata=entitlements --sign - "$DEST/bun"
lipo "$DEST/bun" -verify_arch arm64 x86_64
"$DEST/bun" --version
