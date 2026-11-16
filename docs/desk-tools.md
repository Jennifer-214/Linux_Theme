# Declared tools

A project can give desk-work tools of its own: a graph, findings, figures or a status. desk-work reads what they
answer, runs a declared command only when you ask at a terminal, and hands every answer to Neovim, the notebook and
the drawer in one shape, `desk-result/1`. With nothing declared, nothing changes.

```sh
desk-work tools list [--root DIR]     # this checkout's tools, from both places, with when each last answered
desk-work tools show ID               # one entry: its command, whether you said yes to it, its last answer
desk-work tools run ID                # at a terminal: asks the first time, then runs it as a job
desk-work tools result ID             # its answer as desk-result/1 (reads files only)
```

## Where declarations live

One format, in one of two places.

| Place | For |
| --- | --- |
| `.desk/tools.json` at the top of a checkout, beside `.desk/metrics` | the project's own tools, kept in the project |
| `${XDG_CONFIG_HOME:-~/.config}/foxml/desk.d/<name>.json`, with a `root` | a repo that must not change, or a path that must stay private |

A desk.d file names the checkout its tools are for in `root`, an absolute path; a folder inside a checkout counts as
that checkout, and the file's commands run in that folder. A project file's commands run at the checkout's top level.
`tools list` shows both places' tools for the checkout it runs in. A desk.d file that cannot be read names no
checkout, so it is listed in every one.

Work health reads every desk.d file, and `.desk/tools.json` in each checkout desk-work keeps records of (one where a
job, a review or an agent was recorded).

## The format

```json
{ "version": 1,
  "tools": [
    { "id": "dag", "name": "Pipeline DAG", "gives": "graph", "format": "json",
      "argv": ["python3", "-B", "tools/dag.py", "--json"], "timeout_ms": 5000 } ] }
```

| Field | Where | What |
| --- | --- | --- |
| `version` | file | `1` |
| `root` | file, desk.d only | the checkout the tools are for, absolute |
| `written_by` | file, optional | who wrote it (a tool declaring itself); shown |
| `tools` | file | at most 64 |
| `id` | tool | 1 to 48 letters, digits, `-` and `_`; one per checkout |
| `name` | tool, optional | shown; the id when absent |
| `gives` | tool | `graph`, `findings`, `figures` or `status` (Kinds) |
| `format` | tool | `json`, `toolio`, `fox-symdeps/2`, `lines`, `dot` or `fox-contract/1` (Formats) |
| `argv` | tool | the command, one string per argument; no shell |
| `reads` | tool | the absolute path of a file the tool writes; desk-work only reads it. In a project's own file it must be in the checkout (no `..`, symbolic links resolved); a desk.d file may name any path |
| `timeout_ms` | tool, optional | 100 to 3600000; the run is stopped after it |
| `when` | tool, optional | `ask`, the default. `save` and `run` are accepted but not built yet: such a tool runs when you ask |

A tool has `argv`, `reads`, or both: it runs, and writes its answer to `reads`. Fields desk-work does not read are
ignored.

These are refused, with the reason in `tools list` and `tools show`, and a work health check "Tool declarations · N
refused":

- a file that is not JSON, has another version, is over 64 KiB or is a symlink; a desk.d file whose `root` is not
  an absolute path to a folder;
- a tool with a bad id, kind or format, a format that does not give its kind, an `argv` that is not a list of
  strings, a `reads` that is not absolute, or neither `argv` nor `reads`;
- in a project's own `.desk/tools.json`, which arrives with the repo, a `reads` outside the checkout: an absolute path
  elsewhere, one with `..`, or one a symbolic link leads out of;
- an `id` declared twice for one checkout, in one file or in two. Both are refused, "declared twice: A and B";
  desk-work never picks one.

## Kinds

| `gives` | The answer | Where it shows today |
| --- | --- | --- |
| `status` | a state, `ok` `warn` `fail` or `unknown`, and a short line | `tools result`; a contract-test record is work health's toolchain card |
| `findings` | places in files, with a severity and a message | `tools result` |
| `figures` | named numbers with units | `tools result`; a run's figures are set against its previous run (`desk-work metrics`, the notebook's project page) |
| `graph` | nodes and edges | `tools result` |

Drawing declared graphs and findings in Neovim and the pop-out comes later.

