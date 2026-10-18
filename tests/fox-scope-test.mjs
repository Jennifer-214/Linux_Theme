// tests/fox-scope-test.mjs — drives fox-scope's handlers with a scratch folder tree and fake events.
// Run via tests/test_fox_scope.py (skips when node is missing): argv[2] = fox-scope.ts, argv[3] = the scratch HOME,
// with HOME and PI_CODING_AGENT_DIR (= HOME/.pi/agent) set to it.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.argv[2]).href);
const H = process.argv[3];
const on = {};
mod.default({ on: (ev, fn) => { on[ev] = fn; } });
let fail = 0;
const check = (ok, what) => { if (!ok) fail++; console.log(`${ok ? "ok  " : "FAIL"} ${what}`); };
const put = (p, text = "x") => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, text); };
const file = (p) => ({ path: p, content: `the instructions in ${p}` });
// the context pi gives an EVENT handler: no getSystemPromptOptions — that is a /command's (2026-10-17: the startup
// notice called it and crashed; a fake that had it hid the bug)
const said = [];
const ctx = (hasUI) => ({ hasUI, cwd: "/", ui: { notify: (m, t) => said.push([m, t]) } });
const request = (opts, hasUI = false) =>
  on.before_agent_start({ type: "before_agent_start", messageType: "user", prompt: "hi", systemPrompt: "", systemPromptOptions: opts }, ctx(hasUI));

// the tree: two context files above a git project, the project's own, a subfolder's, and pi's global one
const agent = join(H, ".pi/agent/AGENTS.md"), top = join(H, "CLAUDE.md"), code = join(H, "code/CLAUDE.md");
const proj = join(H, "code/proj"), own = join(proj, "AGENTS.md"), sub = join(proj, "sub/AGENTS.md");
for (const p of [agent, top, code, own, sub]) put(p);
mkdirSync(join(proj, ".git"), { recursive: true });
put(join(H, "code/wt/.git"), "gitdir: /elsewhere/.git/worktrees/wt\n"); // a linked worktree: .git is a FILE
const wtOwn = join(H, "code/wt/CLAUDE.md");
put(wtOwn);
mkdirSync(join(H, "code/wt/src"), { recursive: true }); // asked from a subfolder: the fallback (the folder itself) differs
mkdirSync(join(H, "code-x/p"), { recursive: true });
mkdirSync(join(H, "loose/deep"), { recursive: true });

// ── the root ──
check(mod.projectRoot(join(proj, "sub")) === proj, "a project's root: the nearest folder holding a .git folder");
check(mod.projectRoot(join(H, "code/wt/src")) === join(H, "code/wt"), "…or a .git FILE (a linked worktree, a submodule)");
// no .git between the folder and the scratch HOME: the folder itself — unless a real one sits above the scratch tree
let above = null;
for (let d = H; ; ) { if (existsSync(join(d, ".git"))) { above = d; break; } const up = dirname(d); if (up === d) break; d = up; }
const loose = join(H, "loose/deep");
check(mod.projectRoot(loose) === (above ?? loose), `no .git: the folder pi runs in is the root (${above ? "a real .git above the tree: " + above : "none above"})`);

// ── above, never beside ──
check(mod.isAbove(join(H, "code"), proj) && mod.isAbove(H, proj), "a folder above the root is above it");
check(!mod.isAbove(proj, proj) && !mod.isAbove(join(proj, "sub"), proj), "the root itself and its subfolders are not");
check(!mod.isAbove(join(H, "code-x"), join(H, "code/p")) && !mod.isAbove(join(H, "code"), join(H, "code-x/p")),
  "a sibling that shares a name's start is not above (code vs code-x)");
check(mod.isAbove(H, join(H, "..dots/p")), "a folder named ..dots is not the parent folder (..)");

// ── before each request: the files above the root left out, the rest kept in order, nothing else touched ──
{
  const tools = ["read", "bash"];
  const opts = { cwd: join(proj, "sub"), contextFiles: [file(agent), file(top), file(code), file(own), file(sub)],
    selectedTools: tools, appendSystemPrompt: "keep me" };
  request(opts);
  const kept = opts.contextFiles.map((f) => f.path);
  check(JSON.stringify(kept) === JSON.stringify([agent, own, sub]),
    "kept: pi's global one, the project's own, its subfolder's — in pi's order: " + kept.map((p) => p.slice(H.length)).join(", "));
  check(opts.selectedTools === tools && opts.appendSystemPrompt === "keep me", "…and no other option touched");
}
{
  const opts = { cwd: join(H, "code/wt/src"), contextFiles: [file(top), file(code), file(wtOwn)] };
  request(opts);
  check(opts.contextFiles.length === 1 && opts.contextFiles[0].path === wtOwn, "a worktree keeps its own, leaves out the folders above it");
}
{
  // pi's global file applies to every project — even one kept inside pi's own agent folder, where it sits above the root
  const inAgent = join(H, ".pi/agent/proj");
  mkdirSync(join(inAgent, ".git"), { recursive: true });
  const opts = { cwd: inAgent, contextFiles: [file(agent), file(top)] };
  request(opts);
  check(opts.contextFiles.length === 1 && opts.contextFiles[0].path === agent, "pi's global file is kept even above a project (one inside pi's agent folder)");
}
{
  const opts = { cwd: H, contextFiles: [file(top)] };
  request(opts);
  check(opts.contextFiles.length === 1, "pi run in a folder with no project above: its own file is kept (~/code's CLAUDE.md, in ~/code)");
}

// ── the first request that leaves something out says so, once a session, in a line (her call 2026-10-17: not at
// session start — no event hands an extension the files pi loaded) ──
check(said.length === 0, "no UI: the requests above were filtered, nothing said");
on.session_start({ type: "session_start", reason: "startup" }, ctx(true));
{
  const opts = { cwd: join(proj, "sub"), contextFiles: [file(agent), file(top), file(code), file(own), file(sub)] };
  request(opts, true);
  check(said.length === 1 && said[0][0] === "fox-scope: left out ~/CLAUDE.md, ~/code/CLAUDE.md (above this project, ~/code/proj)"
    && said[0][1] === "info", "the first request: the notice names each file left out and the project — " + JSON.stringify(said[0]));
  check(opts.contextFiles.length === 3, "…and that request is filtered");
  request({ cwd: join(proj, "sub"), contextFiles: [file(agent), file(top), file(code), file(own), file(sub)] }, true);
  check(said.length === 1, "the next request, the same files left out: nothing said again");
  request({ cwd: join(H, "code/wt/src"), contextFiles: [file(top), file(code), file(wtOwn)] }, true);
  check(said.length === 2 && said[1][0] === "fox-scope: left out ~/CLAUDE.md, ~/code/CLAUDE.md (above this project, ~/code/wt)",
    "the same files left out of another project: said again, naming it — " + JSON.stringify(said[1]?.[0]));
  on.session_start({ type: "session_start", reason: "new" }, ctx(true));
  request({ cwd: join(H, "code/wt/src"), contextFiles: [file(top), file(code), file(wtOwn)] }, true);
  check(said.length === 3, "a new session: said again");
}
{
  said.length = 0;
  request({ cwd: proj, contextFiles: [file(agent), file(own)] }, true);
  check(said.length === 0, "nothing left out: nothing said");
}

console.log(fail ? `${fail} FAILED` : "all passed");
process.exit(fail ? 1 : 0);
