// tests/fox-notify-test.mjs — drives fox-notify's handlers with a fake pi: every notice it would send, by argv.
// Run via tests/test_fox_notify.py (skips when node is missing). Small delays keep it well under a second.
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.argv[2]).href);
let fail = 0;
const check = (ok, what) => { if (!ok) fail++; console.log(`${ok ? "ok  " : "FAIL"} ${what}`); };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const DELAY = 40, HINT = 100;
// A fresh pi for each case: its handlers, its event bus, and every notify-send argv it was asked to run.
function boot(opts = {}) {
  const on = {}, bus = {}, sent = [];
  const pi = {
    on: (ev, fn) => { (on[ev] ||= []).push(fn); },
    events: { on: (ch, fn) => { (bus[ch] ||= []).push(fn); return () => {}; }, emit: (ch, d) => (bus[ch] || []).forEach((f) => f(d)) },
    exec: async (cmd, args) => { sent.push([cmd, ...args]); return { code: 0, stdout: "", stderr: "" }; },
  };
  mod.makeNotify({ delayMs: DELAY, minSecs: 0, hintMs: HINT, ...opts })(pi);
  // a session object that throws when read, as pi's stale one does in print mode after the run
  const stale = new Proxy({}, { get: () => { throw new Error("This extension ctx is stale"); } });
  const fire = async (ev, event = {}, ctx = stale) => { for (const f of on[ev] || []) await f({ type: ev, ...event }, ctx); };
  const live = (mode = "tui", cwd = "/home/u/code/Linux_Theme") => ({ hasUI: mode === "tui" || mode === "rpc", mode, cwd });
  return { pi, sent, fire, live };
}
const run = async (b, outcome, aborted = false, ctx) => {
  await b.fire("agent_start", {}, ctx ?? b.live());
  await b.fire("agent_before_settle", { outcome });
  await b.fire("agent_settled", { aborted });
};
const argvText = (sent) => JSON.stringify(sent);

