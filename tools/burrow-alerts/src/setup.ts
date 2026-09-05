/**
 * Guided setup for "Burrow over iMessage". `assembleConfig` (pure, tested) builds
 * the validated config; the orchestration below (guarded by import.meta.main)
 * automates the Photon side via the `photon` CLI's device-code login — the same
 * flow we do by hand — then writes config.local.json.
 *
 *   bun run src/setup.ts        # interactive: photon device-code + write config
 */

import { spawnSync } from "node:child_process";
import { writeFileSync, chmodSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { LLMConfig } from "./llm.ts";
import { onboardingText } from "./onboarding.ts";

export type SetupParts = {
  recipient: string;
  projectId?: string;
  projectSecret?: string;
  llm?: LLMConfig;
};
export type BurrowConfig = {
  recipient: string;
  projectId?: string;
  projectSecret?: string;
  forceLocal?: boolean;
  llm: LLMConfig;
};

/** Build a validated config from collected parts. Cloud creds are both-or-neither. */
export function assembleConfig(parts: SetupParts): BurrowConfig {
  if (!parts.recipient?.trim()) throw new Error("recipient is required");
  if (parts.projectId && !parts.projectSecret) throw new Error("projectSecret missing — cloud needs both project id and secret");
  if (parts.projectSecret && !parts.projectId) throw new Error("projectId missing — cloud needs both project id and secret");
  return {
    recipient: parts.recipient.trim(),
    projectId: parts.projectId,
    projectSecret: parts.projectSecret,
    llm: parts.llm ?? { provider: "claude-cli" },
  };
}

// ---- interactive orchestration (not unit-tested; needs a real device) -------

// Photon egress is direct here; strip the shell proxy so the CLI reaches it.
const NOPROXY = { ...process.env, HTTP_PROXY: "", HTTPS_PROXY: "", ALL_PROXY: "", http_proxy: "", https_proxy: "", all_proxy: "", NO_PROXY: "*", no_proxy: "*" };
const photon = (args: string[]) => spawnSync("photon", args, { env: NOPROXY, encoding: "utf8", timeout: 30_000 });

function runSetup() {
  const recipient = process.env.BURROW_ALERT_TO ?? "";
  assembleConfig({ recipient }); // Validate before creating a remote project.
  console.log(onboardingText());
  console.log("\n──────────────────────────────────────────\n");

  // 1) Device-code login (Photon is free for one user).
  const who = photon(["whoami"]);
  if (who.status !== 0) {
    console.log("Log in to Photon (a device code will appear — approve it in your browser):\n");
    // The owner must see the device code while login is waiting for approval.
    const login = spawnSync("photon", ["login", "--no-browser"], { env: NOPROXY, stdio: "inherit", timeout: 300_000 });
    if (login.status !== 0) { console.error("Photon login failed"); process.exit(1); }
  }

  // 2) Create the project + read its secret.
  const created = photon(["projects", "create", "--name", "Burrow", "--platforms", "imessage", "--json"]);
  if (created.status !== 0) { console.error("Project create failed:", created.stderr); process.exit(1); }
  const projectId = JSON.parse(created.stdout).id as string;
  const secret = JSON.parse(photon(["projects", "secret", "--project", projectId, "--json"]).stdout).projectSecret as string;

  // 3) Register the owner number + surface the assigned line to text once (opt-in).
  const user = photon(["spectrum", "users", "add", "--project", projectId, "--phone", recipient, "--first-name", "Owner", "--last-name", "Burrow", "--email", "owner@example.com", "--invite", "--json"]);
  const assigned = user.status === 0 ? JSON.parse(user.stdout).assignedPhoneNumber : "(see dashboard)";

  // 4) Write config (LLM stays claude-cli unless env overrides).
  const cfg = assembleConfig({ recipient, projectId, projectSecret: secret });
  const out = join(dirname(fileURLToPath(import.meta.url)), "..", "config.local.json");
  writeFileSync(out, JSON.stringify(cfg, null, 2) + "\n", { mode: 0o600 });
  chmodSync(out, 0o600); // Existing manually-created config files may have been 0644.

  console.log(`\n✅ Wrote ${out}\n`);
  console.log(`One-time opt-in: from your iPhone, text anything to ${assigned}. Then:\n  bun run check.ts --test\n`);
}

if (import.meta.main) runSetup();
