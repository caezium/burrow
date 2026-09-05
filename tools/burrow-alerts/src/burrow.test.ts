/**
 * BurrowMCP lifecycle: a missing Burrow.app must surface as a normal rejection, NOT an uncaught
 * 'error' that bypasses every .catch and (in the long-lived agent) becomes a crash loop.
 */
import { test, expect } from "bun:test";

import { BurrowMCP } from "./burrow.ts";
const missingBinary = "/definitely/not/real/burrow-binary-xyz-does-not-exist";

test("a missing burrow binary rejects the call instead of throwing uncaught", async () => {
  const mcp = new BurrowMCP(missingBinary);
  // Spawn ENOENT fires 'error' async → die() rejects `ready` and all pending calls.
  await expect(mcp.toolText("burrow_snapshot")).rejects.toThrow();
  await mcp.close();
});

test("further calls after death reject fast and don't hang", async () => {
  const mcp = new BurrowMCP(missingBinary);
  await expect(mcp.toolText("burrow_snapshot")).rejects.toThrow();
  // Second call after the child is dead: immediate rejection, no 15s timeout wait.
  const t0 = Date.now();
  await expect(mcp.toolText("burrow_disk_forecast")).rejects.toThrow();
  expect(Date.now() - t0).toBeLessThan(1_000);
  await mcp.close();
});

test("a clean child exit rejects a pending initialization immediately", async () => {
  const mcp = new BurrowMCP(process.execPath, ["-e", "process.exit(0)"]);
  const started = Date.now();
  try {
    await expect(mcp.toolText("burrow_snapshot")).rejects.toThrow("exited");
    expect(Date.now() - started).toBeLessThan(1000);
  } finally { await mcp.close(); }
});

test("MCP preserves Unicode split between chunks and surfaces tool errors", async () => {
  const source = `
    import {createInterface} from 'node:readline';
    for await (const line of createInterface({input:process.stdin})) {
      const request=JSON.parse(line); if (!request.id) continue;
      const result=request.method==='initialize' ? {} : {isError:request.params.name==='fail',content:[{type:'text',text:'healthy 🌕'}]};
      const bytes=Buffer.from(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\\n');
      const split=bytes.indexOf(Buffer.from('🌕'))+1;
      process.stdout.write(bytes.subarray(0,split));
      await Bun.sleep(5);
      process.stdout.write(bytes.subarray(split));
    }
  `;
  const mcp = new BurrowMCP(process.execPath, ["-e", source]);
  try {
    expect(await mcp.toolText("ok")).toBe("healthy 🌕");
    await expect(mcp.toolText("fail")).rejects.toThrow("healthy 🌕");
  } finally { await mcp.close(); }
});
