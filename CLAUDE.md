# Linux_Theme — Development Guide

Project-specific guidance for working on the opinionated Arch + Hyprland + local-AI workstation. Loaded automatically when `claude` runs from this directory.

## What this repo is

A theme + tools + installer for an opinionated Arch Linux + Hyprland + local-AI workstation. Currently mid-migration from a 2400-line `install.sh` to a modular C++ orchestrator (`fox-install`) plus a constellation of native tools under `src/fox-*/`.

## Native tool layout

Every C++ component lives in its own `src/<tool>/` directory with its own `Makefile` exposing `all`, `install`, `clean`, optional `test`. The root `Makefile` auto-discovers every subdir — adding a new tool requires zero root-Makefile edits.

Current tools:

| Tool              | Role                                                                |
| ----------------- | ------------------------------------------------------------------- |
| `fox-common`      | Library (`libfox-common.a`) — shared pacman-style UI, subprocess helpers (`sh::run`/`pacman`/`systemctl_*`), and the namespace dispatcher (`fox_common::dispatch`). Every fox-* tool that needs these links against it. |
| `fox`             | Top-level CLI dispatcher. Entry for `fox <namespace> <subcommand> [args]`. Namespaces live in `src/fox/dispatch.def`. As of Phase 2: `ai` namespace wired in. |
| `fox-ai`          | Namespace dispatcher for AI-augmented tools. 23 subcommands registered via `src/fox-ai/dispatch.def`, leaves are the existing `fox-ai-*` binaries (7 C++ + 16 bash). Reachable as `fox ai <sub>` or `fox-ai <sub>` directly. |
| `fox-sec`         | Namespace dispatcher for security tools. 30 subcommands (firewall, vpn, audit, snitch, harden, jail, ...) via `src/fox-sec/dispatch.def`. The standalone `fox-sec` dashboard was renamed to `fox-sec-dashboard` to free up the namespace name; same dashboard now reachable as `fox sec dashboard`. |
| `fox-theme`       | Namespace dispatcher for theme tools (tweak, wallpaper, develop). 3 subcommands via `src/fox-theme/dispatch.def`. |
| `fox-dev`         | Namespace dispatcher for developer tools (new-project, init, build-verify, test, word-count, tail, distro-build/flash/guide, generate-module, template-lint, aider). 12 subcommands via `src/fox-dev/dispatch.def`. |
| `fox-sys`         | Namespace dispatcher for system tools (install, uninstall, rollback, doctor, hw-info, lock, menu, cheatsheet). 8 subcommands via `src/fox-sys/dispatch.def`. |
| `fox-intel`       | Library (`libfox-intel.a`) — Ollama client, embeddings, helpers. The AI primitive every other tool links against. |
| `fox-render-fast` | Concurrent template engine. Drop-in for `render.sh`, byte-for-byte match. |
| `fox-pulse`       | Single-epoll daemon multiplexing Hyprland IPC + inotify + debouncers. Replaces `focus-pulse.sh` and `fox-monitor-watch.sh`. |
| `fox-vault`       | `mlock()`'d in-RAM secret store with Unix-socket CLI.               |
| `fox-install`     | C++ orchestrator with X-macro module registry. Active install path. Two flows: legacy flag-driven (default) and state-driven (`FOX_INSTALL_STATE_DRIVEN=1`) which adds a wizard + manifest-preview + per-run install log. See `## State-driven install path` below. |

The architecture is in mid-refactor — see `plans/architecture-refactor.md` for the master plan. Phases complete: 1 (`fox-common/` extraction + `src/fox/` skeleton), 2 (`fox ai *`, 23 subcommands), 3 (`fox sec *`, 30 subcommands), 4 (`fox theme` + `fox dev` + `fox sys`, 23 more subcommands), 6 (state-driven installer through Step 18; default cutover pending). All 5 intended namespaces are now live (76 subcommands total under `fox <ns> <sub>`). Next: Phase 5 (new `fox sys font` tool) or Phase 6 cutover (flip state-driven to default).

## Adding a new tool

