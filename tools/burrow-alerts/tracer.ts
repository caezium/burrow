/**
 * Tracer bullet: one real event -> one real text.
 *
 * Reuses Burrow's `mo` engine for ALL metrics (this layer only formats + sends):
 *   - `mo status --json`  -> disk used% + free bytes (the crossing signal)
 *   - `mo analyze --json` -> top space hogs (the "why")
 *
 * Delivery is Photon's spectrum-ts in LOCAL mode (imessage.config({ local: true })),
 * which reads/writes iMessage on this Mac with no cloud project. We send
 * proactively to your own handle (a synthesized DM space) so it lands in your
 * self-thread.
 *
 * Usage:
 *   BURROW_ALERT_TO="+1XXXXXXXXXX" bun run tracer.ts        # real send
 *   bun run tracer.ts --dry-run                             # format only, no SDK
 *   BURROW_ALERT_TO="+1..." bun run tracer.ts --connect-test # build app + resolve
 *                                                            # space + stop; NO send
 *   THRESHOLD=90 bun run tracer.ts --dry-run                # override crossing
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFileSync } from "node:fs";
import { toE164 } from "./src/sender.ts";

const pexec = promisify(execFile);

// Local config (gitignored): { projectId, projectSecret, recipient, threshold }.
// Cloud mode is used when projectId + projectSecret are present; otherwise local.
type Config = { projectId?: string; projectSecret?: string; recipient?: string; threshold?: number };
function loadConfig(): Config {
  try {
    return JSON.parse(readFileSync(new URL("./config.local.json", import.meta.url), "utf8"));
  } catch {
    return {};
  }
}
const CFG = loadConfig();

const MO = process.env.MO_BIN || "mo";
const THRESHOLD = Number(process.env.THRESHOLD ?? CFG.threshold ?? 90); // disk used% that fires
const DRY_RUN = process.argv.includes("--dry-run");
const CONNECT_TEST = process.argv.includes("--connect-test");
const RECIPIENT = (process.env.BURROW_ALERT_TO ?? CFG.recipient)?.trim();
const PROJECT_ID = process.env.PHOTON_PROJECT_ID ?? CFG.projectId;
const PROJECT_SECRET = process.env.PHOTON_PROJECT_SECRET ?? CFG.projectSecret;
const USE_CLOUD = !process.argv.includes("--local") && Boolean(PROJECT_ID && PROJECT_SECRET);

// ---- mo data access (reuse, don't recompute) -------------------------------

type Disk = { mount: string; used: number; total: number; used_percent: number };
type AnalyzeEntry = { name: string; path: string; size: number; is_dir: boolean };

async function moStatus(): Promise<{ disks: Disk[] }> {
  const { stdout } = await pexec(MO, ["status", "--json"], { maxBuffer: 64 << 20, timeout: 15_000, killSignal: "SIGKILL" });
  const j = JSON.parse(stdout);
  return j.snapshot ?? j; // MCP wraps under .snapshot; bare `mo` does not
}

// Enrichment only — MUST be bounded. `mo analyze` walks the whole home tree
// (~1M files here) and is cache-sensitive: fast when warm, >90s cold. Never let
// it block the alert; on timeout/failure we send the crossing without hogs.
const ANALYZE_TIMEOUT_MS = Number(process.env.ANALYZE_TIMEOUT_MS ?? 30_000);

async function moAnalyzeTopHogs(path: string, n: number): Promise<AnalyzeEntry[]> {
  try {
    const { stdout } = await pexec(MO, ["analyze", "--json", path], {
      maxBuffer: 256 << 20,
      timeout: ANALYZE_TIMEOUT_MS,
      killSignal: "SIGKILL",
    });
    const j = JSON.parse(stdout);
    const entries: AnalyzeEntry[] = (j.entries ?? []).filter((e: AnalyzeEntry) => e.is_dir);
    entries.sort((a, b) => b.size - a.size);
    return entries.slice(0, n);
  } catch (e: any) {
    console.log(`[tracer] analyze skipped (${e?.killed ? "timed out" : e?.message}) — sending without hogs`);
    return [];
  }
}

// ---- formatting ------------------------------------------------------------

function gb(bytes: number): string {
  const g = bytes / 1e9;
  return g >= 10 ? `${Math.round(g)} GB` : `${g.toFixed(1)} GB`;
}

function formatAlert(root: Disk, hogs: AnalyzeEntry[]): string {
  const freeBytes = root.total - root.used;
  const lines = [
    `⚠️ Burrow: disk ${root.used_percent.toFixed(0)}% full — ${gb(freeBytes)} free on ${root.mount}`,
  ];
  if (hogs.length) {
    lines.push(``, `Top space hogs (~/):`, ...hogs.map((h, i) => `${i + 1}. ${h.name} — ${gb(h.size)}`));
  } else {
    lines.push(``, `(space-hog analysis still running — open Burrow to see the treemap)`);
  }
  return lines.join("\n");
}

// ---- delivery (Photon spectrum-ts, LOCAL mode) -----------------------------

// DM chat-guid spectrum-ts uses to resolve a space for a bare address
// (packages/imessage/src/remote/ids.ts: `any;-;<addr>`). imessage-kit's
// resolveTarget accepts this and routes it as a DM to <addr>.
const dmGuid = (addr: string) => `any;-;${addr}`;

/**
 * Build the app in local mode, run `fn` with a resolved self-DM space, then
 * shut down. The inbound watcher is lazy (only opens if you iterate
 * `app.messages`), so a one-shot sender never starts it and the process exits
 * cleanly after `app.stop()`.
 */
