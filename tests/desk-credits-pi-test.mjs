// tests/desk-credits-pi-test.mjs — drives the desk-credits pi extension with a fake pi and a fake desk-credits.
// Run via tests/test_pi_credits.py, which sets FOX_CREDITS_BIN and the audit file.
import { readFileSync, existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.argv[2]).href);
let fail = 0;
const check = (ok, what, extra = "") => { if (!ok) fail++; console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : "  " + extra}`); };

const reply = (over = {}) => ({ role: "assistant", provider: "anthropic", model: "claude-sonnet-5-5", responseId: "msg_01abc",
  usage: { input: 1000, output: 200, cacheRead: 50, cacheWrite: 0, totalTokens: 1250,
           cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.0123 } }, ...over });
const at = new Date("2026-11-09T18:00:00Z");
const args = mod.recordArgs(reply(), "theme", at, () => "fallback");
check(JSON.stringify(args.slice(0, 9)) === JSON.stringify(["record", "--project", "theme", "--cost-usd", "0.012300",
  "--id", "pi-msg_01abc", "--at", "2026-11-09T18:00:00.000Z"]), "a reply becomes one record", JSON.stringify(args));
const details = JSON.parse(args[args.length - 1]);
check(details.model === "claude-sonnet-5-5" && details.input_tokens === 1000 && details.cache_read_tokens === 50
  && details.source === "pi", "model and tokens go along", JSON.stringify(details));
check(mod.recordArgs(reply({ provider: "llamacpp" }), "theme", at, () => "x") === undefined, "a local model is never counted");
check(mod.recordArgs(reply({ role: "user" }), "theme", at, () => "x") === undefined, "only assistant replies");
check(mod.recordArgs(reply({ usage: { cost: { total: NaN } } }), "theme", at, () => "x") === undefined, "no cost, no record");
check(mod.recordArgs(reply(), "../x", at, () => "x")[2] === "other", "unknown project falls back to other");
check(mod.recordArgs(reply({ responseId: "bad id!" }), "theme", at, () => "fb")[6] === "pi-fb", "unsafe IDs are replaced");

// Not started by claude-api pi: nothing registers.
const off = {};
delete process.env.FOXML_API_CREDITS;
mod.default({ on: (ev, fn) => { off[ev] = fn; } });
check(Object.keys(off).length === 0, "without FOXML_API_CREDITS the extension stays off");

process.env.FOXML_API_CREDITS = "1";
process.env.FOXML_API_PROJECT = "plugins";
const handlers = {}, statuses = [], notes = [];
mod.default({ on: (ev, fn) => { handlers[ev] = fn; } });
const ctx = { ui: { setStatus: (k, t) => statuses.push([k, t]), notify: (m) => notes.push(m) } };
await handlers.session_start({}, ctx);
await handlers.message_end({ message: reply() }, ctx);
await handlers.message_end({ message: reply({ provider: "openai" }) }, ctx);
const audit = process.env.TEST_AUDIT;
const calls = existsSync(audit) ? readFileSync(audit, "utf8").trim().split("\n").map((l) => l.split(" ")[0]) : [];
check(JSON.stringify(calls) === JSON.stringify(["status", "record", "status"]), "records once and refreshes the footer", JSON.stringify(calls));
check(statuses.length === 2 && statuses[0][0] === "desk-credits" && statuses[0][1] === "API ~$199.99 left", "footer shows what is left", JSON.stringify(statuses));
check(notes.length === 0, "no warning when the record lands", JSON.stringify(notes));

console.log(fail ? `${fail} failed` : "all passed");
process.exit(fail ? 1 : 0);
