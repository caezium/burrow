# burrow-alerts

Proactive Mac-health alerts over iMessage. Burrow already measures your Mac; this
layer **only formats and sends**. It reads Burrow's computed signals through
Burrow's MCP server and texts you when something crosses a threshold — debounced
so it never spams.

## What it sends

| Alert | Signal (Burrow MCP tool) | Fires when |
|---|---|---|
| **Disk almost full** | `burrow_snapshot` + `burrow_disk_forecast` + `burrow_analyze` | `/` used % ≥ 90 (with days-to-full + top space hogs) |
| **Sustained CPU** | `burrow_process_usage` (avg CPU over a window) | a process averages ≥ 90% across a 10-min window (not a 1-sample spike) |
| **Weekly digest** | `burrow_report` | Sundays 09:00 — cleanup + top energy users + forecast |

Debounce is a port of Burrow's own `AlertEngine`: hysteresis (fire at `high`,
re-arm only below `low`) + cooldown, so you get one nudge per *episode*, not per
sample. State persists in `~/Library/Application Support/Burrow/iMessage/alerts.state.json` across runs (`BURROW_ALERT_STATE_DIR` overrides this for isolated runs).

## Delivery — Photon spectrum-ts

Cloud mode (managed Photon line) when `projectId`+`projectSecret` are set in
`config.local.json`; local mode (this Mac's Messages) otherwise.

> **Cloud one-time setup:** the shared line only messages opted-in numbers. From
> the target device, text the project's assigned line once, or you'll get
> `Target not allowed for this project`. (Local mode has no such gate.)

## Setup

```bash
bun install                              # already vendored here
cp config.example.json config.local.json # then fill in recipient (+ cloud creds)
bun run check:dry                        # see what it would send, sends nothing
```

## Run

```bash
bun run check          # evaluate + send crossings (what launchd runs)
bun run digest         # send the weekly digest now
bun run check:dry      # dry-run
```

## Schedule (launchd)

```bash
./launchd/install.sh                     # check every 10 min + digest Sun 09:00
./launchd/install.sh --uninstall
launchctl kickstart -k gui/$(id -u)/dev.henryzh.burrow-alerts.check   # run once now
tail -f logs/check.out.log
```

The jobs run proxy-bypassed (`NO_PROXY=*`) so cloud egress to Photon is direct.
Burrow's own daemon is Swift/in-app (it delivers macOS notifications); this
iMessage sender is a separate process, so launchd — not Burrow's loop — is its home.

## Two-way agent (text Burrow a question)

`agent.ts` is a long-lived listener: text the Burrow line and a Claude session on
this Mac answers using Burrow's read-only tools.

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY NO_PROXY='*' bun run agent.ts --once   # handle one msg then exit (demo)
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY NO_PROXY='*' bun run agent.ts          # listen forever
```

Then text the Burrow line (e.g. "how's my disk?" / "what's eating CPU?").

- **Brain (BYO key, provider-flexible)** — set `llm` in `config.local.json`:
  `openrouter` / `openai` / `openai-compat` (any OpenAI-compatible endpoint) or
  `anthropic` run a tool-use loop over Burrow's read-only tools; `claude-cli`
  (default) uses your local `claude` login and delegates tools to its own MCP
  (needs `claude login` once; strips this Mac's Jan `ANTHROPIC_BASE_URL`/
  `ANTHROPIC_AUTH_TOKEN` so it uses the real login — `USE_JAN=1` to keep Jan).
- **Safety:** only answers YOUR number (also the reply-loop guard); tools are
  **read-only**, enforced twice (allowlist to the model + refused in the exec);
  rate-limited (6/min), single-flight, 800-char reply cap; prompt ignores
  instructions embedded in messages; metadata-only audit log (`~/Library/Application Support/Burrow/iMessage/logs/agent.audit.jsonl`).

## Setup & tests

```bash
BURROW_ALERT_TO="+1XXXXXXXXXX" bun run setup   # photon device-code login → project → config.local.json
# text the assigned line once (opt-in), then:
bun run check:test                             # canned "connected" text
bun run onboarding                             # prints the use-cases + setup copy
bun test                                        # 19 tests: brain, safety, debounce, tools, onboarding, setup
```

Photon is **free for one user**. The two-way agent needs a BYO LLM key (or the
local `claude` CLI); alerts alone need no key.

## Files

- `check.ts` — the runner (disk + CPU rules, `--digest`, `--dry-run`)
- `src/burrow.ts` — Burrow MCP stdio client + signal fetchers
- `src/alertengine.ts` — hysteresis+cooldown debounce (port of Burrow's AlertEngine) + state
- `src/format.ts` — message formatting
- `src/sender.ts` — spectrum-ts cloud/local send
- `tracer.ts` — the original one-shot disk tracer (kept for quick manual tests)
- `FRICTION.md` — QA log of Photon SDK friction hit while building this

## Bundled app development

Prepare the pinned universal runtime before building the Mac app:

```sh
bash macos/scripts/fetch-sidecar-bun.sh /tmp/burrow-sidecar-bun
export BUN_BIN=/tmp/burrow-sidecar-bun/bun
```

Run those commands from the repository root. Builds fail if the runtime, locked dependencies, or a target CPU architecture is missing. The bundle keeps Bun's JIT entitlements and runtime assets; mutable state and audit logs stay in Application Support. CI tests the sidecar before building and release signing includes Bun.

The native supervisor runs checks every ten minutes and a weekly digest after Sunday 09:00 local time, catching up after sleep. It avoids overlapping checks and terminates both the agent and active check on quit. Settings still take effect on relaunch.

The assistant accepts incoming owner DMs only. The local Claude provider disables built-in tools, user/project settings, hooks, and session persistence, and connects to a read-only MCP proxy that rejects every tool outside the same allowlist used by API providers. It follows the running app's `BURROW_BIN`, including nonstandard install paths. `bun test` uses fake processes and network responses; `bash macos/scripts/test-sidecar.sh` tests the native supervisor with local shell fixtures. Neither command sends messages.
