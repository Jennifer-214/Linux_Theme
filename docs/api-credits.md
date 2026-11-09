# API tasks and usage

`fox-claude-api` runs read-only Claude reviews of your projects on an ordinary inference API key, and can open
pi with the same key. `fox-credits` keeps the monthly meter: the main screen's bar, the drawer's Today card
and **API usage** page read it, and the paper notebook shows it only once 20% or less is left. Amounts read in
cents, and a run under a cent reads `<$0.01`.

## What the meter counts

The meter is the monthly budget minus the runs these tools record:

- every `fox-claude-api` task (the Claude CLI reports each run's cost, tokens and model), and
- every Anthropic reply in a pi session opened with **Open pi with API credits** (`fox-claude-api pi`).

Calls made with the key anywhere else are **not** counted, and every place the number appears says "tracked".
Costs are client-side estimates; Claude Console shows the account's real balance. Reading account-wide
spending needs an Admin key, which individual accounts cannot create, so the meter never contacts the network.

Set the renewal day, timezone and monthly amount with **API usage → Renewal day and budget**, or:

```
fox-credits setup
fox-credits configure --renewal-day 1 --timezone America/Chicago --budget 200
```

Until a renewal day is set the meter shows `API · setup`; afterwards it reads `API ~$X left` from day one.
`fox-credits usage` prints this month by project, by model and by day, plus the costliest runs; the drawer's
**API usage** page shows the same. The run ledger is `~/.local/state/foxml/api-credits/tracked.json`.

## Tasks

Settings: `${XDG_CONFIG_HOME:-~/.config}/foxml/api-tasks.json` — key file (mode 600), default model, effort,
fallback model, default run budget and the project folders (Trader, Claude mods, Linux_Theme).
**Edit API task settings** opens it in Neovim; `fox-claude-api configure --model claude-opus-5-5` works too.

- **Drawer → Review with API credits**: per project, *Ask*, *Review uncommitted changes* and *Open pi with
  API credits*; past results open in Neovim, each with *Follow up*.
- **Test results / Failures**: a failed job in one of those projects gets *Explain with API credits*, with
  the command, exit code and output filled in.
- **Neovim**: `:ClaudeApi` / `Space Ca` (a visual selection is sent as an excerpt), `:ClaudeApiReview` /
  `Space CR`, `:ClaudeApiStop`. Each asks for the model and run budget; progress shows as it reads files.
  The answer opens in a tab: its `path:line` citations are in the quickfix list (`:copen`), Enter on a line
  opens the cited spot, `f` asks a follow-up, `q` closes.

Each task:

- uses only Read, Glob and Grep, with no MCP servers, no hooks and no saved session;
- cannot read `.env*`, `*.key`, `*.pem`, `secrets/`, SSH/GPG keys, the password store or the API key folder —
  these are permission deny rules, not only an instruction;
- stops at its run budget, and is refused before it starts when the budget is more than the tracked credit
  left this month;
- is saved privately under `~/.local/state/foxml/api-tasks/` (mode 600, the key redacted);
- sends a notification with its cost when it took over 30 seconds (Open shows the answer).

A follow-up sends the earlier question and answer as context. *Review uncommitted changes* sends
`git diff HEAD` (cut at 24 KB) and the names of new files.

## pi with API credits

`fox-claude-api pi --project theme [--model claude-sonnet-5-5]` opens pi in that project with the key in its
environment only, `--provider anthropic`, and `FOXML_API_CREDITS=1`. pi's `fox-credits` extension then records
each reply (pi's catalog-price estimate) and shows what is left in pi's footer. Unlike tasks, pi can edit
files. A pi started any other way — a local model, or a subscription login — is never counted.