## Formats

Which kinds each format can give:

| Format | Kinds |
| --- | --- |
| `json` | all four, in the shapes below |
| `toolio`, `fox-symdeps/2` | all four |
| `lines` | status, findings, figures |
| `dot` | graph |
| `fox-contract/1` | status |

A run's answer is what it printed on stdout; `lines` reads everything it printed, stdout and stderr, since compilers
print diagnostics on stderr. A file named in `reads` is read as it is.

### json

- graph: `{ "version": 1, "nodes": [{ "id", "label", "file", "line", "kind", "detail", "metrics" }], "edges": [{ "from",
  "to", "kind", "label" }], "focus", "complete", "why" }`. Ids are unique, and stable across runs where the tool can
  make them so. `file` is relative to the checkout (an absolute path inside it is made relative) or null, `line` is
  1-based, `kind` one word (function, type, file, module, task, commit). A graph is whole only when it says
  `"complete": true`. Over 5000 nodes or 20000 edges is refused: ask the tool for the part around one node.
- findings: `[{ "file", "line", "col", "severity", "message", "kind" }]`, severity `error`, `warn` or `info`
  (`warning` and `note` read as those).
- figures: `[{ "name", "value", "unit" }]`, in the units desk-work reads a job's printed numbers in
  ([agent-workflows.md](agent-workflows.md), "Run-to-run numbers"). A figure in another unit stays in the answer but
  is not compared run to run.
- status: `{ "state": "ok", "text": "at most 40 characters" }`.

A script printing JSON, `tools/count.py`:

```python
#!/usr/bin/env python3
import json, subprocess
files = subprocess.run(["git", "ls-files", "*.py"], capture_output=True, text=True).stdout.split()
lines = sum(1 for f in files for _ in open(f, encoding="utf-8", errors="replace"))
print(json.dumps([{"name": "python files", "value": len(files), "unit": ""},
                  {"name": "python lines", "value": lines, "unit": ""}]))
```

```json
{ "id": "size", "gives": "figures", "format": "json", "argv": ["python3", "-B", "tools/count.py"] }
```

### dot

`ninja -t graph` (a Ninja build folder; CMake: `cmake -G Ninja`):

```json
{ "id": "build", "name": "Build graph", "gives": "graph", "format": "dot",
  "argv": ["ninja", "-C", "build", "-t", "graph"] }
```

Read: node and edge statements, attribute lists, subgraphs (flattened: `a -> { b c }` is two edges) and comments;
ports are dropped. A node's `label` is its label; `kind`, `file`, `line` and `tooltip` (as its detail) are read when a
writer adds them. DOT cannot say a graph is whole, so `complete` is null.

### toolio and fox-symdeps/2

The envelope as it is:

```json
{ "envelope_version": "1.0", "kind": "findings",
  "producer": { "tool": "long-lines", "version": "1", "command": "long_lines.py" },
  "status": { "ok": false, "code": 1, "findings": [["src/a.py", 12, "warn", "131 characters", "layout"]] },
  "target": { "paths": ["."], "git_head": "<sha>" },
  "payload": { "timing": { "schema": ["name", "value", "unit"], "rows": [["p99", 412, "ns"]] } } }
```

- findings: the rows of `status.findings`, `[file, line, severity, message, kind]`. A row whose severity is `refused`
  is a refusal; its message says why.
