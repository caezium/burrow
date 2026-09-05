/**
 * Delivery via Photon spectrum-ts. Cloud mode (managed Photon line) when a
 * projectId + projectSecret are present; local mode (this Mac's chat.db)
 * otherwise. Space resolution + send are identical either way — a shared-mode
 * DM guid (`any;-;<addr>`) needs no server call.
 *
 * Cloud note: the target must be opted in (text the project's assigned line
 * once) or sends fail with "Target not allowed for this project".
 */

import type { MiniAppInput } from "./card.ts";
import { isPhoneHandle } from "./safety.ts";

export type SendConfig = {
  recipient: string;
  projectId?: string;
  projectSecret?: string;
  forceLocal?: boolean;
  /** When set (and in cloud mode), alerts render as mini-app cards. */
  card?: {
    appName: string;
    extensionBundleId: string;
    teamId: string;
    url: string;
    appStoreId?: number;
  };
};

const dmGuid = (addr: string) => `any;-;${addr}`;

export function toE164(phone: string): string {
  const raw = phone.trim();
  if (!isPhoneHandle(raw)) return raw;
  const digits = raw.replace(/\D/g, "");
  if (raw.startsWith("+")) return `+${digits}`;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return raw; // email / already-odd handle: pass through
}

export function useCloud(cfg: SendConfig): boolean {
  return !cfg.forceLocal && Boolean(cfg.projectId && cfg.projectSecret);
}

/** Build the app + self-DM space, run `fn`, then shut down cleanly. */
async function withSpace<T>(cfg: SendConfig, fn: (space: any, sdk: any) => Promise<T>): Promise<T> {
  const sdk = await import("spectrum-ts");
  const { imessage } = await import("spectrum-ts/providers/imessage");
  const to = toE164(cfg.recipient);
  const app = useCloud(cfg)
    ? await sdk.Spectrum({ projectId: cfg.projectId!, projectSecret: cfg.projectSecret!, providers: [imessage.config()] })
    : await sdk.Spectrum({ providers: [imessage.config({ local: true })] });
  try {
    const im = imessage(app);
    const space = await im.space.get(dmGuid(to));
    return await fn(space, sdk);
  } finally {
    await app.stop();
  }
}

/** Send one text. The inbound watcher is lazy, so this exits cleanly. */
export async function sendText(cfg: SendConfig, body: string): Promise<void> {
  await withSpace(cfg, async (space, sdk) => { await space.send(sdk.text(body)); });
}

/**
 * Load the bundled Burrow bubble image (JPEG). Best-effort — a missing asset
 * just means the card ships without an image (captions/summary still render).
 */
async function bubbleImage(): Promise<Uint8Array<ArrayBuffer> | undefined> {
  try {
    const path = new URL("../assets/burrow-card.jpg", import.meta.url);
    return await Bun.file(path).bytes();
  } catch {
    return undefined;
  }
}

/**
 * Send an alert as a mini-app card (cloud-only), falling back to `fallbackText`
 * when cards aren't available (local mode) or the SDK rejects the card. Attaches
 * the bundled bubble image unless the caller already set one.
 */
export async function sendCard(cfg: SendConfig, card: MiniAppInput, fallbackText: string): Promise<void> {
  if (!card.layout.image) {
    const image = await bubbleImage();
    if (image) card = { ...card, layout: { ...card.layout, image } };
  }
  await withSpace(cfg, async (space, sdk) => {
    const { customizedMiniApp } = await import("spectrum-ts/providers/imessage");
    try {
      await space.send(customizedMiniApp(card));
    } catch (e: any) {
      console.log(`[sender] mini-app card unavailable (${e?.message ?? e}) — sending text`);
      await space.send(sdk.text(fallbackText));
    }
  });
}