```
mkdir src/fox-foo
# write src/fox-foo/Makefile exposing: all / install / clean / (optional) test
# write src/fox-foo/*.cpp
make           # root Makefile auto-discovers it
make test      # auto-runs your test target if present
```

The Makefile contract is the only requirement. No central registration, no dependency declaration.

## Adding a new install module (fox-install)

```
# 1. Write src/fox-install/modules/foo.cpp:
#
#     #include "../core/context.hpp"
#     #include "../../fox-common/shell.hpp"
#     #include "../../fox-common/ui.hpp"
#     namespace fox_install {
#     void run_foo(Context& ctx) {
#         ui::section("Doing foo");
#         sh::pacman({"some-pkg"});
#         sh::systemctl_enable("some.service", /*user=*/false);
#     }
#     }
#
# 2. Add one line to src/fox-install/core/modules.def:
#
#     FOX_MODULE( foo, run_foo, "--foo", "What foo does", false )
#
# 3. Rebuild. --help, --foo/--no-foo parsing, dry-run plan, and the
#    dispatcher all pick it up automatically.
```

The X-macro registry in `modules.def` is the single source of truth. The args parser, `--help`, dry-run preview, dispatcher, and registry-validation test all derive from it.

**Header-path note (post-Phase-1):** ui.hpp and shell.hpp moved from `fox-install/core/` to `fox-common/`. Includes from inside fox-install use `../../fox-common/ui.hpp` (from `modules/`) or `../fox-common/ui.hpp` (from `fox-install.cpp`). The fox-install Makefile links `libfox-common.a` so the headers + .a get pulled in automatically.

## Adding a new namespace to the fox dispatcher (Phase 2+)

```
# 1. Build a namespace dispatcher binary (src/fox-ai/, src/fox-sec/, ...)
#    that itself uses an X-macro dispatch.def to route subcommands.
#
# 2. Add one line to src/fox/dispatch.def:
#
#     FOX_NAMESPACE( ai,    fox-ai,    "AI-augmented tools (doctor, snitch, review, ...)" )
#     FOX_NAMESPACE( sec,   fox-sec,   "Security tools (audit, firewall, vpn, ...)" )
#     FOX_NAMESPACE( theme, fox-theme, "Theme management (tweak, wallpaper, swap)" )
#
# 3. Rebuild fox. `fox help` lists the new namespace, `fox ai <tab>`
#    completes against fox-ai's own registry, `fox ai doctor` execs
#    fox-ai-doctor with remaining args.
```

The pattern mirrors fox-install's X-macro registry — single source of truth per dispatcher, no central registration beyond the one line in dispatch.def. See `plans/architecture-refactor.md` D1-D6 for the full architectural rationale.

**Live example:** `src/fox-ai/` is the first namespace dispatcher (Phase 2). Use its `main.cpp`, `dispatch.def`, and `Makefile` as the template when creating a new namespace. Each namespace dispatcher is ~70 lines of C++ + the registry — adding a new namespace is genuinely cheap.

## Reusable headers

Modules and tools share these by `#include`-ing them; never duplicate the functionality.

| Header                            | Provides                                                          |
| --------------------------------- | ----------------------------------------------------------------- |
| `src/fox-intel/fox_intel.hpp`     | `FoxIntel.ask(prompt)`, embeddings, `cosine_similarity`, Ollama state mgmt. **Every AI-flavored command imports this — there is no separate "AI module" abstraction; AI is a library call.** |
| `src/fox-common/ui.hpp`           | Pacman-style `section`/`substep`/`ok`/`warn`/`err`/`progress`/`summary_row`/`ask_yn`. (Moved from `fox-install/core/` in Phase 1 of the architecture refactor — link `libfox-common.a`.) |
| `src/fox-common/shell.hpp`        | `sh::run`/`capture`/`pacman`/`systemctl_*`/`sudo_warmup` + `set_dry_run`. Never `system()`/`popen()` directly. (Moved from `fox-install/core/` in Phase 1.) |
| `src/fox-common/dispatch.hpp`     | `fox_common::dispatch::{Entry, print_help, find, exec_leaf}`. The registry → execvp pattern used by `fox` and every namespace dispatcher (`fox-ai`, `fox-sec`, ...) post-Phase 2. |
| `src/fox-install/core/context.hpp` | Install-specific: state passed into every install module. Hardware flags, paths, theme name, global flags. Stays in `fox-install/` (not promoted) because it's install-scoped. |
| `src/fox-install/core/module.hpp` | Install-specific: Module interface that every `modules/*.cpp` implements. |

