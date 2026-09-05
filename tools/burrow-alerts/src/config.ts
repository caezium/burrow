/**
 * LLM provider resolution. Precedence: env (how the Swift app passes config to
 * the bundled sidecar) → config.local.json value → local `claude` CLI default.
 */

import type { LLMConfig } from "./llm.ts";
import { homedir } from "node:os";
import { join } from "node:path";
import type { SendConfig } from "./sender.ts";

type Env = Record<string, string | undefined>;

/** Swift and standalone runners use the same delivery precedence. */
export function resolveDelivery(env: Env, config: Partial<SendConfig> = {}, local = false): SendConfig {
  return {
    recipient: (env.BURROW_ALERT_TO ?? config.recipient ?? "").trim(),
    projectId: env.PHOTON_PROJECT_ID ?? config.projectId,
    projectSecret: env.PHOTON_PROJECT_SECRET ?? config.projectSecret,
    forceLocal: local || config.forceLocal,
    card: config.card,
  };
}

/** Runtime writes must never modify Contents/Resources in the signed app. */
export function stateDirectory(env: Env = process.env, home = homedir()): string {
  return env.BURROW_ALERT_STATE_DIR || join(home, "Library", "Application Support", "Burrow", "iMessage");
}

export function burrowMcpConfig(env: Env = process.env, proxy?: { command: string; entry: string }): string {
  return JSON.stringify({ mcpServers: { burrow: {
    command: proxy?.command ?? (env.BURROW_BIN || "/Applications/Burrow.app/Contents/MacOS/Burrow"),
    args: proxy ? ["run", proxy.entry] : ["--mcp"],
    ...(proxy ? { env: { BURROW_BIN: env.BURROW_BIN || "/Applications/Burrow.app/Contents/MacOS/Burrow" } } : {}),
  } } });
}

export function resolveLLM(env: Env, fromConfig?: LLMConfig): LLMConfig {
  const p = env.BURROW_LLM_PROVIDER;
  if (p) {
    const apiKey = env.BURROW_LLM_KEY ?? "";
    const model = env.BURROW_LLM_MODEL ?? "";
    switch (p) {
      case "openrouter":
      case "openai":
        return { provider: p, apiKey, model };
      case "openai-compat":
        return { provider: p, baseUrl: env.BURROW_LLM_BASEURL ?? "", apiKey, model };
      case "anthropic":
        return { provider: p, apiKey, ...(model.trim() ? { model } : {}) };
      case "claude-cli":
        return { provider: "claude-cli", ...(env.BURROW_LLM_MODEL ? { model } : {}) };
    }
  }
  return fromConfig ?? { provider: "claude-cli" };
}
