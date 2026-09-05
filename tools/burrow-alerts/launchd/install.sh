#!/usr/bin/env bash
# Install (or uninstall) the Burrow-alerts launchd jobs for the current user.
#   ./launchd/install.sh          # generate + load both jobs
#   ./launchd/install.sh --uninstall
# Safe to re-run: it reloads the jobs from the current templates.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"     # the burrow-alerts dir
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"
AGENTS="$HOME/Library/LaunchAgents"
LABELS=(dev.henryzh.burrow-alerts.check dev.henryzh.burrow-alerts.digest)

unload() {
  for L in "${LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/$L" 2>/dev/null || true
    rm -f "$AGENTS/$L.plist"
  done
}

if [[ "${1:-}" == "--uninstall" ]]; then
  unload
  echo "Uninstalled Burrow-alerts launchd jobs."
  exit 0
fi

if [[ ! -f "$DIR/config.local.json" ]]; then
  echo "error: $DIR/config.local.json not found — configure delivery before installing jobs." >&2
  exit 1
fi
[[ -x "$BUN" ]] || { echo "error: Bun runtime not found at $BUN" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: Python 3 is required to generate launchd plists." >&2; exit 1; }

mkdir -p "$AGENTS" "$DIR/logs"
unload   # clean slate

for TPL in "$DIR"/launchd/*.plist.template; do
  L="$(basename "$TPL" .plist.template)"
  OUT="$AGENTS/$L.plist"
  python3 - "$TPL" "$OUT" "$BUN" "$DIR" <<'PYPLIST'
import plistlib, sys
source, target, bun, directory = sys.argv[1:]
with open(source, "rb") as stream:
    data = plistlib.load(stream)
def replace(value):
    if isinstance(value, str): return value.replace("__BUN__", bun).replace("__DIR__", directory)
    if isinstance(value, list): return [replace(item) for item in value]
    if isinstance(value, dict): return {key: replace(item) for key, item in value.items()}
    return value
with open(target, "wb") as stream:
    plistlib.dump(replace(data), stream)
PYPLIST
  plutil -lint "$OUT" >/dev/null
  launchctl bootstrap "gui/$(id -u)" "$OUT"
  echo "loaded $L"
done

echo
echo "Done. Jobs: check every 10 min, digest Sundays 09:00."
echo "Tail logs:   tail -f $DIR/logs/check.out.log"
echo "Run once now: launchctl kickstart -k gui/$(id -u)/dev.henryzh.burrow-alerts.check"
echo "Uninstall:    $DIR/launchd/install.sh --uninstall"