## When to port shell → C++

Port when **one or more** of these apply:

- **Frequently invoked** (>1/sec, or in a hot path like Hyprland event handling).
- **Long-running daemon.**
- **Security-critical** (handles secrets, kernel APIs, signing).
- **Needs registry-based extensibility** (more than a handful of modes/subcommands).
- **Complex parsing or data structures** (templates, palettes, graphs, JSON).

**Leave alone** when the script is mostly orchestration of 2–3 commands and runs once per user action — porting it buys verbosity, not perf. Examples that should stay in shell: small `fox-knock`-style wrappers that call one external binary and `notify-send`.

## AI integration recipe

A command goes from "no AI" to "AI-integrated" by adding three lines:

```cpp
#include "../../fox-intel/fox_intel.hpp"
// ...
FoxIntel ai;
std::string summary = ai.ask("Summarize these logs:\n" + logs);
```

There is no AI framework, no plugin system, no "AI module" class to derive from. `libfox-intel.a` is already linked into anything that wants it; instantiate `FoxIntel`, call `.ask()`, done. Embedding-based RAG is `ai.get_embedding(text)` + `FoxIntel::cosine_similarity(a, b)`.

## Testing discipline

`make test` runs every `src/<tool>/test` target.

- **Do** unit-test pure functions: palette parsing, substitution, vault crypto roundtrip, registry invariants.
- **Don't** unit-test modules that call `pacman` / `systemctl`. For those, write integration tests that flip `sh::set_dry_run(true)` and assert the planned command sequence. Real system tests belong in CI under a container.
- Tests live in `src/<tool>/tests/` and are compiled by the tool's own Makefile under a `test` target. The umbrella `make test` skips silently for tools with no test target.

## Conventions

