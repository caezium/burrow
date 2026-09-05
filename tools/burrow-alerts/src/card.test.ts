import { test, expect } from "bun:test";
import { diskCard, type MiniAppMeta } from "./card.ts";
import { decodeLayoutURL } from "./burrowlayout.ts";

const meta: MiniAppMeta = {
  appName: "Burrow",
  extensionBundleId: "dev.caezium.Burrow.cards.extension",
  teamId: "ABCDE12345",
  url: "https://burrow.henryzh.dev",
};

test("diskCard builds a mini-app card: caption, subcaption, lock-screen summary, deep link", () => {
  const c = diskCard(meta, { usedPercent: 98.9, freeBytes: 6.1e9, daysUntilFull: 6, hogs: [] });
  expect(c.appName).toBe("Burrow");
  expect(c.extensionBundleId).toBe("dev.caezium.Burrow.cards.extension");
  expect(c.teamId).toBe("ABCDE12345");
  // url carries the BurrowLayout as a base64url ?p= payload the extension decodes
  expect(c.url.startsWith("https://burrow.henryzh.dev/?p=")).toBe(true);
  expect(decodeLayoutURL(c.url).title).toContain("99% full");
  expect(c.layout.caption).toContain("99% full");
  expect(c.layout.subcaption).toContain("6.1 GB free");
  // image overlay text (the bytes are attached at send time, not here)
  expect(c.layout.imageTitle).toBe("99% full");
  expect(c.layout.imageSubtitle).toBe("6.1 GB free");
  expect(c.layout.subcaption).toContain("~6 days");
  expect(c.layout.summary?.toLowerCase()).toContain("disk 99% full");
});

test("diskCard omits the forecast line when there's no trend", () => {
  const c = diskCard(meta, { usedPercent: 91, freeBytes: 20e9, daysUntilFull: null });
  expect(c.layout.subcaption).toBe("20 GB free");
});
