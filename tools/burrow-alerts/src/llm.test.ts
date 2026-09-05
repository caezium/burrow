import { test, expect } from "bun:test";
import { makeOpenAICompatBrain, makeClaudeCliBrain, selectProvider, defaultRunCli } from "./llm.ts";

// A fake OpenAI-compatible /chat/completions endpoint that returns queued
// responses in order, so we can drive the brain deterministically.
function fakeFetch(responses: any[]) {
  const queue = [...responses];
  const calls: any[] = [];
  const urls: string[] = [];
  const fn = async (url: string, init: any) => {
    urls.push(url);
    calls.push(JSON.parse(init.body));
    const body = queue.shift();
    return { ok: true, json: async () => body } as any;
  };
  (fn as any).calls = calls;
  (fn as any).urls = urls;
  return fn as any;
}

test("selectProvider routes named providers to their base URLs", async () => {
  for (const [provider, host] of [["openrouter", "openrouter.ai"], ["openai", "api.openai.com"]] as const) {
    const fetchImpl = fakeFetch([{ choices: [{ message: { content: "ok" } }] }]);
    const brain = selectProvider({ provider, apiKey: "k", model: "m" } as any, { fetchImpl });
    await brain.ask("q", { system: "s", tools: [], exec: async () => "" });
    expect(fetchImpl.urls[0]).toContain(host);
    expect(fetchImpl.urls[0]).toContain("/chat/completions");
  }
});

test("selectProvider routes claude-cli via injected cli deps", async () => {
  const seen: any = {};
  const brain = selectProvider(
    { provider: "claude-cli" },
    { cli: { mcpConfigPath: "/m.json", allowedTools: ["mcp__burrow__burrow_doctor"], runCli: async (a: string[]) => { seen.args = a; return "ok"; } } },
  );
  const a = await brain.ask("q", { system: "s", tools: [], exec: async () => "" });
  expect(a).toBe("ok");
  expect(seen.args).toContain("/m.json");
});

test("selectProvider honors a custom openai-compat baseUrl", async () => {
  const fetchImpl = fakeFetch([{ choices: [{ message: { content: "ok" } }] }]);
  const brain = selectProvider(
    { provider: "openai-compat", baseUrl: "https://llm.internal/v1", apiKey: "k", model: "m" },
    { fetchImpl },
  );
  await brain.ask("q", { system: "s", tools: [], exec: async () => "" });
  expect(fetchImpl.urls[0]).toBe("https://llm.internal/v1/chat/completions");
});

test("claude-cli brain shells claude with the burrow mcp config and returns its output", async () => {
  const seen: any = {};
  const runCli = async (args: string[]) => { seen.args = args; return "6 GB free (via claude)."; };
  const brain = makeClaudeCliBrain(
    { mcpConfigPath: "/x/burrow-mcp.json", allowedTools: ["mcp__burrow__burrow_snapshot"] },
    { runCli },
  );
  const a = await brain.ask("how's my disk?", { system: "be brief", tools: [], exec: async () => "" });

  expect(a).toBe("6 GB free (via claude).");
  expect(seen.args.slice(seen.args.indexOf("--tools"), seen.args.indexOf("--tools") + 2)).toEqual(["--tools", ""]);
  expect(seen.args).toEqual(expect.arrayContaining(["--permission-mode", "dontAsk", "--setting-sources", "", "--no-session-persistence"]));
  expect(seen.args).toEqual(expect.arrayContaining([
    "-p", "how's my disk?", "--mcp-config", "/x/burrow-mcp.json",
    "--strict-mcp-config", "--allowedTools", "mcp__burrow__burrow_snapshot",
    "--append-system-prompt", "be brief",
  ]));
});

test("both API providers abort a stalled request", async () => {
  for (const provider of ["openai", "anthropic"] as const) {
    const fetchImpl = ((_url: unknown, init: RequestInit) => new Promise((_resolve, reject) => {
      init.signal!.addEventListener("abort", () => reject(init.signal!.reason));
    })) as typeof fetch;
    const brain = selectProvider({ provider, apiKey: "fake", model: "fake" }, { fetchImpl, timeoutMs: 10 });
    await expect(brain.ask("test", { system: "test", tools: [], exec: async () => "" })).rejects.toThrow("timed out");
  }
});