async function withSelfSpace<T>(to: string, fn: (space: any) => Promise<T>): Promise<T> {
  const { Spectrum } = await import("spectrum-ts");
  const { imessage } = await import("spectrum-ts/providers/imessage");
  // Cloud: managed Photon line (needs projectId/projectSecret). Local: reads
  // this Mac's chat.db, no creds. Space resolution + send are identical either
  // way — a shared-mode DM guid (`any;-;<addr>`) needs no server call.
  const app = USE_CLOUD
    ? await Spectrum({ projectId: PROJECT_ID!, projectSecret: PROJECT_SECRET!, providers: [imessage.config()] })
    : await Spectrum({ providers: [imessage.config({ local: true })] });
  try {
    const im = imessage(app);
    const space = await im.space.get(dmGuid(to));
    return await fn(space);
  } finally {
    await app.stop();
  }
}

async function sendIMessage(to: string, body: string): Promise<void> {
  const { text } = await import("spectrum-ts");
  await withSelfSpace(to, async (space) => {
    await space.send(text(body));
  });
}

// ---- main ------------------------------------------------------------------

async function main() {
  if (CONNECT_TEST) {
    if (!RECIPIENT) throw new Error("--connect-test needs BURROW_ALERT_TO set");
    const to = toE164(RECIPIENT);
    console.log(`[connect-test] building spectrum-ts (${USE_CLOUD ? "cloud" : "local"}) + resolving DM space for ${to}...`);
    await withSelfSpace(to, async (space) => {
      console.log(`[connect-test] resolved space: id=${space.id} type=${space.type}`);
    });
    console.log("[connect-test] app.stop() returned; NO message sent ✅");
    return;
  }

  const status = await moStatus();
  const root = status.disks.find((d) => d.mount === "/");
  if (!root) throw new Error("no root volume in `mo status` output");

  console.log(`[tracer] / used ${root.used_percent.toFixed(2)}% (threshold ${THRESHOLD}%)`);

  if (root.used_percent < THRESHOLD) {
    console.log(`[tracer] below threshold — nothing to send.`);
    return;
  }

  const home = process.env.HOME!;
  console.log(`[tracer] crossing detected — analyzing ${home} for top hogs...`);
  const hogs = await moAnalyzeTopHogs(home, 3);
  const message = formatAlert(root, hogs);

  console.log("\n----- message -----\n" + message + "\n-------------------\n");

  if (DRY_RUN) {
    console.log("[tracer] --dry-run: not sending.");
    return;
  }
  if (!RECIPIENT) {
    console.log("[tracer] BURROW_ALERT_TO not set — not sending. (re-run with it, or --dry-run)");
    return;
  }

  const to = toE164(RECIPIENT);
  console.log(`[tracer] sending to ${to} via spectrum-ts (${USE_CLOUD ? "cloud" : "local"})...`);
  await sendIMessage(to, message);
  console.log("[tracer] sent ✅");
}

if (import.meta.main) main().catch((err) => {
  console.error("[tracer] failed:", err?.message ?? err);
  process.exit(1);
});
