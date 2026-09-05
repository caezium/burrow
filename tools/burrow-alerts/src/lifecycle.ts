import type { ChildProcess } from "node:child_process";

const children = new Set<ChildProcess>();

/** These children have their own process group so their MCP helpers stop too. */
export function trackChild(child: ChildProcess): ChildProcess {
  children.add(child);
  child.once("close", () => children.delete(child));
  return child;
}

function signalGroup(child: ChildProcess, signal: NodeJS.Signals) {
  if (!child.pid) return;
  try { process.kill(-child.pid, signal); }
  catch { try { child.kill(signal); } catch {} }
}

export async function terminateChild(child: ChildProcess, graceMs = 300): Promise<void> {
  signalGroup(child, "SIGTERM");
  // Even a reaped parent may have descendants holding stdout. Kill the group
  // after the grace period, then release local pipe handles deterministically.
  await new Promise<void>((resolve) => setTimeout(resolve, graceMs));
  signalGroup(child, "SIGKILL");
  child.stdin?.destroy(); child.stdout?.destroy(); child.stderr?.destroy();
  children.delete(child);
}

export async function stopChildren(): Promise<void> {
  await Promise.all([...children].map((child) => terminateChild(child)));
}

/** Works for standalone runs too; no handlers or timers are installed by imports. */
export function installShutdown(stop: () => Promise<void> = async () => {}) {
  let stopping = false;
  const shutdown = async () => {
    if (stopping) return;
    stopping = true;
    const forced = setTimeout(() => process.exit(1), 1_500);
    await stopChildren();
    try { await stop(); } finally { clearTimeout(forced); process.exit(0); }
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
  const parent = Number(process.env.BURROW_PARENT_PID);
  if (Number.isSafeInteger(parent) && parent > 1) {
    setInterval(() => {
      try { process.kill(parent, 0); } catch { void shutdown(); }
    }, 1_000).unref();
  }
  return shutdown;
}

/** Abort covers both response headers and body consumption. */
export async function fetchJson(fetchImpl: typeof fetch, url: string, init: RequestInit, timeoutMs = 30_000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error("model request timed out")), timeoutMs);
  try {
    const response = await fetchImpl(url, { ...init, signal: controller.signal });
    return { ok: response.ok, status: response.status, body: response.ok ? await response.json() : undefined };
  } finally { clearTimeout(timer); }
}
