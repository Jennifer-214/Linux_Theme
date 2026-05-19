# Handoff — Architecture Refactor, mid-Phase 6

Resume point for the next session of the FoxML workstation architecture refactor. Written 2026-05-19 at the end of a long working session that shipped Phases 0-4 and Phase 6 Session A.

## Read these first, in this order

1. `CLAUDE.md` — overall conventions + native tool layout
2. `plans/architecture-refactor.md` — master plan: 19 architectural decisions (D1-D19), 25 related work items (R1-R25), phase table. TOC at the top makes the 1100+ lines navigable.
3. `plans/refactor/06-state-driven-installer.md` — the slice in progress. Session A is **done** (Steps 1-4). Session B starts at Step 5.

## What's done

| Phase | Commits | Result |
| ----- | ------- | ------ |
| 0 — master plan | 1 | `plans/architecture-refactor.md` written + gitignore exception added |
| 1 — fox-common + fox skeleton | 8 | `src/fox-common/` (ui+shell+dispatch helpers, libfox-common.a). `src/fox/` top-level dispatcher binary. `fox-install` relinked. **Note: args.{hpp,cpp} was NOT promoted** because args.hpp `#include`s context.hpp and args.cpp `#include`s module.hpp (both fox-install-specific). Args promotion is its own future slice. |
| 2 — fox ai namespace | 6 | `src/fox-ai/` dispatcher, 23 subcommands registered via dispatch.def |
| 3 — fox sec namespace | 5 | `src/fox-sec/` dispatcher, 30 subcommands. **Existing fox-sec dashboard was renamed to fox-sec-dashboard** (`shared/bin/fox-sec-dashboard`) to free up the namespace name. Reachable as `fox sec dashboard`. |
| 4 — theme/dev/sys namespaces | 4 | `src/fox-theme/` (3), `src/fox-dev/` (12), `src/fox-sys/` (8). All wired into `src/fox/dispatch.def`. |
| 6 Session A — state-driven installer foundation | 4 | `src/fox-install/core/state_manifest.{hpp,cpp}` + `classifier.{hpp,cpp}` + tests. Manifest read/write integrated into fox-install — fully additive, no behavior change yet. |

**Surface live:** `fox help` lists ai/sec/theme/dev/sys. 76 subcommands accessible as `fox <ns> <sub>`. Direct invocations (`fox-ai-doctor`, `fox-firewall`, etc.) still work unchanged.

**Test suites (9, all green):** fox-install (registry 52 modules + state_manifest 25 assertions + classifier 14 assertions), fox sanity, fox-ai sanity, fox-sec sanity, fox-theme sanity, fox-dev sanity, fox-sys sanity, fox-render, fox-vault.

## What's next — Phase 6 Session B (Steps 5-7)

**Step 5 — Extend the FOX_MODULE X-macro for prereqs.** `core/modules.def` currently declares each install module with `FOX_MODULE(name, fn, flag, desc, ...)`. Add prereq fields:

```cpp
FOX_MODULE_FULL(
    name,
    fn,
    flag,
    desc,
    /* requires_root */ true,
    /* requires_graphical */ false,
    /* requires_network */ true
)
```

Backward-compat shim: old `FOX_MODULE(...)` calls default all prereqs to `false`. The args parser, --help generator, and dispatcher should keep working unchanged. Prereqs are read by the classifier in Step 7 to produce `Status::Blocked` when not met.

**Step 6 — Write `state_check` callbacks for 3-5 representative modules.** Each module gets an optional `check_X_state(ctx)` returning a `Classification` (per `core/classifier.hpp`). Suggested starting modules:

- `deps` (pacman package install — check `pacman -Qi <pkg>` for each tracked package)
- `render` (file deployment — compare hash of rendered output vs stored)
- `etckeeper` (systemd unit — check `systemctl is-enabled`, watch for masked state per R6/R5)

Modules without a callback default to `Status::Fresh` (current behavior).

**Step 7 — Three-hash conflict diff helper + interactive prompt.** When a module classifies as `Conflict`, prompt the user via `fox-common/ui.hpp` (NOT ftxui yet — that's Session C). Options: keep mine / take new / save as `.foxml-bak` then take new / view diff (use `diff -u` subprocess).

## Quality bars (per D19)

- Build clean under `-Wall -Wextra -Wpedantic` (no exceptions, no warnings)
- All existing tests must stay green — run `make test` from repo root before each commit
- One commit per logical step, descriptive messages, include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- No raw `new`/`delete`, RAII everywhere, `std::optional<T>` over nullable pointers
- Atomic file writes (tmp + rename — pattern already used in `state_manifest.cpp`)
- Subprocess via `sh::run`/`sh::capture` only, never raw `system()`/`popen()`

## Load-bearing context

- **Mid-refactor state.** `install.sh` is still a thin bash wrapper that builds fox-install + execs it. The state-driven installer rewrite (Phase 6) eventually replaces this — but Phase 6 is multi-session, so for now the OLD install path still works and is the active one. The state manifest plumbing is non-gated additive code.
- **Leaf binaries not renamed.** Per D4 (language-agnostic leaves), `fox-ai-doctor`, `fox-firewall`, etc. keep their existing names. The dispatcher just `execvp`s to them. No mass rename in this refactor.
- **gitignore exceptions.** `plans/architecture-refactor.md` AND `plans/refactor/**` are explicitly excepted from `plans/*` in `.gitignore`. Other plan files in `plans/` (e.g., `fox-intel-modernization.md`) stay local-only per existing convention.
- **C++ build dependency chain.** Each namespace dispatcher's Makefile links `../fox-common/libfox-common.a`. The fox-install Makefile also links `-lcrypto` (OpenSSL, for SHA256 in state_manifest).
- **JSON dependency.** Use the vendored `src/fox-intel/json.hpp` (nlohmann/json 3.12.0). Don't add a new JSON dep.
- **Caramel push-back pattern.** In the prior session, Caramel pushed past several explicit "this is a good stopping point" recommendations to ship more. The Phase 6 subplan has an explicit "Hard cap at end of Session A scope" line for exactly this reason. **For Session B specifically: Steps 6 and 7 involve real design judgment (per-module state semantics, user-facing prompts). If Caramel wants to push past those at 2am, respect engineering judgment over enthusiasm — those are the parts that get rewritten the next day.**

## Reference: what was tonight's session shape

- Started ~6pm, ended ~2am
- 33 commits across 7 phases
- All commits are atomic (per-step), reviewable, and reversible
- Each phase had its own subplan in `plans/refactor/0N-<slice>.md`
- Pattern is established: namespace dispatcher = `src/fox-X/{Makefile, main.cpp, dispatch.def, tests/dispatch_test.sh}`. Use `src/fox-ai/` as the canonical template.

## Start by

```bash
cd /home/caramel/code/Linux_Theme
git log --oneline c33e27c..HEAD     # see what was shipped
cat plans/architecture-refactor.md  # TOC at top, scan structure
cat plans/refactor/06-state-driven-installer.md  # Phase 6 detail
```

Then begin Phase 6 Step 5 (FOX_MODULE_FULL X-macro extension).
