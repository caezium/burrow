#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc "$ROOT/Shared/Sources/BurrowCards/BurrowLayout.swift" \
  "$ROOT/Shared/Sources/BurrowCards/Samples.swift" "$ROOT/Tests/TransportChecks.swift" \
  -o "$WORK/transport-checks"
"$WORK/transport-checks"