- status: `status.code` 0 is ok, 1 warn (answered with findings), 2 refused; without a code, `status.ok`.
- figures: every payload table with `name` and `value` columns, `unit` optional.
- graph: the payload tables `nodes` and `edges`, by column name (the json graph's fields).
- `producer` becomes the answer's `source.producer`, `target.git_head` its `about`.

A run that exits 1 answered with findings, so its job counts as passed; 2 and above failed. symdeps' door speaks the
same envelope as `fox-symdeps/2`.

A toolio emitter, `tools/long_lines.py`:

```python
#!/usr/bin/env python3
import json, subprocess, sys
rows = []
for path in subprocess.run(["git", "ls-files", "*.py"], capture_output=True, text=True).stdout.split():
    for n, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        if len(line.rstrip("\n")) > 120:
            rows.append([path, n, "warn", f"{len(line.rstrip())} characters", "layout"])
print(json.dumps({"envelope_version": "1.0", "kind": "findings", "producer": {"tool": "long-lines", "version": "1"},
                  "status": {"ok": not rows, "code": 1 if rows else 0, "findings": rows},
                  "target": {"paths": ["."]}, "payload": {}}))
sys.exit(1 if rows else 0)
```

```json
{ "id": "long-lines", "gives": "findings", "format": "toolio", "argv": ["python3", "-B", "tools/long_lines.py"] }
```

### lines

- status: the last line that is not empty. A leading `ok`, `warn`, `fail` or `unknown` (then `:` or a space) is the
  state and the rest its text; otherwise the run's exit status decides (0 ok, anything else fail), and a file that was
  read is unknown.
- findings: `file:line[:col]: message` lines, as compilers print them; `error:`, `warning:`, `note:` or `fatal error:`
  before the message sets the severity, and without one it is unknown. Other lines are skipped.
- figures: the strict reading desk-work gives a job's printed numbers (`name value unit`, `name: value unit`,
  `name=value unit`; a line holding anything else is no figure).

Two entries for a `tools` list: a compiler's warnings, and a status from a shell test (a declared `sh -c` is your
own shell command; desk-work adds none):

```json
[ { "id": "warnings", "gives": "findings", "format": "lines", "argv": ["gcc", "-fsyntax-only", "-Wall", "src/main.c"] },
  { "id": "built", "gives": "status", "format": "lines",
    "argv": ["sh", "-c", "test build/app -nt src/main.c && echo ok built || echo warn sources are newer than the build"] } ]
```

### fox-contract/1

