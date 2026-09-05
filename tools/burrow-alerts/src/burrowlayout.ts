/**
 * BurrowLayout — the declarative card schema shared with the Burrow Cards
 * iMessage extension (imessage/Shared/Sources/BurrowCards/BurrowLayout.swift).
 * The agent/sidecar emits this JSON; the signed on-device renderer draws it as
 * native SwiftUI (fixed vocabulary — no downloaded code). Transport is the JSON
 * base64url-encoded into a Photon `customizedMiniApp` URL as `?p=<payload>`.
 *
 * Keep this in lockstep with the Swift Codable types — the round-trip test and
 * the Swift decoder both depend on the exact field names below.
 *
 * Node vocabulary is derived from HermesShare (MIT, time-attack/HermesShare),
 * trimmed and re-branded for Burrow's system-health alerts.
 */

import { gb } from "./format.ts";
import type { Hog } from "./burrow.ts";

export type BurrowNode =
  | { type: "vstack" | "hstack"; spacing?: number; children: BurrowNode[] }
  | { type: "section"; title?: string; children: BurrowNode[] }
  | { type: "text"; text: string; role?: "title" | "body" | "caption" }
  | { type: "statusBadge"; label: string; colorHex?: string }
  | { type: "progressBar"; value: number; colorHex?: string }
  | { type: "gauge"; label: string; value: number; colorHex?: string }
  | { type: "keyValueRow"; key: string; value: string };

export type BurrowAction = {
  id: string;
  label: string;
  systemImage?: string;
  deepLinkURL: string;
};

export type BurrowLayout = {
  version: 1;
  title: string;
  subtitle?: string;
  accentColorHex?: string;
  root: BurrowNode;
  actions?: BurrowAction[];
};

export type DiskLayoutData = {
  usedPercent: number;
  freeBytes: number;
  daysUntilFull?: number | null;
  hogs?: Hog[];
};

/** Accent by severity: red past ~95%, amber past ~85%, else green. */
function severityHex(usedPercent: number): string {
  if (usedPercent >= 95) return "#FF3B30";
  if (usedPercent >= 85) return "#FF9F0A";
  return "#34C759";
}

export function diskLayout(d: DiskLayoutData): BurrowLayout {
  const pct = Math.round(d.usedPercent);
  const accent = severityHex(d.usedPercent);
  const rows: BurrowNode[] = [
    { type: "keyValueRow", key: "Free", value: gb(d.freeBytes) },
    { type: "keyValueRow", key: "Used", value: `${pct}%` },
  ];
  if (d.daysUntilFull != null) {
    rows.push({ type: "keyValueRow", key: "Full in", value: `~${Math.round(d.daysUntilFull)} days` });
  }
  if (d.hogs?.length) {
    rows.push({ type: "keyValueRow", key: "Top", value: `${d.hogs[0].name} (${gb(d.hogs[0].size)})` });
  }
  return {
    version: 1,
    title: `Disk ${pct}% full`,
    subtitle: `${gb(d.freeBytes)} free`,
    accentColorHex: accent,
    root: {
      type: "vstack",
      spacing: 12,
      children: [
        { type: "statusBadge", label: `${pct}% full`, colorHex: accent },
        { type: "progressBar", value: Math.min(1, d.usedPercent / 100), colorHex: accent },
        { type: "section", title: "Details", children: rows },
      ],
    },
    actions: [
      { id: "clean", label: "Open Burrow to clean", systemImage: "sparkles", deepLinkURL: "burrow://action?id=clean" },
    ],
  };
}

// --- Transport: base64url payload in the customizedMiniApp URL (?p=…) --------

const toBase64Url = (json: string) => Buffer.from(json, "utf8").toString("base64url");
const fromBase64Url = (p: string) => Buffer.from(p, "base64url").toString("utf8");

export function encodeLayoutURL(baseUrl: string, layout: BurrowLayout): string {
  const url = new URL(baseUrl);
  url.searchParams.set("p", toBase64Url(JSON.stringify(layout)));
  return url.toString();
}

export function decodeLayoutURL(url: string): BurrowLayout {
  const p = new URL(url).searchParams.get("p");
  if (!p) throw new Error("no ?p= payload in URL");
  return JSON.parse(fromBase64Url(p)) as BurrowLayout;
}