{ // done: a long run pings once, on the normal lane, with the project
  const b = boot();
  await run(b, "completed");
  check(b.sent.length === 1, "a settled run pings once");
  const a = b.sent[0] || [];
  check(a[0] === "notify-send" && a[1] === "-a" && a[2] === "pi", "notify-send -a pi");
  check(!a.includes("-u"), "done is on the normal lane (no -u critical)");
  check(a.at(-2) === "🦊 pi is ready" && /^📁 Linux_Theme · \d+s$/.test(a.at(-1)), `done: ${JSON.stringify(a.slice(-2))}`);
}
{ // a retry: agent_end twice, settled once → one ping (agent_end is not listened to)
  const b = boot();
  await b.fire("agent_start", {}, b.live());
  await b.fire("agent_end"); await b.fire("agent_end");
  await b.fire("agent_before_settle", { outcome: "completed" });
  await b.fire("agent_settled", { aborted: false });
  check(b.sent.length === 1, `a retried run pings once (${b.sent.length})`);
}
{ // a short run: nothing
  const b = boot({ minSecs: 3600 });
  await run(b, "completed");
  check(b.sent.length === 0, "a quick reply pings nothing");
}
{ // an error: a ping whatever the length
  const b = boot({ minSecs: 3600 });
  await run(b, "error");
  check(b.sent.length === 1 && b.sent[0].at(-2) === "🦊 pi stopped on an error" && b.sent[0].at(-1) === "📁 Linux_Theme",
        `an error pings at any length: ${argvText(b.sent)}`);
}
{ // Escape: nothing, by either signal
  const b = boot();
  await run(b, "aborted", true);
  await run(b, "completed", true);
  await run(b, "aborted", false);
  check(b.sent.length === 0, "a run she stopped pings nothing");
}
for (const mode of ["print", "rpc", "json"]) { // only the terminal UI
  const b = boot();
  await b.fire("session_start", {}, b.live(mode));
  await run(b, "completed", false, b.live(mode));
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await sleep(DELAY * 3);
  check(b.sent.length === 0, `${mode} mode: no notice at all`);
}
{ // a dialog open past the delay: one critical ping, once
  const b = boot();
  await b.fire("session_start", {}, b.live());
  await b.fire("ui_prompt_start", { kind: "confirm", title: "Allow: rm -rf ~/secret --token=hunter2?" });
  await sleep(DELAY * 3);
  check(b.sent.length === 1, `a dialog left open pings once (${b.sent.length})`);
  const a = b.sent[0] || [];
  check(a.includes("-u") && a[a.indexOf("-u") + 1] === "critical", "a dialog notice is critical");
  check(a.at(-2) === "🦊 pi needs your yes" && a.at(-1) === "📁 Linux_Theme", `needs your yes: ${JSON.stringify(a.slice(-2))}`);
  check(!/rm -rf|secret|hunter2|Allow/.test(argvText(b.sent)), "the dialog's title never reaches the notice");
  await b.fire("ui_prompt_end", { kind: "confirm" });
}
{ // answered in time: nothing
  const b = boot();
  await b.fire("session_start", {}, b.live());
  await b.fire("ui_prompt_start", { kind: "select" });
  await sleep(DELAY / 4);
  await b.fire("ui_prompt_end", { kind: "select" });
  await sleep(DELAY * 3);
  check(b.sent.length === 0, "a dialog answered within the delay pings nothing");
}
{ // a second start while armed (pi merges nesting, so this is defence): still one ping
  const b = boot();
  await b.fire("session_start", {}, b.live());
  await b.fire("ui_prompt_start", { kind: "select" });
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await sleep(DELAY * 3);
  check(b.sent.length === 1, `two starts, one ping (${b.sent.length})`);
}
for (const kind of ["input", "editor", "custom"]) { // typing kinds: she is already typing
  const b = boot();
  await b.fire("session_start", {}, b.live());
  await b.fire("ui_prompt_start", { kind });
  await sleep(DELAY * 3);
  check(b.sent.length === 0, `a ${kind} dialog pings nothing`);
}
{ // the plan gate's hint: the next dialog says "needs approval"
  const b = boot();
  await b.fire("session_start", {}, b.live());
  b.pi.events.emit("fox:approval", {});
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await sleep(DELAY * 3);
  check(b.sent.length === 1 && b.sent[0].at(-2) === "🦊 pi needs approval", `the hint: ${argvText(b.sent)}`);
  await b.fire("ui_prompt_end", { kind: "confirm" });
  b.sent.length = 0; // …and only that one: the next dialog is "needs your yes"
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await sleep(DELAY * 3);
  check(b.sent.length === 1 && b.sent[0].at(-2) === "🦊 pi needs your yes", `a hint is used once: ${argvText(b.sent)}`);
}
{ // a stale hint (older than hintMs) is ignored
  const b = boot();
  await b.fire("session_start", {}, b.live());
  b.pi.events.emit("fox:approval", {});
  await sleep(HINT * 2);
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await sleep(DELAY * 3);
  check(b.sent.length === 1 && b.sent[0].at(-2) === "🦊 pi needs your yes", `a stale hint is ignored: ${argvText(b.sent)}`);
}
{ // a hint consumed by a typing dialog does not carry to the next yes/no
  const b = boot();
  await b.fire("session_start", {}, b.live());
  b.pi.events.emit("fox:approval", {});
  await b.fire("ui_prompt_start", { kind: "input" });
  await b.fire("ui_prompt_end", { kind: "input" });
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await sleep(DELAY * 3);
  check(b.sent.length === 1 && b.sent[0].at(-2) === "🦊 pi needs your yes", `a hint is the next dialog's only: ${argvText(b.sent)}`);
}
{ // shutdown during a dialog: the timer is cleared, nothing fires later
  const b = boot();
  await b.fire("session_start", {}, b.live());
  await b.fire("ui_prompt_start", { kind: "confirm" });
  await b.fire("session_shutdown", { reason: "reload" });
  await sleep(DELAY * 3);
  check(b.sent.length === 0, "a shutdown during a dialog cancels its ping");
}
{ // a project whose name starts with "-": every argv string after the flags starts with an emoji
  const b = boot();
  await run(b, "error", false, b.live("tui", "/home/u/-x"));
  const a = b.sent[0] || [];
  check(a.at(-2).startsWith("🦊") && a.at(-1).startsWith("📁 -x"), `no argv string after the flags starts with "-": ${JSON.stringify(a.slice(-2))}`);
}
{ // notify-send missing: no throw out of a handler
  const b = boot();
  b.pi.exec = async () => { throw new Error("spawn notify-send ENOENT"); };
  let threw = false;
  try { await run(b, "error"); } catch { threw = true; }
  check(!threw, "a missing notify-send never throws into pi");
}

console.log(fail ? `${fail} failure(s)` : "all checks passed");
process.exit(fail ? 1 : 0);
