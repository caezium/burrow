#!/usr/bin/env bash
#
# bundle-burrow.sh — build the `burrow-engine` binary and stage it as the app's `Resources/burrow`.
#
# The GUI shells out to this ONE bundled binary (`burrow <cmd> --json`) for the stable Burrow
# envelope, and `clean --stream` / `optimize --stream` for the live NDJSON progress feed. The new
# MIT `burrow-engine` does all the work natively (analyze/status/clean/optimize/uninstall/net/
# orphans/slim-check/evict/dupes/photos/history/purge/installer), so there is no separate engine
# dir or conductor anymore — this single binary replaces both the old burrow-cli conductor and the
# burrow-digger engine. It's still staged under the name `burrow` so the app's resolution
# (BurrowConductor.executableURL → Resources/burrow) is unchanged. Only the built binary travels —
# no Rust source ships. `dupes` shells the sibling-bundled Resources/fclones via $BURROW_FCLONES.
#
# Usage: bundle-burrow.sh <BURROW_ENGINE_SRC> <RESOURCES_DIR>
#   BURROW_ENGINE_SRC  a burrow-engine checkout (has Cargo.toml with the `burrow-engine` binary)
#   RESOURCES_DIR      the app bundle's Resources dir (the binary is written directly inside it)
set -euo pipefail

SRC="${1:?burrow-engine source dir required}"
RESOURCES="${2:?resources dir required}"
OUT="$RESOURCES/burrow"

command -v cargo >/dev/null 2>&1 || {
  echo "error: cargo not found — cannot build burrow-engine (install Rust, or omit the vendor/burrow-engine submodule to fall back to a system engine)"
  exit 1
}

# Build UNIVERSAL (arm64 + x86_64) so the engine runs on BOTH Apple Silicon and Intel Macs. An
# arch-only binary hangs the universal app on the other arch (issue #221). Rust cross-compiles per
# target; we add both targets (rustup fetches the missing slice) and lipo them together.
# GIT_TERMINAL_PROMPT=0 + </dev/null keep a fresh checkout from ever blocking on an interactive
# prompt.
export GIT_TERMINAL_PROMPT=0
A=aarch64-apple-darwin
X=x86_64-apple-darwin
( cd "$SRC"
  if command -v rustup >/dev/null 2>&1; then
    rustup target add "$A" "$X" >/dev/null 2>&1 || true
  fi
  cargo build --release --bin burrow-engine --target "$A" </dev/null
  cargo build --release --bin burrow-engine --target "$X" </dev/null
  lipo -create -output "target/release/burrow-engine-universal" \
    "target/$A/release/burrow-engine" "target/$X/release/burrow-engine" )

# Stage + sign the engine so the app's own signature validates (--deep). Uses the build's resolved
# identity when run as a build phase, else ad-hoc ('-').
mkdir -p "$RESOURCES"
cp "$SRC/target/release/burrow-engine-universal" "$OUT"
chmod +x "$OUT"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$OUT" 2>/dev/null \
  || codesign --force --sign - --timestamp=none "$OUT" || true

echo "bundled burrow-engine -> $OUT ($(lipo -archs "$OUT" 2>/dev/null || echo native); signed with '${IDENTITY}')"
