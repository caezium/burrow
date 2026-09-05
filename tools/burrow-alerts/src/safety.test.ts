import { test, expect } from "bun:test";
import { isAuthorized, isOwnerQuestion, capReply, RateLimiter } from "./safety.ts";
import { toE164 } from "./sender.ts";

test("numeric email handles cannot impersonate the owner or turn into phone recipients", () => {
  expect(isAuthorized("15551234567@attacker.example", "+15551234567")).toBe(false);
  expect(isAuthorized("owner42@attacker.example", "owner42@example.com")).toBe(false);
  expect(isAuthorized("OWNER42@EXAMPLE.COM", "owner42@example.com")).toBe(true);
  expect(toE164("5551234567@example.com")).toBe("5551234567@example.com");
});

test("only incoming owner DMs can cause a health reply", () => {
  const message = { direction: "inbound", sender: { id: "+15551234567" }, space: { type: "dm" }, content: { type: "text", text: "disk?" } };
  expect(isOwnerQuestion(message, "+15551234567")).toBe(true);
  expect(isOwnerQuestion({ ...message, direction: "outbound" }, "+15551234567")).toBe(false);
  expect(isOwnerQuestion({ ...message, space: { type: "group" } }, "+15551234567")).toBe(false);
  expect(isOwnerQuestion({ ...message, direction: undefined }, "+15551234567")).toBe(false);
});

test("RateLimiter allows up to max per window, blocks beyond, and recovers", () => {
  const rl = new RateLimiter(2, 1000); // 2 per 1000ms; time injected
  expect(rl.allow(0)).toBe(true);
  expect(rl.allow(100)).toBe(true);
  expect(rl.allow(200)).toBe(false);  // 3rd inside window
  expect(rl.allow(1201)).toBe(true);  // first two aged out
});

test("capReply truncates long replies with an ellipsis and leaves short ones", () => {
  expect(capReply("short", 800)).toBe("short");
  const out = capReply("a".repeat(900), 800);
  expect(out.length).toBe(800);
  expect(out.endsWith("…")).toBe(true);
});

test("isAuthorized accepts the owner's number (any formatting) and rejects others", () => {
  const owner = "8613410272240";
  expect(isAuthorized("+8613410272240", owner)).toBe(true);   // E.164
  expect(isAuthorized("8613410272240", owner)).toBe(true);    // bare
  expect(isAuthorized("+1 (555) 000-1111", owner)).toBe(false); // someone else
  expect(isAuthorized("", owner)).toBe(false);                 // empty sender
  expect(isAuthorized("+8613410272240", "")).toBe(false);     // no owner configured
});

test("isAuthorized rejects suffix collisions (the old endsWith bypass)", () => {
  const owner = "+15551234567"; // US, +1
  expect(isAuthorized("+1 (555) 123-4567", owner)).toBe(true);  // same number, formatted
  expect(isAuthorized("5551234567", owner)).toBe(true);         // bare 10-digit, +1 dropped
  expect(isAuthorized("1234567", owner)).toBe(false);           // 7-digit suffix — MUST NOT match
  expect(isAuthorized("4567", owner)).toBe(false);              // short suffix — MUST NOT match
  expect(isAuthorized("+8615551234567", owner)).toBe(false);    // owner digits as a suffix of a +86 number
});

test("isAuthorized matches email/handle owners exactly, case-insensitively", () => {
  const owner = "Owner@Example.com";
  expect(isAuthorized("owner@example.com", owner)).toBe(true);
  expect(isAuthorized("someone@example.com", owner)).toBe(false);
  expect(isAuthorized("example.com", owner)).toBe(false); // not a suffix match
});