The record a contract-test runner writes (symdeps' runner writes one after a full run of its contract tests): when
it ran, its outcome (`pass`, `fail`, `partial` or `refused`), the counts against the expected number, the failed,
skipped and missing tests, the checkouts it ran against at its start and end (folder, commit, the tree id of a
tested folder, whether it was uncommitted and which paths), which of those moved during the run, and the path of its
log. desk-work reads it through one table of field names (`contract_fields` in `src/desk-work/results.hpp`). A
skipped or missing test is never a pass: such a run reads `partial`. Nor is a record that contradicts itself: one that
says `pass` while it lists a failed test reads `failed`, one whose counts account for fewer tests than it expected
reads `partial`, and a finding of kind `inconsistent` says why. It is declared as a status tool that `reads` the
record; see the card below.

## Running a tool

- `desk-work tools run ID` starts a declared command only at a terminal (stdin and stdout) and never from Claude
  Code's own shell. An agent is refused and pointed at `tools result`. `tools list`, `show` and `result`, and work
  health, read files and git and run nothing a declaration names.
- The first run of an entry, and the first after its command changed, shows the exact command and its folder and
  asks `Run it? [y/N]`. Your yes is kept per tool in the checkout's records (`tool-approvals.json`), pinned to a hash
  of the command, its folder and its timeout: an edited entry asks again, so editing a declaration cannot get a
  command run. Each argument is shown in single quotes; one holding a character a terminal acts on (a control
  character, DEL, a bidi override) is shown as `$'…'` with that character escaped, and so are the tool's name and
  paths, so the command you read is the one that runs.
- It runs as a desk-work job: its output log (the newest 4 MiB), a notice when it fails, the job in the notebook. A
  tool run is never a test run. A Python tool runs with `PYTHONDONTWRITEBYTECODE=1`, so it leaves no bytecode in the
  project. Its stdin is `/dev/null`: a declared tool reads nothing from your terminal.
- `timeout_ms` stops it (`timeout`, with a kill two seconds later).
- A run stopped before it finished (Ctrl-C, a signal) says it gave no answer; `tools result` still reads the last run
  that finished.
- A program that is not installed is listed with `requires`, and `tools run` says "requires PROGRAM" and runs nothing.

## Reading an answer

`desk-work tools result ID` prints the tool's answer as desk-result/1: the file in `reads`, else the newest finished
run's answer in this checkout. Without an answer yet it says so: `{ "ok": false, "message": "No answer yet: …" }`.

```json
{ "format": "desk-result/1", "gives": "status",
  "source": { "kind": "tool", "id": "contract", "name": "symdeps contract tests",
              "producer": { "tool": "fox-symdeps", "version": null, "command": null } },
  "read": { "format": "fox-contract/1", "from": "/path/to/the/record.json", "ok": true },
  "at": 1794812098, "summary": "12 passed, 0 failed",
  "complete": true, "why": null, "state": "ok",
  "findings": [], "facts": [{ "name": "passed", "value": 12, "unit": "" }],
  "about": [{ "kind": "checkout", "name": "workspace", "label": "workspace 1.2.0", "path": "/path/to/workspace",
              "scope": "tools", "how": "WORKSPACE_DIR",
              "version": { "head": "…", "tree": "…", "release": "1.2.0", "dirty": false, "uncommitted": [] } }],
  "log": "/path/to/the/run.log", "started": 1794812098 }
```

This is what desk-work gives for the sample record its tests read (`src/desk-work/tests/fixtures/fox-contract.json`),
shortened to one of its three checkouts.

- `state` is there for a status, `graph` (`nodes`, `edges`, `focus`) for a graph, `log` and `started` for a contract
  record. `read.exit` is the run's exit status when the answer came from a run.
- `complete` false, with `why`: the tool refused (`refused: …`), or desk-work could not read what it wrote
  (`read.ok` false). Null: the format cannot say (DOT, a json graph without `complete`).
- findings are `{ id, file, line, col, severity, kind, message }`, facts `{ name, value, unit }`.
- A value the tool did not give is null, read as unknown; nothing is guessed.

## The toolchain card

Work health (the drawer's Work health page, the notebook's health page, `:WorkHealth`) shows one check per
contract-test record a tool declares, a status tool in `fox-contract/1`. symdeps declares its own:

```json
{ "version": 1, "written_by": "fox-symdeps", "root": "/path/to/fox-symdeps.nvim",
  "tools": [ { "id": "contract", "name": "symdeps contract tests", "gives": "status",
               "reads": "/path/to/fox-symdeps.nvim/.git/fox-contract.json", "format": "fox-contract/1" } ] }
```

The check reads `Contract tests · NAME · STATE`, then `· STALE` or `· unverified` when that applies. STATE is
`passed`, `passed with N uncommitted files` (the run tested files in the tools folder that were not committed: no
clean pass), `failed`, `partial` (something skipped or did not run), `refused`, `unreadable` (the record cannot be
read) or `not recorded yet` (no record at `reads`). Its lines: the outcome with its time, age and counts; the
runner's own summary line; where the record contradicts itself, why (`Inconsistent: the record says pass, but …`);
the failed, skipped and missing tests by name; what it ran against (each checkout's
commit, the tools version and tree id) and which uncommitted files it ran with; whether that is still what is there,
and why not; what is not compared; the log's path; where the record and its declarations are.

A directory in an uncommitted list that holds its own `.git` is a nested repository (a worktree or a clone kept
inside the folder), not the folder's content: it is counted apart ("N nested repositories not counted") and never
compared.

Stale, by the tested folder alone (the tools tree the record names), with the reason shown:

- "tools committed since the run": its tree id now (`git rev-parse HEAD:tools` in the folder the record names)
  differs from the record's;
- "uncommitted files in … changed since the run": `git status --porcelain -- tools/` there lists a file the record did
  not have, or no longer lists one it had, or one of those files (for a folder, any file in it git does not ignore:
  a cache written there after the run is no change) was changed after the run ended (`ended_epoch`; a change within
  that last second counts as after).

Inputs that moved during the run (`moved`) read unverified, and are named. The other checkouts' commits are shown,
not compared, and neither are gitignored files or the machine's tools.

Viewing the card runs no test: it reads the declarations and the record, the times of the uncommitted files, and runs
`git rev-parse` and `git status` (no optional locks, no fsmonitor, three seconds each). The runner writes the record;
desk-work keeps no copy. A check that is not a pass, or is stale, adds an alert, so the drawer no longer says
everything is in order.

## With nothing declared, or a tool missing

- Nothing declared: `tools list` lists nothing, work health says "Contract tests · none declared", and every other
  feature works as before.
- symdeps not installed: there is no contract declaration, so the card says none declared. Nothing in the theme
  requires symdeps.
- A declared program that is not installed: "requires PROGRAM" (Running a tool).
- A tool that has not written its `reads` file yet: "No answer yet", and on the card "not recorded yet".