- **C++17**, `-Wall -Wextra`, no exceptions in hot paths (use return codes / `std::optional`).
- **No `system()` / `popen()`** outside `shell.cpp`. Subprocess goes through `sh::` so dry-run + logging stay centralized.
- **Atomic file writes**: `tmp + rename`, never write-in-place.
- **No `mkdir -p` in C++ — use `std::filesystem::create_directories`** (it's already atomic and handles races).
- **Comments**: only when the *why* isn't obvious. Don't narrate what the code does — the names already do that.
- **Memory hygiene** for anything secret: `mlock()` the page, XOR-obfuscate at rest, `explicit_bzero` on destruction. Pattern is in `src/fox-vault/vault_store.cpp`.

## install.sh migration status

**Migration complete.** `install.sh` is a 90-line wrapper (self-update + sudo keepalive + build + exec). All 21 install modules are native C++ — there is no longer any `bridge::call()` site in the fox-install codebase. The bridge infrastructure (`core/mappings_bridge.*`) has been deleted.

**Native module index (all 50, source of truth: `core/modules.def`):**

| Phase           | Modules                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------- |
| 0 — discovery   | detect, preflight, theme                                                                 |
| 1 — system      | deps, privacy, perf, clock_sync, ufw, security, arch_audit, no_coredumps, hidepid, noexec_tmp, iommu, makepkg_harden, etckeeper, mac_random, gpg_agent_cache, catppuccin_cursor, papirus_icons, zsh_plugins, keyring_full, endlessh, browser_hardening, dispatch_hooks, throttling, greetd, greetd_fingerprint |
| 2 — render      | render, symlinks, specials                                                               |
| 3 — opt-in      | vault, ai, ollama_hardening, models, opencode, github                                    |
| 4 — GPU         | amd_gpu, intel_gpu, nvidia (auto-enabled by `detect` when hardware present)              |
| 5 — hardware    | fprint, fprint_pam, ssh_harden                                                           |
| 6 — build       | xgboost, cpp_pro                                                                         |
| 7 — per-machine | monitors, personalize                                                                    |
| 8 — report      | post_install, summary, next_steps                                                        |

**`install.sh.legacy` is gone.** Every install step has a native module, including the SSH hardening wizard (`--ssh-harden`). Git history retains the legacy bash forever: `git show <pre-cutover-sha>:install.sh`.

**Why `mappings.sh` is still on disk**
- `shared/hyprland_scripts/{fox-monitor-watch.sh, fox-unlock-hook.sh, rotate_wallpaper.sh}` source `mappings.sh` at runtime — they're deployed to `~/.config/hypr/scripts/` by the symlinks module and run as systemd user services. `mappings.sh` is a runtime helper library for them, not an install-time dependency anymore.
- `update.sh` (separate tool) sources `mappings.sh` for its template-capture logic.

**Don't add new install steps to `install.sh` or `mappings.sh`** — write a `fox-install` module instead. The X-macro registry is the single source of truth.

## State-driven install path

Phase 6 added a parallel install flow behind `FOX_INSTALL_STATE_DRIVEN=1`. The legacy flag-driven path remains the default — the cutover is pending real-install miles. Both paths run the same module set; the difference is in how the user picks which modules and how errors surface.

```bash
# legacy: --full / --only / --no-X / inline y/n prompts per module
./install.sh --full

# state-driven: wizard → preview → run, with per-run install log
FOX_INSTALL_STATE_DRIVEN=1 ./install.sh --full   # repair mode (non-interactive)
FOX_INSTALL_STATE_DRIVEN=1 ./install.sh           # interactive wizard
./src/fox-install/fox-install --wizard-demo       # wizard UI only, no install
```

What the state-driven path adds:
- **Manifest** at `$XDG_CONFIG_HOME/foxml/install-state.json` records which modules last ran + their source hashes.
- **State classifier**: each module that opts in (via a `check_X_state` callback in `core/state_checks.cpp` + FOX_MODULE_FULL line) reports Fresh / Noop / Update / Conflict / Blocked. Currently wired: `deps`, `render`, `etckeeper`, `arch_audit`, `vault`, `mac_random`. Legacy `FOX_MODULE` entries default to Fresh.
- **Wizard** (`core/wizard.{hpp,cpp}`): per-module hjkl screen, SPACE toggle (binary) or cycle (Conflict). Pure printf + ANSI redraw — no ftxui dep, works in any TTY including bare Linux console.
- **Preview**: aggregated plan with `+`/`-`/`!` markers, single y/n commit.
- **Conflict resolution** (`core/conflict_resolve.{hpp,cpp}` + `wizard::apply_conflict_decisions`): user picks per-module — KeepMine (skip the module), TakeNew (overwrite normally), or BackupThenTakeNew (write `.foxml-bak` then overwrite). Sentinel paths live in a small per-slug lookup in `wizard.cpp`.
- **Repair mode**: `--full` under state-driven promotes Conflict to BackupThenTakeNew and short-circuits the wizard/preview prompts.
- **Install lockfile** (`core/install_lock.{hpp,cpp}`): per-uid flock at `$XDG_RUNTIME_DIR/foxml-install-<uid>.lock`. Two concurrent installs report the holding PID + exit 1; dry-runs and `--wizard-demo` are exempt.
- **Subprocess log** (`sh::set_stderr_log` + `sh::log_section`): forked-child stderr redirected to `$XDG_STATE_HOME/foxml/install-<ts>.log` per run, with section markers per module. The dispatcher tails the log on module failure so errors don't scroll past.

### Adding a state_check to a module

```cpp
// 1. Add to src/fox-install/core/state_checks.hpp:
Classification check_foo(const Context& ctx, const Manifest& manifest);

// 2. Implement in src/fox-install/core/state_checks.cpp using either
//    user_unit_check (for systemd units), the file-hash compare
//    pattern in check_render / check_mac_random, or a custom probe
//    (check_deps reads pacman -Qi for sentinel packages).

// 3. Update src/fox-install/core/modules.def — change FOX_MODULE to
//    FOX_MODULE_FULL with the prereq booleans + the state_check fn:
FOX_MODULE_FULL( foo, run_foo, "--foo", "What foo does", false,
                 /*root*/ true, /*gfx*/ false, /*net*/ false,
                 state::check_foo )
```

The wizard immediately reports real Classification for that module instead of the "no state_check — assumed fresh" placeholder. If the check can produce `Status::Conflict`, also add a sentinel path entry to `conflict_sentinel()` in `wizard.cpp` so `BackupThenTakeNew` / `KeepMine` resolve to file-IO; without an entry, the user's conflict_decision is recorded in the manifest but not yet applied.

## AI integration (worked examples)

The pattern documented in "Reusable headers" / "AI integration recipe" is live in **six** `src/fox-ai-*/` binaries:

| Tool             | Captures                                          | Asks the model to |
| ---------------- | ------------------------------------------------- | ----------------- |
| `fox-ai-doctor`  | failed systemd units + `journalctl -p err` + kernel ring buffer | diagnose + suggest surgical fixes |
| `fox-ai-snitch`  | `ss -tupn state established` + listening sockets + ufw rules    | flag suspicious egress (beaconing / exfil) |
| `fox-ai-review`  | `git diff --cached` + CLAUDE.md + INVARIANTS.md   | emit `BLOCK:` / `WARN:` / `OK` lines (exits non-zero on BLOCK — wire as pre-commit hook) |
| `fox-ai-oracle`  | KEYBINDS.md + README.md + installed fox-* + active theme | answer the user's natural-language `how do I…` question |
| `fox-ai-audit`   | `arch-audit -uf` + lynis filtered output + `fox-audit` | rank top 3 actionable findings for THIS host |
| `fox-ai-bouncer` | `journalctl -u usbguard --since -30min` + USBGuard policy | classify a blocked USB device as BENIGN/SUSPICIOUS/HOSTILE |

The recipe behind each is identical:

```cpp
#include "../fox-intel/fox_intel.hpp"

FoxIntel ai;
if (!ai.ensure_ollama_running()) return 1;

std::string prompt = "Diagnose: ...";
ai.ask(prompt, /*stream=*/true);
```

That's the whole integration. Any future `fox-ai-*` tool follows this shape:

1. Capture context via short-lived `execvp` calls (`systemctl`, `journalctl`, `ufw`, `lspci`, …).
2. Build a focused prompt with the captured state.
3. `FoxIntel.ask(prompt, /*stream=*/true)` and let the response flow to stdout.

Embedding-backed RAG is `ai.get_embedding(text)` + `FoxIntel::cosine_similarity(a, b)`; see `src/fox-intel/fask.cpp` for a reference implementation. **There is no AI framework or plugin abstraction** — `libfox-intel.a` is the dependency, the constructor + `.ask()` are the API.

## What NOT to do

- Don't reintroduce centralized helper bash files. Bash that survives the migration should be small, scoped to one tool, and called from a `fox-install` module.
- Don't add AI integration as a separate "framework." It's `#include "fox_intel.hpp"` + `ai.ask()`. Same pattern everywhere.
- Don't write multi-paragraph docstrings on functions. Headers explain why the file exists; functions get a 1-line comment if anything.
- Don't add a feature flag system for in-development C++ code. Compile it in, gate it behind a CLI flag if needed, delete the flag when stable.
- Don't pre-fork registries or plugin loaders for features that don't have at least three concrete callers yet.

## Useful one-liners

```bash
# Full clean rebuild + test
make clean && make && make test

# Just the orchestrator
make -C src/fox-install && ./src/fox-install/fox-install --help

# Render with the native engine
./src/fox-render/fox-render-fast themes/FoxML_Classic/palette.sh templates /tmp/out

# Dry-run an install plan
./src/fox-install/fox-install --dry-run --full
```
