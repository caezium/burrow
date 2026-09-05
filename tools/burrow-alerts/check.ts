/**
 * Burrow health alerts — the runner launchd invokes.
 *
 * Reuses Burrow's computed signals (via its MCP server), evaluates them through
 * a hysteresis+cooldown debounce (ported from Burrow's AlertEngine), and texts
 * threshold-crossings — plus a weekly digest — over Photon spectrum-ts.
 *
 * Modes:
 *   bun run check.ts               evaluate disk + CPU rules, send crossings
 *   bun run check.ts --digest      send the weekly cleanup digest
 *   bun run check.ts --dry-run     print what would send; send nothing
 *
 * The alert layer only formats and sends. All measurement is Burrow's.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  BurrowMCP, getSnapshot, getForecast, getSustainedCpu, getTopHogs, getReport,
} from "./src/burrow.ts";
import { AlertStore, step, digestDue, type ThresholdRule } from "./src/alertengine.ts";
import { resolveDelivery, stateDirectory } from "./src/config.ts";
import { installShutdown, stopChildren } from "./src/lifecycle.ts";
import { formatDiskAlert, formatCpuAlert, formatDigest } from "./src/format.ts";
import { sendText, sendCard, useCloud, type SendConfig } from "./src/sender.ts";
import { diskCard, diskCardFrom, type MiniAppInput } from "./src/card.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const DRY_RUN = process.argv.includes("--dry-run");
const DIGEST = process.argv.includes("--digest");
const TEST = process.argv.includes("--test"); // canned "connected" text — verifies delivery only
const TEST_CARD = process.argv.includes("--test-card"); // fire a sample mini-app card on demand

type Config = {
  recipient: string;
  projectId?: string;
  projectSecret?: string;
  forceLocal?: boolean;
  card?: { appName: string; extensionBundleId: string; teamId: string; url: string; appStoreId?: number };
  disk?: { high?: number; low?: number; cooldownSeconds?: number; hogsTimeoutMs?: number };
  cpu?: { high?: number; low?: number; windowMinutes?: number; minSamples?: number; cooldownSeconds?: number };
};

function loadConfig(): Config {
  try {
    return JSON.parse(readFileSync(join(HERE, "config.local.json"), "utf8"));
  } catch {
    return { recipient: process.env.BURROW_ALERT_TO ?? "" };
  }
}

const CFG = loadConfig();
const send = resolveDelivery(process.env, CFG, process.argv.includes("--local"));
const STATE_PATH = join(stateDirectory(), "alerts.state.json");

// Defaults mirror Burrow's own thresholds (Doctor: <10% free = warn; ThresholdAlerts: CPU 90).
const DISK = { high: 90, low: 85, cooldownSeconds: 6 * 3600, hogsTimeoutMs: 25_000, ...CFG.disk };
const CPU = { high: 90, low: 70, windowMinutes: 10, minSamples: 3, cooldownSeconds: 3600, ...CFG.cpu };

// Monotonic-ish wall clock in seconds (fine — we only diff timestamps for cooldown).
const now = () => Math.floor(Date.now() / 1000);

async function deliver(label: string, body: string, card?: MiniAppInput) {
  const asCard = Boolean(card && send.card && useCloud(send)); // cards are cloud-only
  console.log(`\n----- ${label}${asCard ? " (card)" : ""} -----\n${body}\n${"-".repeat(label.length + 12)}`);
  if (DRY_RUN) { console.log("[dry-run] not sending"); return; }
  if (!send.recipient) throw new Error("no recipient configured");
  if (asCard) await sendCard(send, card!, body);   // text is the fallback
  else await sendText(send, body);
  console.log(`[sent ✅] ${label} via spectrum-ts (${useCloud(send) ? "cloud" : "local"})`);
}

async function runDigest(mcp: BurrowMCP) {
  const [report, forecast] = await Promise.all([
    getReport(mcp, 7),
    getForecast(mcp).catch(() => null),
  ]);
  await deliver("weekly digest", formatDigest(report, forecast));
}

async function runChecks(mcp: BurrowMCP) {
  const store = new AlertStore(STATE_PATH);
  const ts = now();

  // 1) Fast signals up front — all read Burrow's DB and return quickly. We do
  //    them before any slow `analyze`, which would block this serial connection.
  const snap = await getSnapshot(mcp);
  const forecast = await getForecast(mcp).catch(() => null);
  const cpu = await getSustainedCpu(mcp, CPU.windowMinutes, 100);

  // 2) Evaluate rules and stage next states. We do NOT persist state until after
  //    sends succeed, so a mid-run kill re-alerts rather than swallowing.
  const staged: Array<{ id: string; state: ReturnType<typeof step>["state"] }> = [];
  const sends: Array<{ id: string; label: string; produce: () => Promise<{ text: string; card?: MiniAppInput }> }> = [];

  const root = snap.disks.find((d) => d.mount === "/");
  if (root) {
    const rule: ThresholdRule = { id: "disk:/", high: DISK.high, low: DISK.low, cooldownSeconds: DISK.cooldownSeconds };
    const { state, fired } = step(rule, root.used_percent, ts, store.get(rule.id));
    staged.push({ id: rule.id, state });
    console.log(`[disk] / at ${root.used_percent.toFixed(1)}% (high ${DISK.high}/low ${DISK.low}) firing=${state.firing} fired=${fired}`);
    if (fired) {
      sends.push({
        id: rule.id,
        label: "disk alert",
        // Slow `analyze` runs on a THROWAWAY connection so it can't block anything.
        produce: async () => {
          const hogsMcp = new BurrowMCP();
          try {
            const hogs = await getTopHogs(hogsMcp, 3, DISK.hogsTimeoutMs);
            const text = formatDiskAlert(root, forecast, hogs);
            const card = send.card ? diskCardFrom(send.card, root, forecast, hogs) : undefined;
            return { text, card };
          } finally {
            await hogsMcp.close();
          }
        },
      });
    }
  }

  const needSamples = Math.max(CPU.minSamples, Math.ceil(cpu.sampleCount * 0.5));
  const worst = cpu.processes.filter((p) => p.samples >= needSamples).sort((a, b) => b.avg_cpu - a.avg_cpu)[0];
  if (cpu.sampleCount >= CPU.minSamples) {
    // Track the sustained-load episode itself. A process can recover, exit or
    // leave the ranked list; per-name states would otherwise remain firing forever.
    const rule: ThresholdRule = { id: "cpu:sustained", high: CPU.high, low: CPU.low, cooldownSeconds: CPU.cooldownSeconds };
    const { state, fired } = step(rule, worst?.avg_cpu ?? 0, ts, store.get(rule.id));
    staged.push({ id: rule.id, state });
    if (worst) console.log(`[cpu] worst="${worst.name}" avg ${worst.avg_cpu.toFixed(0)}% over ${CPU.windowMinutes}m fired=${fired}`);
    if (fired && worst) sends.push({ id: rule.id, label: "cpu alert", produce: async () => ({ text: formatCpuAlert({ name: worst.name, peak_cpu: worst.avg_cpu }, CPU.windowMinutes) }) });
  } else {
    console.log(`[cpu] no process sustained ≥${CPU.high}% over ${CPU.windowMinutes}m (sampleCount ${cpu.sampleCount})`);
  }

  // 3) Send, then persist — PER RULE, not all-or-nothing. Each alert's new state is saved only
  //    after its OWN delivery succeeds; a failure is isolated (logged, state left unsaved so it
  //    re-alerts next run) and does not block or un-persist the others. The old single end-of-run
  //    save meant one failed send (e.g. CPU) threw away an already-delivered alert's state (disk),
  //    which then re-fired every 10 min — the exact spam this tool exists to avoid.
  //    Dry-run never persists (it must not suppress a later real alert).
  const stateFor = new Map(staged.map((s) => [s.id, s.state] as const));
  const firedIds = new Set(sends.map((s) => s.id));
  for (const s of sends) {
    try {
      const out = await s.produce();
      await deliver(s.label, out.text, out.card);
      if (!DRY_RUN && stateFor.has(s.id)) { store.set(s.id, stateFor.get(s.id)!); store.save(); }
    } catch (e: any) {
      console.error(`[check] ${s.label} failed (state not saved, will re-alert): ${e?.message ?? e}`);
    }
  }
  if (DRY_RUN) return;
  // Rules that didn't fire (idle / recovered) have no send to gate on — persist them so a
  // recovery below the low threshold is remembered and doesn't linger as "firing".
  for (const { id, state } of staged) if (!firedIds.has(id)) store.set(id, state);
  store.save();
}

async function main() {
  installShutdown();
  // Bounds SDK connection/send shutdown too, including standalone launchd runs.
  setTimeout(() => { void stopChildren().finally(() => process.exit(1)); }, 180_000).unref();
  if (!DRY_RUN && !send.recipient) throw new Error("no recipient configured");
  // Delivery-only smoke test (setup wizard's "Send test message"). No MCP needed.
  if (TEST) {
    await deliver("test", "✅ Burrow is connected. You'll get disk, CPU, and weekly-cleanup alerts here.");
    return;
  }

  // On-demand sample mini-app card (no threshold, no MCP). Needs a `card` block.
  if (TEST_CARD) {
    if (!send.card) { console.log("[skip] add a `card` block to config.local.json first (see config.example.json)."); return; }
    if (!useCloud(send)) { console.log("[skip] mini-app cards are cloud-only (set projectId+projectSecret)."); return; }
    const card = diskCard(send.card, { usedPercent: 99, freeBytes: 6.1e9, daysUntilFull: 6, hogs: [{ name: "Library", size: 160e9 }] });
    await deliver("test card", "⚠️ Burrow: disk 99% full — 6.1 GB free · full in ~6 days (sample)", card);
    return;
  }
  const mcp = new BurrowMCP();
  try {
    if (DIGEST) await runDigest(mcp);
    else {
      await runChecks(mcp);
      if (process.argv.includes("--scheduled") && !DRY_RUN) {
        const store = new AlertStore(STATE_PATH);
        const last = store.get("weekly_digest").lastFiredTS;
        // The first run establishes the schedule; enabling the feature doesn't
        // send an unsolicited historical digest immediately.
        if (last !== null && digestDue(last, new Date())) await runDigest(mcp);
        if (last === null || digestDue(last, new Date())) {
          store.set("weekly_digest", { firing: false, lastFiredTS: now() });
          store.save();
        }
      }
    }
  } finally {
    await mcp.close();
  }
}

if (import.meta.main) main().catch((err) => {
  console.error("[check] failed:", err?.message ?? err);
  process.exit(1);
});
