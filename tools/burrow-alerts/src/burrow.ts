/**
 * Burrow data source. The alert layer reuses Burrow's *computed* signals — it
 * does not re-measure. We drive Burrow's own MCP server (the app binary run with
 * `--mcp`, a stdio JSON-RPC server) and call its tools:
 *
 *   burrow_snapshot        -> disk used% + free bytes + top CPU procs   (~3ms, DB)
 *   burrow_disk_forecast   -> days_until_full + bytes/day trend         (~1s, DB)
 *   burrow_top_processes   -> peak CPU per process over a window        (fast, DB)
 *   burrow_analyze         -> top space hogs                            (SLOW cold)
 *
 * The first three read Burrow's SQLite history and are fast/reliable. analyze
 * cold-walks ~1M files, so callers must bound it and treat hogs as best-effort.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { trackChild, terminateChild } from "./lifecycle.ts";

const BURROW_BIN =
  process.env.BURROW_BIN ?? "/Applications/Burrow.app/Contents/MacOS/Burrow";

export type Disk = { mount: string; used: number; total: number; used_percent: number };
export type Proc = { name: string; command?: string; cpu: number; memory_bytes?: number; pid: number };
export type Snapshot = { disks: Disk[]; top_processes: Proc[]; health_score?: number; health_score_msg?: string };
export type Forecast = { mount: string; days_until_full: number | null; slope_bytes_per_day: number; basis_days: number };
export type TopProc = { name: string; peak_cpu: number; peak_mem?: number };
export type Hog = { name: string; size: number };

/** Minimal MCP stdio client for one short-lived session (spawn -> calls -> close). */
export class BurrowMCP {
  private proc: ChildProcess;
  private buf = "";
  private nextId = 1;
  private pending = new Map<number, (msg: any) => void>();
  private ready: Promise<void>;
  private dead = false;
  private deadError: Error | null = null;

  constructor(command = BURROW_BIN, args = ["--mcp"]) {
    this.proc = trackChild(spawn(command, args, { stdio: ["pipe", "pipe", "ignore"], detached: true }));
    // A missing/moved Burrow.app makes spawn emit 'error' on the child. With no listener Node
    // RE-THROWS it as an uncaught exception — bypassing every `.catch`/await and, in the
    // long-lived agent (one BurrowMCP per message), turning a fresh Mac without Burrow into a
    // crash-restart storm. Funnel 'error'/nonzero-exit into `die` so it surfaces as a normal
    // rejection on `ready`/pending calls instead.
    this.proc.on("error", (e) => this.die(e instanceof Error ? e : new Error(String(e))));
    this.proc.on("exit", (code, signal) => {
      this.die(new Error(`burrow --mcp exited (code ${code ?? "null"}, signal ${signal ?? "null"})`));
    });
    this.proc.stdin!.on("error", (error) => this.die(error));
    this.proc.stdout!.setEncoding("utf8");
    this.proc.stdout!.on("data", (d: string) => this.onData(d));
    this.ready = this.init();
    void this.ready.catch(() => {}); // A failed idle session is observed by its next call.
  }

  /** Tear down on a fatal child failure: reject every in-flight call (and `ready`, one of them)
   *  so awaiters see an Error instead of an uncaught throw. Idempotent. */
  private die(err: Error) {
    if (this.dead) return;
    this.dead = true;
    this.deadError = err;
    for (const [id, fn] of [...this.pending]) {
      this.pending.delete(id);
      fn({ error: { message: err.message } });
    }
  }

  /** Write a framed JSON message, guarding a dead/closed pipe (a raw stdin.write on a failed
   *  spawn throws EPIPE synchronously). */
  private write(obj: unknown): void {
    if (this.dead) return;
    try {
      this.proc.stdin!.write(JSON.stringify(obj) + "\n");
    } catch (e) {
      this.die(e instanceof Error ? e : new Error(String(e)));
    }
  }

