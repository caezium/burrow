/** CLI-side MCP boundary: only the same read-only tools exposed to API brains. */
import { createInterface } from "node:readline";
import { BurrowMCP } from "./burrow.ts";
import { READONLY_TOOL_SPECS, makeBurrowExec } from "./burrow-tools.ts";
import { installShutdown, stopChildren } from "./lifecycle.ts";

type Request = { id?: string | number; method?: string; params?: { name?: string; arguments?: Record<string, unknown> } };
export async function reply(request: Request, exec: (name: string, args: Record<string, unknown>) => Promise<string>) {
  if (request.id === undefined) return undefined;
  let result: object;
  switch (request.method) {
    case "initialize":
      result = { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "burrow-readonly", version: "0.1.0" } };
      break;
    case "tools/list":
      result = { tools: READONLY_TOOL_SPECS.map(({ name, description, schema }) => ({ name, description, inputSchema: schema })) };
      break;
    case "tools/call": {
      const name = request.params?.name ?? "";
      if (!READONLY_TOOL_SPECS.some((tool) => tool.name === name)) {
        result = { isError: true, content: [{ type: "text", text: "Tool is not read-only or not allowed." }] };
      } else {
        result = { content: [{ type: "text", text: await exec(name, request.params?.arguments ?? {}) }] };
      }
      break;
    }
    case "ping": result = {}; break;
    default: return { jsonrpc: "2.0", id: request.id, error: { code: -32601, message: "Method not found" } };
  }
  return { jsonrpc: "2.0", id: request.id, result };
}

async function main() {
  let mcp: BurrowMCP | undefined;
  const execute = async (name: string, args: Record<string, unknown>) => {
    mcp ??= new BurrowMCP();
    return makeBurrowExec(mcp)(name, args);
  };
  installShutdown();
  try {
    for await (const line of createInterface({ input: process.stdin })) {
      try {
        const result = await reply(JSON.parse(line) as Request, execute);
        if (result) process.stdout.write(JSON.stringify(result) + "\n");
      } catch {
        process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Invalid request" } }) + "\n");
      }
    }
  } finally { await stopChildren(); }
}
if (import.meta.main) void main();
