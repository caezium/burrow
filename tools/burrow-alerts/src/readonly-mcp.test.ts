import { test, expect } from "bun:test";
import { reply } from "./readonly-mcp.ts";

test("the CLI MCP server blocks every unlisted tool even if CLI permissions allow it", async () => {
  const calls: string[] = [];
  const exec = async (name: string) => { calls.push(name); return "healthy"; };
  for (const name of ["burrow_clean", "burrow_remove", "burrow_analyze", "future_mutator"]) {
    const response = await reply({ id: 1, method: "tools/call", params: { name } }, exec);
    expect(response).toMatchObject({ result: { isError: true } });
  }
  expect(calls).toEqual([]);
  expect(await reply({ id: 2, method: "tools/call", params: { name: "burrow_snapshot" } }, exec))
    .toMatchObject({ result: { content: [{ text: "healthy" }] } });
  expect(calls).toEqual(["burrow_snapshot"]);
});
