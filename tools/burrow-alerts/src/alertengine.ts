/**
 * Debounce core — a faithful port of Burrow's own AlertEngine
 * (macos/Sources/AlertEngine.swift). Fire once per *episode*, not once per
 * sample: cross `high` to fire, don't re-arm until the value recovers below
 * `low` (hysteresis), and never fire more often than `cooldownSeconds` apart.
 * This is what keeps proactive alerts from becoming the spam they warn about.
 *
 * State is persisted to a JSON file so debounce survives across separate
 * launchd invocations (each run is a fresh process).
 */

import { readFileSync, writeFileSync, mkdirSync, renameSync, rmSync } from "node:fs";
import { dirname } from "node:path";

export type ThresholdRule = {
  id: string;
  /** Fire when the reading reaches `high`… */
  high: number;
  /** …and don't re-arm until it falls back below `low`. */
  low: number;
  /** Minimum seconds between fires, across episodes. */
  cooldownSeconds: number;
};

export type AlertState = { firing: boolean; lastFiredTS: number | null };

/** Fold one reading into the state. Returns the next state and whether to fire. */
export function step(
  rule: ThresholdRule,
  value: number,
  ts: number,
  state: AlertState,
): { state: AlertState; fired: boolean } {
  const s: AlertState = { ...state };
  if (s.firing) {
    if (value < rule.low) s.firing = false; // episode ends on recovery
    return { state: s, fired: false };
  }
  if (value < rule.high) return { state: s, fired: false };
  s.firing = true;
  if (s.lastFiredTS != null && ts - s.lastFiredTS < rule.cooldownSeconds) {
    return { state: s, fired: false }; // armed, still cooling down
  }
  s.lastFiredTS = ts;
  return { state: s, fired: true };
}

// ---- persistence -----------------------------------------------------------

type Store = Record<string, AlertState>;

export class AlertStore {
  private path: string;
  private data: Store;

  constructor(path: string) {
    this.path = path;
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
      this.data = Object.create(null);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        for (const [key, value] of Object.entries(parsed)) {
          if (value && typeof value.firing === "boolean"
            && (value.lastFiredTS === null || Number.isFinite(value.lastFiredTS))) this.data[key] = value;
        }
      }
    } catch {
      this.data = Object.create(null);
    }
  }

  get(id: string): AlertState {
    return this.data[id] ?? { firing: false, lastFiredTS: null };
  }

  set(id: string, state: AlertState) {
    this.data[id] = state;
  }

  save() {
    mkdirSync(dirname(this.path), { recursive: true, mode: 0o700 });
    const temporary = `${this.path}.${process.pid}.tmp`;
    try {
      writeFileSync(temporary, JSON.stringify(this.data, null, 2) + "\n", { mode: 0o600 });
      renameSync(temporary, this.path);
    } finally { rmSync(temporary, { force: true }); }
  }
}

/** Sunday at 09:00 local time, with catch-up after sleep or app downtime. */
export function digestDue(lastSentSeconds: number, now: Date): boolean {
  const boundary = new Date(now);
  boundary.setDate(boundary.getDate() - boundary.getDay());
  boundary.setHours(9, 0, 0, 0);
  if (boundary > now) boundary.setDate(boundary.getDate() - 7);
  return lastSentSeconds * 1000 < boundary.getTime();
}
