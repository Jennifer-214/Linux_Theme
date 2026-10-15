// tests/fox-trim-test.mjs — drives fox-trim's tool_result handler with fake events.
// Run via tests/test_fox_trim.py (skips when node is missing). XDG_CACHE_HOME points at a throwaway folder.
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.argv[2]).href);
let handler;
mod.default({ on: (ev, fn) => { if (ev === "tool_result") handler = fn; } });
let fail = 0;
const check = (ok, what) => { if (!ok) fail++; console.log(`${ok ? "ok  " : "FAIL"} ${what}`); };

const local = { provider: "llamacpp", id: "qwen3.5:4b", baseUrl: "http://127.0.0.1:8080/v1" };
const cloud = { provider: "anthropic", id: "claude-x", baseUrl: "https://api.anthropic.com" };
const lines = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => `line ${from + i}: ${"x".repeat(40)}`);
const ev = (toolName, text, input = {}, extra = {}) =>
  ({ type: "tool_result", toolName, toolCallId: "call/1", input, content: [{ type: "text", text }], isError: false, ...extra });
// The note's "offset=A limit=N" must name exactly the lines that were cut.
const named = (short) => short.match(/offset=(\d+) limit=(\d+)/).slice(1).map(Number);
const cutLines = (whole, short) => {
  const [head, tail] = short.split(/\n… \[fox-trim: [^\n]*\] …\n\n/);
  return whole.slice(head.length, whole.length - tail.length).replace(/\n$/, "").split("\n");
};

check(mod.isLocal(local) && !mod.isLocal(cloud) && !mod.isLocal(undefined), "local = a router's provider, cloud is not");
check(mod.isLocal({ provider: "mine", baseUrl: "http://localhost:9000/v1" }), "any loopback URL counts as local");

{ // bash: start + end kept, the whole output saved, the note's range is the cut
  const whole = [...lines(1, 3000), "error: the build failed here"].join("\n");
  const r = await handler(ev("bash", whole, { command: "make" }, { structuredContent: { exit_code: 2 } }), { model: local });
  const short = r?.content?.[0]?.text ?? "";
  check(short.startsWith("line 1:") && short.endsWith("error: the build failed here"), "bash: the start and the error at the end stay");
  check(/\[fox-trim: lines \d+–\d+ of 3001 cut /.test(short), "bash: the note says which lines of how many were cut");
  check(short.length < 9 * 1024, `bash: ${whole.length} chars → ${short.length}`);
  const file = short.match(/the whole output is in (\S+):/)?.[1];
  check(file && existsSync(file) && readFileSync(file, "utf8") === whole, "bash: the whole output is in the named file");
  const [off, n] = named(short);
  const saved = readFileSync(file, "utf8").split("\n");
  check(JSON.stringify(saved.slice(off - 1, off - 1 + n)) === JSON.stringify(cutLines(whole, short)),
        `bash: offset=${off} limit=${n} reads exactly the cut lines`);
  check(JSON.stringify(r.structuredContent) === JSON.stringify({ exit_code: 2 }), "bash: structuredContent passes through");
}
{ // read from offset 101: the note names the file's own lines
  const fileLines = lines(1, 4000);
  const whole = fileLines.slice(100, 2100).join("\n") + "\n\n[Showing lines 101-2100 of 4000. Use offset=2101 to continue.]";
  const r = await handler(ev("read", whole, { path: "/src/big.cpp", offset: 101 }), { model: local });
  const short = r?.content?.[0]?.text ?? "";
  check(/file lines \d+–\d+ cut .*; read \/src\/big\.cpp with offset=/.test(short), "read: the note names the file lines cut and points back at the file");
  check(short.endsWith("Use offset=2101 to continue.]"), "read: pi's own continuation note stays");
  const [off, n] = named(short);
  check(JSON.stringify(fileLines.slice(off - 1, off - 1 + n)) === JSON.stringify(cutLines(whole, short)),
        `read: offset=${off} limit=${n} are the file lines that were cut`);
}
for (const [what, e, ctx] of [
  ["a cloud model's result", ev("bash", lines(1, 3000).join("\n")), { model: cloud }],
  ["a short result", ev("bash", "ok"), { model: local }],
  ["an edit's result", ev("edit", lines(1, 3000).join("\n")), { model: local }],
  ["an image read", { ...ev("read", ""), content: [{ type: "image", data: "", mimeType: "image/png" }] }, { model: local }],
]) {
  check((await handler(e, ctx)) === undefined, `untouched: ${what}`);
}
console.log(fail ? `${fail} FAILED` : "all passed");
process.exit(fail ? 1 : 0);
