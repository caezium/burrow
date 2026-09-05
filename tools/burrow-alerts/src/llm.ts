/**
 * Provider-agnostic LLM brain for the Burrow iMessage agent. Bring-your-own key:
 * OpenRouter / OpenAI / any OpenAI-compatible endpoint, native Anthropic, or the
 * local `claude` coding-agent CLI. Each brain answers a question, optionally
 * calling Burrow's read-only tools, and returns plain text.
 */

import { spawn } from "node:child_process";
import { trackChild, terminateChild, fetchJson } from "./lifecycle.ts";

export type ToolSpec = { name: string; description: string; schema: object };
export type ToolExec = (name: string, args: any) => Promise<string>;
export type AskOpts = { system: string; tools: ToolSpec[]; exec: ToolExec };
export interface Brain {
  ask(question: string, opts: AskOpts): Promise<string>;
}

export type OpenAICompatCfg = { baseUrl: string; apiKey: string; model: string };
type Deps = {
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  // App-level context for the claude-cli provider (not part of user LLMConfig).
  cli?: { mcpConfigPath: string; allowedTools: string[]; runCli?: (args: string[]) => Promise<string>; useJan?: boolean };
};

/** BYO-key provider config. `openai-compat` covers any OpenAI-compatible host. */
export type LLMConfig =
  | { provider: "openrouter"; apiKey: string; model: string }
  | { provider: "openai"; apiKey: string; model: string }
  | { provider: "openai-compat"; baseUrl: string; apiKey: string; model: string }
  | { provider: "anthropic"; apiKey: string; model?: string }
  | { provider: "claude-cli"; model?: string };

const NAMED_BASE_URLS: Record<string, string> = {
  openrouter: "https://openrouter.ai/api/v1",
  openai: "https://api.openai.com/v1",
};

/** Pick the brain implementation for a provider config. */
export function selectProvider(cfg: LLMConfig, deps: Deps = {}): Brain {
  switch (cfg.provider) {
    case "openrouter":
    case "openai":
      return makeOpenAICompatBrain({ baseUrl: NAMED_BASE_URLS[cfg.provider], apiKey: cfg.apiKey, model: cfg.model }, deps);
    case "openai-compat":
      return makeOpenAICompatBrain({ baseUrl: cfg.baseUrl, apiKey: cfg.apiKey, model: cfg.model }, deps);
    case "anthropic":
      return makeAnthropicBrain({ apiKey: cfg.apiKey, model: cfg.model ?? "claude-sonnet-5" }, deps);
    case "claude-cli":
      if (!deps.cli) throw new Error("claude-cli provider needs cli deps (mcpConfigPath, allowedTools)");
      return makeClaudeCliBrain(
        { model: cfg.model, mcpConfigPath: deps.cli.mcpConfigPath, allowedTools: deps.cli.allowedTools, useJan: deps.cli.useJan },
        { runCli: deps.cli.runCli },
      );
    default:
      throw new Error(`provider not implemented: ${(cfg as any).provider}`);
  }
}

// --- local coding-agent CLI (`claude`) ---------------------------------------
// Delegates tool use to the CLI's own Burrow MCP server, so it ignores the
// AskOpts tools/exec. Injectable runner for tests; the default spawns `claude`
// with the Jan-routing env vars stripped (so it uses the real login).
export type ClaudeCliCfg = { model?: string; mcpConfigPath: string; allowedTools: string[]; useJan?: boolean };
type CliDeps = { runCli?: (args: string[]) => Promise<string> };

export function defaultRunCli(useJan: boolean, command = "claude", timeoutMs = 180_000): (args: string[]) => Promise<string> {
  return (args) =>
    new Promise((resolve, reject) => {
      const env = { ...process.env };
      if (!useJan) { delete env.ANTHROPIC_BASE_URL; delete env.ANTHROPIC_AUTH_TOKEN; }
      const child = trackChild(spawn(command, args, { stdio: ["ignore", "pipe", "pipe"], env, detached: true }));
      let out = "";
      const timer = setTimeout(() => {
        void terminateChild(child);
        reject(new Error("Claude CLI timed out"));
      }, timeoutMs);
      child.stdout!.setEncoding("utf8");
      child.stdout!.on("data", (d: string) => {
        if (out.length + d.length > 1_000_000) {
          clearTimeout(timer); void terminateChild(child); reject(new Error("Claude CLI output exceeded limit"));
        } else out += d;
      });
      child.stderr!.resume(); // Never let diagnostics fill a pipe and block the answer.
      child.on("close", (code) => { clearTimeout(timer); code === 0 ? resolve(out.trim()) : reject(new Error(`Claude CLI exited (${code})`)); });
      child.on("error", (error) => { clearTimeout(timer); reject(error); });
    });
}

