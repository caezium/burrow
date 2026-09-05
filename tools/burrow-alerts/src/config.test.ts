import { test, expect } from "bun:test";
import { resolveLLM, resolveDelivery, stateDirectory, burrowMcpConfig } from "./config.ts";
import { useCloud } from "./sender.ts";

test("the native app's environment selects cloud delivery and preserves owner handles", () => {
  const cfg = resolveDelivery({ BURROW_ALERT_TO: "owner42@example.com", PHOTON_PROJECT_ID: "p", PHOTON_PROJECT_SECRET: "s" });
  expect(useCloud(cfg)).toBe(true);
  expect(cfg.recipient).toBe("owner42@example.com");
  expect(useCloud(resolveDelivery({}, cfg, true))).toBe(false);
});

test("runtime files live in Application Support, and MCP follows the running app", () => {
  expect(stateDirectory({}, "/Users/Test")).toBe("/Users/Test/Library/Application Support/Burrow/iMessage");
  expect(stateDirectory({ BURROW_ALERT_STATE_DIR: "/tmp/test-state" })).toBe("/tmp/test-state");
  expect(JSON.parse(burrowMcpConfig({ BURROW_BIN: "/tmp/Test Burrow.app/Contents/MacOS/Burrow" })).mcpServers.burrow.command)
    .toBe("/tmp/Test Burrow.app/Contents/MacOS/Burrow");
});

test("an empty Anthropic model uses the provider default", () => {
  expect(resolveLLM({ BURROW_LLM_PROVIDER: "anthropic", BURROW_LLM_KEY: "k", BURROW_LLM_MODEL: "" }))
    .toEqual({ provider: "anthropic", apiKey: "k" });
});

test("resolveLLM reads a named provider from env", () => {
  expect(resolveLLM({ BURROW_LLM_PROVIDER: "openrouter", BURROW_LLM_KEY: "k", BURROW_LLM_MODEL: "m" }))
    .toEqual({ provider: "openrouter", apiKey: "k", model: "m" });
});

test("resolveLLM reads openai-compat with a base URL from env", () => {
  expect(resolveLLM({ BURROW_LLM_PROVIDER: "openai-compat", BURROW_LLM_KEY: "k", BURROW_LLM_MODEL: "m", BURROW_LLM_BASEURL: "http://x/v1" }))
    .toEqual({ provider: "openai-compat", baseUrl: "http://x/v1", apiKey: "k", model: "m" });
});

test("resolveLLM falls back to the config value when env is absent", () => {
  expect(resolveLLM({}, { provider: "anthropic", apiKey: "a", model: "c" }))
    .toEqual({ provider: "anthropic", apiKey: "a", model: "c" });
});

test("resolveLLM defaults to the local claude CLI when nothing is set", () => {
  expect(resolveLLM({})).toEqual({ provider: "claude-cli" });
});
