/**
 * Multi-user safety primitives for the iMessage agent: owner authorization
 * (also the reply-loop guard), reply-length cap, and a rolling-window rate
 * limiter. Pure and injectable so they're testable without the SDK.
 */

export function digits(s: string): string {
  return (s ?? "").replace(/\D/g, "");
}

/** Canonical phone digits: strip a leading US/Canada country code so "+1 (555)…" and
 *  "5551234567" compare equal, WITHOUT the old bidirectional `endsWith` that authorized any
 *  suffix collision (e.g. a 7-digit sender matching an 11-digit owner) — a real auth bypass on
 *  the only gate protecting a system-reading assistant. */
function canonPhone(d: string): string {
  return d.length === 11 && d.startsWith("1") ? d.slice(1) : d;
}

/** True only for the configured owner. Numeric handles compare by canonical digits (formatting /
 *  +1 tolerated); email or other non-numeric handles compare case-insensitively verbatim. */
export function isPhoneHandle(handle: string): boolean {
  return /^\+?[\d\s().-]+$/.test(handle.trim()) && digits(handle).length > 0;
}

export function isAuthorized(senderId: string, ownerDigits: string): boolean {
  const sd = digits(senderId);
  const od = digits(ownerDigits);
  if (isPhoneHandle(senderId) && isPhoneHandle(ownerDigits)) return canonPhone(sd) === canonPhone(od);
  // No digits on one side ⇒ an email/handle: exact, case-insensitive match (never a suffix).
  const s = (senderId ?? "").trim().toLowerCase();
  const o = (ownerDigits ?? "").trim().toLowerCase();
  return s !== "" && s === o;
}

export type IncomingMessage = {
  direction?: string;
  sender?: { id?: string };
  content?: { type?: string; text?: string };
  space?: { id?: string; type?: string };
};

/** Mac health is private even when the owner also participates in group chats. */
export function isOwnerQuestion(message: IncomingMessage, owner: string): boolean {
  return message.direction === "inbound" && message.space?.type === "dm"
    && message.content?.type === "text" && isAuthorized(message.sender?.id ?? "", owner)
    && Boolean(message.content.text?.trim());
}

export function positiveInteger(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export function capReply(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1).trimEnd() + "…";
}

export class RateLimiter {
  private hits: number[] = [];
  constructor(private max: number, private windowMs: number) {}

  /** Record and allow if under the cap for the rolling window; else block. */
  allow(nowMs: number): boolean {
    const cutoff = nowMs - this.windowMs;
    while (this.hits.length && this.hits[0] <= cutoff) this.hits.shift();
    if (this.hits.length >= this.max) return false;
    this.hits.push(nowMs);
    return true;
  }
}
