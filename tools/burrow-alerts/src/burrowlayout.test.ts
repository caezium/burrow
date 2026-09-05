import { test, expect } from "bun:test";
import { diskLayout, encodeLayoutURL, decodeLayoutURL, type BurrowLayout } from "./burrowlayout.ts";

test("diskLayout builds a system-health card: title, progress, free-space row, clean action", () => {
  const l = diskLayout({ usedPercent: 98.9, freeBytes: 6.1e9, daysUntilFull: 6, hogs: [{ name: "Library", size: 160e9 }] });
  expect(l.version).toBe(1);
  expect(l.title.toLowerCase()).toContain("disk");
  // a progressBar reflecting fill fraction (~0.99)
  const bar = findNode(l.root, (n) => n.type === "progressBar") as any;
  expect(bar).toBeTruthy();
  expect(bar.value).toBeCloseTo(0.989, 2);
  // a Free key/value row carrying the human free size
  const free = findNode(l.root, (n) => n.type === "keyValueRow" && n.key === "Free") as any;
  expect(free?.value).toContain("6.1 GB");
  // a tap-to-clean action
  expect(l.actions?.some((a) => a.deepLinkURL.startsWith("burrow://action"))).toBe(true);
});

test("encode/decode round-trips the layout through a base64url ?p= URL (Photon transport)", () => {
  const l = diskLayout({ usedPercent: 91, freeBytes: 20e9, daysUntilFull: null });
  const url = encodeLayoutURL("https://burrow.henryzh.dev/card", l);
  expect(url.startsWith("https://burrow.henryzh.dev/card?p=")).toBe(true);
  const payload = new URL(url).searchParams.get("p")!;
  expect(payload).not.toMatch(/[+/=]/); // base64url alphabet only — URL-safe, no +/=
  const back = decodeLayoutURL(url);
  expect(back).toEqual(l);
});

test("card URLs replace old payloads and keep fragments out of the query", () => {
  const layout = diskLayout({ usedPercent: 91, freeBytes: 20e9 });
  const encoded = encodeLayoutURL("https://example.com/card?p=stale&mode=small#details", layout);
  expect(new URL(encoded).hash).toBe("#details");
  expect(new URL(encoded).searchParams.getAll("p")).toHaveLength(1);
  expect(decodeLayoutURL(encoded)).toEqual(layout);
});

function findNode(n: any, pred: (n: any) => boolean): any {
  if (pred(n)) return n;
  for (const c of n.children ?? []) {
    const hit = findNode(c, pred);
    if (hit) return hit;
  }
  return null;
}
