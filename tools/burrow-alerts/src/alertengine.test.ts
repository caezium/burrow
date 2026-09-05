import { test, expect } from "bun:test";
import { step, digestDue, AlertStore, type ThresholdRule, type AlertState } from "./alertengine.ts";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("weekly digest runs after Sunday 09:00 and catches up after sleep only once", () => {
  const sent = new Date(2026, 8, 5, 10).getTime() / 1000;
  expect(digestDue(sent, new Date(2026, 8, 6, 8, 59))).toBe(false);
  expect(digestDue(sent, new Date(2026, 8, 6, 9))).toBe(true);
  expect(digestDue(sent, new Date(2026, 8, 7, 14))).toBe(true);
  expect(digestDue(new Date(2026, 8, 7, 14).getTime() / 1000, new Date(2026, 8, 8, 10))).toBe(false);
});

test("malformed state cannot break checks; saved debounce survives another invocation", () => {
  const dir = mkdtempSync(join(tmpdir(), "burrow-state-test-"));
  try {
    const path = join(dir, "alerts.state.json");
    writeFileSync(path, "null");
    const store = new AlertStore(path);
    expect(store.get("disk")).toEqual({ firing: false, lastFiredTS: null });
    store.set("disk", { firing: true, lastFiredTS: 123 }); store.save();
    expect(new AlertStore(path).get("disk")).toEqual({ firing: true, lastFiredTS: 123 });
    expect(JSON.parse(readFileSync(path, "utf8")).disk.firing).toBe(true);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

const rule: ThresholdRule = { id: "disk", high: 90, low: 85, cooldownSeconds: 100 };

test("fires once per episode: hysteresis (high/low) + cooldown", () => {
  let s: AlertState = { firing: false, lastFiredTS: null };
  const at = (value: number, ts: number) => { const r = step(rule, value, ts, s); s = r.state; return r.fired; };

  expect(at(80, 0)).toBe(false);   // below high — quiet
  expect(at(92, 10)).toBe(true);   // cross high — fire
  expect(s.firing).toBe(true);
  expect(at(95, 20)).toBe(false);  // still high — no re-fire (same episode)
  expect(at(88, 30)).toBe(false);  // dip but above low — still firing, no re-arm
  expect(s.firing).toBe(true);

  expect(at(80, 40)).toBe(false);  // recover below low — episode ends (re-arm)
  expect(s.firing).toBe(false);

  expect(at(91, 50)).toBe(false);  // re-cross but within cooldown (50-10<100) — armed, silent
  expect(s.firing).toBe(true);
  at(80, 60);                       // recover again
  expect(at(91, 200)).toBe(true);  // re-cross after cooldown (200-10>100) — fire again
});
