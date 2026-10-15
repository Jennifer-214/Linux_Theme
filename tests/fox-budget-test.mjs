// tests/fox-budget-test.mjs — drives fox-budget's /budget with a fake pi, a fake tokenizer (one token per word) and a
// fake grade. Run via tests/test_fox_budget.py, which sets XDG_DATA_HOME / XDG_STATE_HOME / FOX_LLAMA_TOKENIZE.
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.argv[2]).href);
let fail = 0;
const check = (ok, what, extra = "") => { if (!ok) fail++; console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : "  " + extra}`); };

const handlers = {}, commands = {};
mod.default({
  on: (ev, fn) => { handlers[ev] = fn; },
  registerCommand: (name, o) => { commands[name] = o; },
  getActiveTools: () => ["read", "bash"],
  getAllTools: () => [{ name: "read", description: "read a file", parameters: {} },
                      { name: "bash", description: "run a command", parameters: {} },
                      { name: "edit", description: "never active here", parameters: {} }],
});
check(typeof commands.budget?.handler === "function", "/budget is registered");

const ctx = (model, notes) => ({
  model,
  getSystemPromptOptions: () => ({
    contextFiles: [{ path: `${process.env.HOME}/code/BRIEF.md`, content: "one two three four" }],
    skills: [{ name: "c2c", description: "find false sharing" }, { name: "hidden", description: "x", disableModelInvocation: true }],
    appendSystemPrompt: "", sections: {},
  }),
  getContextUsage: () => ({ tokens: 1234, contextWindow: 32768, percent: 4 }),
  ui: { notify: (m) => notes.push(m) },
});

{ // before any message: the parts, and a pointer to the total
  const notes = [];
  await commands.budget.handler("", ctx({ id: "qwen3.5:4b" }, notes));
  const t = notes[0] ?? "";
  check(t.includes("send one message for its total"), "no prompt yet: says how to get the total", t);
  check(/context ~\/code\/BRIEF\.md\s+4\b/.test(t), "a context file counted in the model's tokens (4 words)", t);
  check(/skills \(1\)\s+4\b/.test(t), "only the skills the model sees, counted (\"c2c: find false sharing\": 4)", t);
  check(t.includes("counted with qwen3.5:4b's own tokenizer"), "exact when the GGUF is here", t);
}
{ // after a message: pi's own share and the read time at the graded speed
  await handlers.before_agent_start({ systemPrompt: Array(100).fill("w").join(" ") });
  const notes = [];
  await commands.budget.handler("", ctx({ id: "qwen3.5:4b" }, notes));
  const t = notes[0] ?? "";
  // the fake tokenizer counts words: pi's own = the prompt's 100 − the brief's 4 − the skills' 4
  check(/pi's own instructions\s+92\b/.test(t), "pi's own share = the prompt less the parts", t);
  check(/opening prompt for qwen3\.5:4b: \d+ tokens, ~\d+ s to read at 150 tok\/s \(graded 2026-10-15\)/.test(t),
        "total with the read time at the graded speed", t);
  check(t.includes("tool definitions (2)"), "only the active tools", t);
  check(t.includes("this session so far: 1,234 of 32,768 tokens"), "the session's own use", t);
}
{ // a cloud model: estimates, said as such
  const notes = [];
  await commands.budget.handler("", ctx({ id: "claude-x", provider: "anthropic" }, notes));
  const t = notes[0] ?? "";
  check(t.includes("estimated (characters ÷ 3.6)"), "no GGUF: estimates, labelled", t);
  check(t.includes("read speed not measured yet"), "no grade: says so", t);
}
console.log(fail ? `${fail} FAILED` : "all passed");
process.exit(fail ? 1 : 0);
