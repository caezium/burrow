/**
 * iMessage mini-app cards (spectrum-ts `customizedMiniApp`) for alerts — a rich
 * bubble with a caption/subcaption, a lock-screen `summary` fallback, and a
 * tap-to-open deep link. Cloud-only; the sender falls back to plain text in
 * local mode or if the SDK rejects the card. Pure builders (no SDK import) so
 * they're unit-testable.
 */

import { gb } from "./format.ts";
import { diskLayout, encodeLayoutURL } from "./burrowlayout.ts";
import type { Disk, Forecast, Hog } from "./burrow.ts";

/** The extension identity + deep link a card carries (from config). */
export type MiniAppMeta = {
  appName: string;
  extensionBundleId: string;
  teamId: string;
  url: string;
  appStoreId?: number;
};

export type MiniAppLayout = {
  caption?: string;
  subcaption?: string;
  trailingCaption?: string;
  trailingSubcaption?: string;
  /** Bubble image bytes (JPEG — Photon rejects PNG). Attached at send time. */
  image?: Uint8Array<ArrayBuffer>;
  imageTitle?: string;
  imageSubtitle?: string;
  summary?: string;
};

export type MiniAppInput = MiniAppMeta & { layout: MiniAppLayout };

export type DiskCardData = {
  usedPercent: number;
  freeBytes: number;
  daysUntilFull?: number | null;
  hogs?: Hog[];
};

export function diskCard(meta: MiniAppMeta, d: DiskCardData): MiniAppInput {
  const pct = Math.round(d.usedPercent);
  const free = gb(d.freeBytes);
  const parts = [`${free} free`];
  if (d.daysUntilFull != null) parts.push(`full in ~${Math.round(d.daysUntilFull)} days`);
  const layout: MiniAppLayout = {
    caption: `⚠️ Disk ${pct}% full`,
    subcaption: parts.join(" · "),
    imageTitle: `${pct}% full`,
    imageSubtitle: `${free} free`,
    summary: `Burrow: disk ${pct}% full — ${free} free`,
  };
  if (d.hogs?.length) layout.trailingSubcaption = d.hogs[0].name;
  // The rich card data rides in the URL as ?p=<base64url BurrowLayout>; the
  // Burrow Cards extension decodes and renders it. caption/subcaption above are
  // the fallback bubble for recipients without the extension.
  const url = meta.url ? encodeLayoutURL(meta.url, diskLayout(d)) : meta.url;
  return { ...meta, url, layout };
}

/** Convenience: build DiskCardData from Burrow's own signals. */
export function diskCardFrom(meta: MiniAppMeta, root: Disk, forecast: Forecast | null, hogs: Hog[]): MiniAppInput {
  return diskCard(meta, {
    usedPercent: root.used_percent,
    freeBytes: root.total - root.used,
    daysUntilFull: forecast?.days_until_full ?? null,
    hogs,
  });
}