test("CLI drains stderr and surfaces failure or timeout without running a real model", async () => {
  const run = defaultRunCli(false, process.execPath, 1_000);
  expect(await run(["-e", "process.stderr.write('x'.repeat(200000)); console.log('answer')"])).toBe("answer");
  await expect(run(["-e", "process.exit(3)"])).rejects.toThrow("exited (3)");
  await expect(defaultRunCli(false, process.execPath, 30)(["-e", "setInterval(() => {}, 1000)"])).rejects.toThrow("timed out");
});

test("anthropic brain returns text and can run a tool round", async () => {
  const fetchImpl = fakeFetch([
    // round 1: model wants a tool
    { stop_reason: "tool_use", content: [
      { type: "tool_use", id: "tu1", name: "burrow_disk_forecast", input: {} },
    ] },
    // round 2: final text
    { stop_reason: "end_turn", content: [{ type: "text", text: "Full in ~6 days." }] },
  ]);
  const execCalls: Array<[string, any]> = [];
  const exec = async (n: string, a: any) => { execCalls.push([n, a]); return '{"days":6}'; };

  const brain = selectProvider({ provider: "anthropic", apiKey: "k", model: "claude-x" }, { fetchImpl });
  const tools = [{ name: "burrow_disk_forecast", description: "forecast", schema: { type: "object" } }];
  const answer = await brain.ask("when's my disk full?", { system: "s", tools, exec });

  expect(answer).toBe("Full in ~6 days.");
  expect(execCalls).toEqual([["burrow_disk_forecast", {}]]);
  expect(fetchImpl.urls[0]).toContain("api.anthropic.com");
  // round 2 carried a tool_result block referencing the tool_use id
  const round2 = fetchImpl.calls[1].messages.at(-1);
  expect(round2.content[0]).toMatchObject({ type: "tool_result", tool_use_id: "tu1", content: '{"days":6}' });
});

test("openai-compat brain runs a tool call, feeds the result back, and answers", async () => {
  const fetchImpl = fakeFetch([
    // round 1: model asks to call a tool
    { choices: [{ message: { role: "assistant", content: null, tool_calls: [
      { id: "c1", type: "function", function: { name: "burrow_snapshot", arguments: "{}" } },
    ] } }] },
    // round 2: model gives the final answer
    { choices: [{ message: { role: "assistant", content: "Disk is 99% full — 6 GB free." } }] },
  ]);
  const execCalls: Array<[string, any]> = [];
  const exec = async (name: string, args: any) => { execCalls.push([name, args]); return '{"free_gb":6}'; };

  const brain = makeOpenAICompatBrain(
    { baseUrl: "https://api.openai.com/v1", apiKey: "sk", model: "gpt" },
    { fetchImpl },
  );
  const tools = [{ name: "burrow_snapshot", description: "disk/cpu snapshot", schema: { type: "object" } }];
  const answer = await brain.ask("how's my disk?", { system: "s", tools, exec });

  expect(answer).toBe("Disk is 99% full — 6 GB full.".replace("full.", "free."));
  expect(execCalls).toEqual([["burrow_snapshot", {}]]);
  // round 1 advertised the tool
  expect(fetchImpl.calls[0].tools?.[0]?.function?.name).toBe("burrow_snapshot");
  // round 2 carried the tool result back as a tool-role message
  const round2 = fetchImpl.calls[1].messages;
  expect(round2.some((m: any) => m.role === "tool" && m.tool_call_id === "c1" && m.content === '{"free_gb":6}')).toBe(true);
});

test("openai-compat brain returns the assistant's answer when no tools are needed", async () => {
  const fetchImpl = fakeFetch([
    { choices: [{ message: { role: "assistant", content: "You have 6.1 GB free — you're fine." } }] },
  ]);
  const brain = makeOpenAICompatBrain(
    { baseUrl: "https://openrouter.ai/api/v1", apiKey: "sk-test", model: "x" },
    { fetchImpl },
  );

  const answer = await brain.ask("how's my disk?", { system: "be brief", tools: [], exec: async () => "" });

  expect(answer).toBe("You have 6.1 GB free — you're fine.");
  // it POSTed the user question + system prompt
  expect(fetchImpl.calls[0].messages).toEqual([
    { role: "system", content: "be brief" },
    { role: "user", content: "how's my disk?" },
  ]);
});