export function makeClaudeCliBrain(cfg: ClaudeCliCfg, deps: CliDeps = {}): Brain {
  const run = deps.runCli ?? defaultRunCli(cfg.useJan ?? false);
  return {
    async ask(question, { system }) {
      const model = cfg.model ? ["--model", cfg.model] : [];
      return run([
        "-p", question,
        "--mcp-config", cfg.mcpConfigPath,
        "--strict-mcp-config",
        "--tools", "", // allowedTools grants permissions; it does not remove built-in tools.
        "--permission-mode", "dontAsk",
        "--setting-sources", "",
        "--settings", JSON.stringify({ disableAllHooks: true }),
        "--disable-slash-commands",
        "--no-session-persistence",
        "--allowedTools", ...cfg.allowedTools,
        "--append-system-prompt", system,
        ...model,
      ]);
    },
  };
}

export type AnthropicCfg = { apiKey: string; model: string; baseUrl?: string };

export function makeAnthropicBrain(cfg: AnthropicCfg, deps: Deps = {}): Brain {
  const doFetch = deps.fetchImpl ?? fetch;
  const url = `${cfg.baseUrl ?? "https://api.anthropic.com"}/v1/messages`;
  return {
    async ask(question, { system, tools, exec }) {
      const messages: any[] = [{ role: "user", content: question }];
      const toolPayload = tools.length
        ? tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.schema }))
        : undefined;

      for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
        const res = await fetchJson(doFetch, url, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-api-key": cfg.apiKey,
            "anthropic-version": "2023-06-01",
          },
          body: JSON.stringify({ model: cfg.model, max_tokens: 1024, system, messages, tools: toolPayload }),
        }, deps.timeoutMs);
        // Without this an auth/rate-limit/5xx returns a body with no `content`, the brain yields
        // "", and the agent texts the owner a BLANK bubble. Surface the failure instead.
        if (!(res as any).ok) return `I couldn't reach the model (HTTP ${(res as any).status}).`;
        const json = res.body;
        const content: any[] = json.content ?? [];

        if (json.stop_reason === "tool_use") {
          messages.push({ role: "assistant", content });
          const results = [];
          for (const block of content) {
            if (block.type !== "tool_use") continue;
            const out = await exec(block.name, block.input ?? {});
            results.push({ type: "tool_result", tool_use_id: block.id, content: out });
          }
          messages.push({ role: "user", content: results });
          continue;
        }
        return content.filter((b) => b.type === "text").map((b) => b.text).join("").trim();
      }
      return "I couldn't finish looking that up — try a narrower question.";
    },
  };
}

const MAX_TOOL_ROUNDS = 6; // bound the tool-use loop so a model can't spin forever

export function makeOpenAICompatBrain(cfg: OpenAICompatCfg, deps: Deps = {}): Brain {
  const doFetch = deps.fetchImpl ?? fetch;
  return {
    async ask(question, { system, tools, exec }) {
      const messages: any[] = [
        { role: "system", content: system },
        { role: "user", content: question },
      ];
      const toolPayload = tools.length
        ? tools.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.schema } }))
        : undefined;

      for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
        const res = await fetchJson(doFetch, `${cfg.baseUrl}/chat/completions`, {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${cfg.apiKey}` },
          body: JSON.stringify({ model: cfg.model, messages, tools: toolPayload }),
        }, deps.timeoutMs);
        // See the Anthropic brain: a non-2xx here otherwise becomes an empty reply → blank iMessage.
        if (!(res as any).ok) return `I couldn't reach the model (HTTP ${(res as any).status}).`;
        const json = res.body;
        const msg = json.choices?.[0]?.message ?? {};

        const toolCalls = msg.tool_calls ?? [];
        if (!toolCalls.length) return msg.content ?? "";

        messages.push(msg); // the assistant turn that requested the tools
        for (const call of toolCalls) {
          let args: any = {};
          try { args = JSON.parse(call.function?.arguments || "{}"); } catch {}
          const result = await exec(call.function?.name, args);
          messages.push({ role: "tool", tool_call_id: call.id, content: result });
        }
      }
      return "I couldn't finish looking that up — try a narrower question.";
    },
  };
}
