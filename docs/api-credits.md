# Monthly API credit meter

The paper notebook, the drawer's Today card / Monthly API credits page, and
both monitor bar configurations use `fox-credits` as their shared data source.
The $200 budget is for API credits from the monthly plan. It does not count
interactive subscription usage or treat its API-equivalent cost as credit spend.

No model calls are made by the meter. `status` and `bar` only read local state.
`sync` calls Anthropic's cost reporting endpoint. An hourly user timer calls
`sync-if-configured`, which exits quietly until the cycle and credential exist.

Until a renewal date and a usable data source are supplied, the display says
`API · setup`; unknown spend is never presented as zero or a full balance.

## Connect reporting

Open **System → Monthly API credits → Set up credit tracking**, or run:

```
fox-credits setup
```

Confirm the monthly credit's expiry / renewal day in Claude Console. Set the
billing timezone too; the default is UTC. A day of 29–31 clamps to the last day
of shorter months without changing the configured anchor for later months.
The meter uses midnight on that billing day as its cycle boundary.

Automatic reporting needs an Anthropic credential permitted to read organization
cost analytics. Ordinary workspace-scoped inference keys cannot read those
reports. Individual accounts may not have reporting access. Store a suitable
reporting credential in a private file (mode 600); give setup only the path.
The key is read only by the sync process, sent only to Anthropic's fixed HTTPS
endpoint, and never copied into notebook state, widget output or logs.
Redirects are refused so credentials are not forwarded to another host.

Then run `fox-credits sync`. The service retains the last successful snapshot
if a request fails. Figures show their source, freshness and cycle; the meter
is a budget calculation, not a live query of the account's credit balance.

The config is `${XDG_CONFIG_HOME:-~/.config}/foxml/api-credits.json`.
For a Trader / Claude mods breakdown, use separate API keys or workspaces for
the two workloads and put their **IDs**, not secret key strings, into each
project's `api_key_ids` or `workspace_ids` arrays. Unassigned costs remain in
`Other / unassigned` and still count toward the shared $200 allowance.
A project with no mapping says that attribution is unconfigured; it does not
claim that the project has spent nothing.

## Local tracking without account reporting access

A client can record the actual dollar cost returned for a completed API run:

```
fox-credits record --project trader --cost-usd 0.065 --id unique-request-id --at 2026-11-09T18:00:00Z
```

Use `--project plugins` for Claude mods and `--project theme` for Linux_Theme. Record a stable unique request/run ID
and the actual event timestamp; retries with the same record are idempotent.
These figures are marked **tracked only**, with `~` on the remaining estimate.
They cannot cover calls made by other clients. Reported organization totals
and local records are never added together, avoiding double-counting.

## Read-only API tasks

`fox-claude-api` runs a review-and-explain task with an ordinary inference key, read-only tools
(Read, Glob, Grep) and a per-run budget. Its projects are Trader, Claude mods and Linux_Theme;
settings live in `${XDG_CONFIG_HOME:-~/.config}/foxml/api-tasks.json` (key file, default budget,
project folders). New projects are added to an older settings file automatically.

- **Drawer → Review with API credits**: the remaining credit, one row per project, past results,
  and **Edit API task settings** (opens the settings file in Neovim).
- **Test results / Failures**: a failed job inside one of those projects gets **Explain with API
  credits**, which opens the prompt with the command, exit code and output already filled in.
- **Neovim**: `:ClaudeApi` or `Space Ca` (a visual selection is sent as an excerpt).

Before a run starts, its budget is checked against the remaining credit; a budget above it is
refused. When the remaining credit is unknown (nothing connected or tracked yet), the run is
allowed and the prompt says the amount is unknown. Each run's CLI cost estimate is recorded with
`fox-credits record --estimate`; `fox-claude-api record ID` retries a record that did not land.

## Reporting limits

The Analytics API reports costs as decimal **cents**, which the collector
converts to dollars without binary floating-point accounting. It follows all
pages and preserves fractional cents. Missing data, incomplete pagination,
conflicting attribution and invalid currency reject the snapshot.

Anthropic's data may lag up to 24 hours and be revised later. Interactive chat, Claude Code and Cowork product costs are excluded from API
credit spending. Unattributed execution charges are included conservatively;
this is one reason the figure is a budget estimate, not the actual balance.
The collector names its last completed UTC reporting hour and the API's `data_refreshed_at`.
Reports from an old credit cycle or a changed attribution config are invalidated.
The meter does not enforce a spending cap; use the Console's workspace spending
controls for that.

Sources: [Monthly plan API credits](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-ultra-and-team-plans),
[Analytics API and cost units](https://platform.claude.com/docs/en/manage-claude/usage-cost-analytics-api),
[Reporting access](https://platform.claude.com/docs/en/manage-claude/admin-api).