  private onData(chunk: string) {
    this.buf += chunk;
    if (this.buf.length > 8_000_000) {
      this.die(new Error("MCP response exceeded limit"));
      void terminateChild(this.proc);
      return;
    }
    let i: number;
    while ((i = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, i);
      this.buf = this.buf.slice(i + 1);
      if (!line.trim()) continue;
      let msg: any;
      try { msg = JSON.parse(line); } catch { continue; }
      if (msg.id && this.pending.has(msg.id)) {
        this.pending.get(msg.id)!(msg);
        this.pending.delete(msg.id);
      }
    }
  }

  private rpc(method: string, params: unknown, timeoutMs = 15_000): Promise<any> {
    if (this.dead) return Promise.reject(this.deadError ?? new Error(`MCP ${method}: burrow is not running`));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, (msg) => {
        clearTimeout(timer);
        if (msg.error) reject(new Error(`MCP ${method}: ${msg.error.message ?? JSON.stringify(msg.error)}`));
        else resolve(msg.result);
      });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  private async init() {
    await this.rpc("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "burrow-alerts", version: "0.1.0" },
    });
    this.write({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
  }

  /** Call a tool and return its first text-content block verbatim. */
  async toolText(name: string, args: Record<string, unknown> = {}, timeoutMs = 15_000): Promise<string> {
    await this.ready;
    const res = await this.rpc("tools/call", { name, arguments: args }, timeoutMs);
    const text = res?.content?.[0]?.text;
    if (res?.isError) throw new Error(`${name}: ${typeof text === "string" ? text : "tool failed"}`);
    if (typeof text !== "string") throw new Error(`${name}: no text content`);
    return text;
  }

  /** Call a tool and parse its first text-content block as JSON. */
  async tool<T = any>(name: string, args: Record<string, unknown> = {}, timeoutMs = 15_000): Promise<T> {
    return JSON.parse(await this.toolText(name, args, timeoutMs)) as T;
  }

  async close() {
    this.die(new Error("MCP session closed"));
    await terminateChild(this.proc);
  }
}

export async function getSnapshot(mcp: BurrowMCP): Promise<Snapshot> {
  const r = await mcp.tool<{ snapshot: Snapshot }>("burrow_snapshot");
  return r.snapshot;
}

export async function getForecast(mcp: BurrowMCP): Promise<Forecast> {
  return mcp.tool<Forecast>("burrow_disk_forecast", {});
}

export async function getTopProcesses(mcp: BurrowMCP, minutes: number, limit = 5): Promise<TopProc[]> {
  const r = await mcp.tool<{ processes: TopProc[] }>("burrow_top_processes", { minutes, limit });
  return r.processes ?? [];
}

export type UsageProc = { name: string; avg_cpu: number; peak_cpu: number; samples: number };

/**
 * Sustained-CPU signal: mean CPU% while present over the window (not a 1-sample
 * peak). Returns `sampleCount` (total samples in the window) so callers can
 * require a process to appear across enough of them to count as "sustained".
 */
export async function getSustainedCpu(
  mcp: BurrowMCP, minutes: number, limit = 5,
): Promise<{ sampleCount: number; processes: UsageProc[] }> {
  const r = await mcp.tool<{ sample_count: number; processes: UsageProc[] }>(
    "burrow_process_usage", { metric: "avg_cpu", minutes, limit },
  );
  return { sampleCount: r.sample_count ?? 0, processes: r.processes ?? [] };
}

/** Best-effort: bounded, returns [] on timeout/failure (analyze can take >60s cold). */
export async function getTopHogs(mcp: BurrowMCP, n: number, timeoutMs: number): Promise<Hog[]> {
  try {
    const r = await mcp.tool<{ entries?: Hog[] }>("burrow_analyze", {}, timeoutMs);
    const entries = (r.entries ?? []).filter((e: any) => e.is_dir);
    entries.sort((a, b) => b.size - a.size);
    return entries.slice(0, n).map((e) => ({ name: e.name, size: e.size }));
  } catch {
    return [];
  }
}

/** The weekly digest, straight from Burrow's own report (raw Markdown). */
export async function getReport(mcp: BurrowMCP, days = 7): Promise<string> {
  return mcp.toolText("burrow_report", { days }, 60_000);
}
