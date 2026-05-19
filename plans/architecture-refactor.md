# Architecture Refactor: Unified `fox` Dispatcher + Shared Core

Master plan for collapsing the ~70 flat `fox-*` binaries/scripts into a hierarchical `fox <namespace> <subcommand>` CLI, centralizing shared infrastructure in `src/fox-common/`, and fixing the install-time UX. Each slice below is independently shippable and has its own subplan file (`plans/refactor/NN-<slice>.md`) authored when work on that slice begins.

## Table of Contents

- [Objective](#objective) · [Background & Motivation](#background--motivation)
- **Architectural Decisions (19):**
  - Dispatcher: [D1 Hierarchical dispatch](#d1-two-level-hierarchical-dispatch-with-leaf-execvp) · [D2 X-macro registry](#d2-each-namespace-dispatcher-uses-the-x-macro-registry-pattern) · [D3 Shared core](#d3-shared-core-in-srcfox-common) · [D4 Language-agnostic leaves](#d4-language-agnostic-leaves) · [D5 Hard cutover](#d5-hard-cutover-no-deprecation-wrappers) · [D6 Discoverability](#d6-discoverability-via-standard-help-patterns)
  - Extensibility: [D7 Compositor abstraction](#d7-compositor-abstraction-extensibility-hook) · [D8 Config profiles](#d8-config-profile-support-extensibility-hook) · [D10 Palette source-of-truth](#d10-single-source-of-truth-for-aesthetic-values)
  - Installer: [D11 State-driven installer](#d11-state-driven-installer-single-unified-entry-idempotent-conflict-aware) · [D17 Terminal capability + TUI fallback](#d17-terminal-capability-detection--graceful-tui-fallback) · [D18 Bootstrap channels](#d18-bootstrap-channels--fresh-install-path-is-the-load-bearing-case)
  - Conventions: [D9 Bash port policy](#d9-bash--c-port-policy-substantial-scripts-threshold) · [D12 CLI conventions](#d12-standardized-cli-conventions-across-every-fox--tool) · [D13 Shell completions](#d13-shell-completion-generation-zsh--bash--fish) · [D14 Logging](#d14-structured-logging-convention) · [D15 CI pipeline](#d15-ci-pipeline-github-actions) · [D19 Safety & correctness](#d19-safety--correctness-conventions-for-all-new-c)
- [Out of Scope](#out-of-scope) · [Phased Rollout](#phased-rollout) · [Per-Slice Subplan Convention](#per-slice-subplan-convention) · [Tentative Namespace Groupings](#tentative-namespace-groupings) · [Open Questions](#open-questions)
- **Related Work (24):**
  - Wallpaper/Firefox: [R1](#r1-per-monitor-wallpaper-quality-low-source-resolution--blunt-center-crop) · [R4](#r4-firefox-install-gap-slow-startup-theme-drift)
  - tmux/readability: [R2](#r2-tmux-config-not-templated) · [R8](#r8-tmux-sessionwindow-garbage-collection) · [R10](#r10-readability-audit-inactive-panes--muted-palette-values) · [R16](#r16-tmux-text-duplication-across-panes-synchronize-panes-accidental-trigger) · [R22](#r22-tmux-session-naming-convention-slug-from-cwd)
  - Keybinds/screenshots: [R3](#r3-hyprland-keybind-doc-drift) · [R6](#r6-toggle-script-audit-ghost-mode-shape-bugs-in-other-toggles) · [R7](#r7-keybind-collision-audit) · [R11](#r11-screenshot-workflow--split-quick-capture-from-edit-with-tools)
  - Installer bugs: [R5](#r5-hyprland-live-state-drift-reconciliation) · [R14](#r14-preflight-boot-partition-free-space-math-bug) · [R15](#r15-no-user-feedback-during-bootstrap-compile-phase) · [R17](#r17-install-lockfile-concurrency-safety)
  - Diag/uninstall: [R18](#r18-diagnostic-bundle-fox-sys-diag) · [R19](#r19-uninstall-coverage-audit)
  - Power/distro: [R12](#r12-conditional-power-profiles-perf-module--batteryactemperature-aware) · [R13](#r13-custom-archiso-integration--ensure-distro-chains-into-fox-sys-install)
  - Dev iteration: [R20](#r20-hyprland-config-validation-gate-fox-theme-validate) · [R21](#r21-theme-hot-preview-live-palette-iteration) · [R23](#r23-pre-commit-hook-for-fox-ai-review) · [R24](#r24-deferred-tui-color-picker-for-live-palette-editing)
  - Docs/recovery: [R9](#r9-recoverymd-verification)
- [Status & Sign-off](#status--sign-off)

## Objective

Replace the current sprawl:

- 6 native binaries with C++ source under `src/fox-ai-*/`
- ~20 additional `fox-ai-*` bash scripts deployed to `~/.local/bin/`
- ~30 `fox-*` security/system bash scripts deployed to `~/.local/bin/`
- 5 other native binaries (`fox-install`, `fox-intel`, `fox-pulse`, `fox-render`, `fox-vault`, `fox-ask`, `fox-agent-parse`)
- 3 short-name AI utilities (`fask`, `findex`, `fhelp`)

…with one entry point (`fox`) that dispatches into namespace-owned subcommand registries. Outcome:

- `fox` (no args) → list namespaces with one-liners
- `fox ai` → list ai subcommands
- `fox ai doctor` → run the doctor tool
- `fox ai doctor --help` → tool-specific help
- Tab-completion works at every level

## Background & Motivation

Three concrete problems the current layout has:

1. **Name collisions.** `fox-ai-snitch` vs `fox-snitch`, `fox-ai-audit` vs `fox-audit`, `fox-ai-bouncer` vs `fox-bouncer`. Same word, totally different tool. Resolved by namespacing: `fox ai snitch` vs `fox sec snitch`.
2. **Zero discoverability.** Users need to know a binary exists to find it. There is no `fox sec <tab>` today; you grep `~/.local/bin` and hope.
3. **Onboarding wall.** A new contributor opens the repo and sees 70 binaries with no implicit categorization. The "AI vs Security vs Theme vs Dev" partition lives only in the author's head.

The native binaries already mostly follow a good pattern (`src/<tool>/` with its own Makefile, X-macro registry in `fox-install/core/modules.def`). This refactor extends that pattern *across the whole CLI surface* and promotes the install-only helpers (`ui.hpp`, `shell.hpp`, `args.hpp`) into a shared `src/fox-common/` so any tool can use them.

## Architectural Decisions

### D1: Two-level hierarchical dispatch with leaf execvp

Top-level `fox` binary knows about namespaces only. Each namespace (`fox-ai`, `fox-sec`, etc.) is itself a small dispatcher binary with its own X-macro registry. Leaf binaries (`fox-ai-doctor`, `fox-sec-firewall`) stay independent and can still be run standalone.

```
fox ai doctor --json
  → execvp("fox-ai", ["doctor", "--json"])
    → execvp("fox-ai-doctor", ["--json"])
```

**Why:** Mirrors the existing `src/fox-install/core/modules.def` pattern. Adding a new subcommand only touches one namespace's dispatch.def — no central registration. Leaves stay shippable independently (systemd units, hyprland hooks can still reference `fox-ai-doctor` directly during transition).

**Alternative rejected:** Single fat `fox` binary with all subcommands compiled in. Faster dispatch (no exec) but rebuild-the-world on any change, can't run individual tools standalone, fights the existing modular pattern.

### D2: Each namespace dispatcher uses the X-macro registry pattern

Identical shape to `fox-install/core/modules.def`. Example for `src/fox-ai/dispatch.def`:

```cpp
//          name          binary           description
FOX_SUBCMD( doctor,       fox-ai-doctor,   "Diagnose systemd / Hyprland / Waybar breakage" )
FOX_SUBCMD( snitch,       fox-ai-snitch,   "Flag suspicious outbound network connections" )
FOX_SUBCMD( review,       fox-ai-review,   "Pre-commit review of staged changes" )
FOX_SUBCMD( ask,          fox-ai-ask,      "Ask the local model a question" )
...
```

The dispatcher binary, --help formatter, tab-completion generator, and registry-validation test all derive from this file. Single source of truth per namespace.

### D3: Shared core in `src/fox-common/`

Promote `src/fox-install/core/{ui,shell,args}.{hpp,cpp}` to `src/fox-common/`. Add a new `src/fox-common/dispatch.hpp` for the registry → execvp pattern. Migration order:

1. Create `src/fox-common/` with copies (don't break fox-install)
2. Update `fox-install` includes to point at the new location
3. Delete the duplicates in `fox-install/core/`
4. Each new namespace dispatcher includes from `fox-common/` directly

### D4: Language-agnostic leaves

The dispatcher does not care if `fox-sec-firewall` is C++, bash, Python, or a symlink. It just execvps to whatever's on `$PATH`. This means:

- Bash leaves can be registered immediately, ported to C++ later (or never) per `CLAUDE.md`'s "When to port" criteria
- No artificial pressure to port scripts that don't meet the criteria
- The user experience (`fox sec firewall`) is identical regardless of implementation language

### D5: Hard cutover, no deprecation wrappers

User confirmed she controls all the call sites (waybar modules, systemd units, hyprland hooks, her own muscle memory). Soft transition would add ~70 trivial wrapper scripts for marginal benefit. Each namespace slice updates its call sites as part of the migration.

### D6: Discoverability via standard help patterns

Match git/docker/kubectl conventions:

- `fox` → namespace list with one-line descriptions
- `fox help` → same as above (alias)
- `fox <ns>` → subcommand list for that namespace
- `fox <ns> help` → same as above (alias)
- `fox <ns> <cmd> --help` → defer to the leaf's own help

No custom man pages, no separate help system. The X-macro registry generates the namespace-level help; each leaf owns its own `--help`.

### D7: Compositor abstraction (extensibility hook)

Tools that talk to the compositor (waybar reload, IPC events, layer queries, workspace ops) go through a thin abstraction layer:

```
src/fox-common/compositor.hpp        // interface
src/fox-common/compositor_hyprland.cpp  // current implementation
src/fox-common/compositor_niri.cpp      // future, when needed
src/fox-common/compositor_sway.cpp      // future, when needed
```

Interface covers: `reload_compositor()`, `send_ipc(event, payload)`, `list_windows()`, `current_workspace()`, `move_window_to_workspace(id, ws)`, `set_keybind(...)`. Implementation selected at startup via env var (`$XDG_CURRENT_DESKTOP`) or `fox config get compositor`.

**Why now:** Retrofitting compositor abstraction after every tool has hardcoded `hyprctl` calls is a refactor disaster. Designing the interface up front is cheap; adding new backends later is a single new file.

**Scope clarification:** Hyprland backend is the only implementation that ships in this refactor. Niri/sway support is a separate future slice that just adds a new file. The point now is the seam.

### D10: Single source of truth for aesthetic values

Every hardcoded palette / accent / sizing value across the codebase routes through `themes/<theme>/palette.sh`. No raw hex strings, no duplicated `rgba(212,152,90, …)`, no `border_size = 0` literals scattered across files. If it's themable, it lives in `palette.sh` and gets substituted at render time.

**Status today:** Mostly there for the templated apps (waybar, kitty, hyprlock, etc. — `templates/<app>/` files use `${PRIMARY}` / `${PEACH}` / `${BLUSH}` placeholders that `fox-render` substitutes). Holes:

- **tmux.conf** lives as a flat `~/.tmux.conf`; `templates/tmux/` is empty. Today's edits hardcoded `#d4985a` in five places. Should be templated.
- **Hyprland modules** under `~/.config/hypr/modules/` (theme.conf etc.) — some are rendered from templates, others are hand-edited and accumulate drift.
- **Shell scripts** (`ghost-mode.sh`, etc.) sometimes have their own copies of color constants for `notify-send` icons or similar.
- **C++ sources** under `src/fox-*/` may have hardcoded peach in border-format strings, status colors, etc. These need either palette.sh-generated headers OR runtime palette loading.

**Mechanism:**

1. **Lint step:** `make lint-palette` greps for known palette hex values outside `themes/*/palette.sh` and `rendered/`. Fails the build if hits exist. Single command tells you where the leaks are.
2. **Templated configs:** Anything user-facing that contains a palette value goes under `templates/<app>/` with placeholders, rendered via `fox-render`. Removes the hand-edit-then-drift failure mode.
3. **C++ palette header:** `src/fox-common/palette.hpp` is generated at build time from the active `themes/<theme>/palette.sh`. C++ tools reference `Palette::peach()` instead of `#d4985a`.
4. **Audit slice (phase 9.5):** One-time pass that finds every existing leak and either templates it, moves it to palette.sh, or documents why it must stay literal (e.g., legal/external constraint).

**Why now:** The user-visible symptom is "Caramel hits 'edit hardcoded value' more than once per session." That's a maintenance tax that compounds. Solving it once with a lint gate prevents the regression from coming back.

### D8: Config profile support (extensibility hook)

Single state file: `~/.config/foxml/profile` containing the active profile name. Profiles live as directories: `~/.config/foxml/profiles/{work,personal,demo}/` and contain overrides for any tool that wants profile-aware behavior.

Tools query active profile via `fox_common::active_profile()`. Default profile is `default` (no override directory needed). Migration is zero-cost: tools that don't care about profiles just don't call the function.

CLI surface:
- `fox config use <profile>` — switch active profile
- `fox config list` — show available profiles
- `fox config new <name>` — scaffold a new profile directory
- `fox config show` — print current profile + which tools have profile overrides

**Why now:** Same as D7. Adding a profile mechanism after tools assume single-config is painful. The hook is cheap; usage emerges later.

### D12: Standardized CLI conventions across every `fox-*` tool

Every namespace dispatcher and every leaf binary supports the same baseline flags. Implemented once in `src/fox-common/cli.hpp`, included everywhere.

| Flag                     | Meaning                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------- |
| `--help` / `-h`          | Print usage, auto-derived from X-macro `FOX_SUBCMD(...)` description fields            |
| `--version`              | Print fox release version + git sha                                                     |
| `--quiet` / `-q`         | Suppress non-error output (still log to D14 sink)                                       |
| `--verbose` / `-v`/`-vv` | Increase log detail (-v = info, -vv = debug)                                            |
| `--dry-run`              | Preview without mutating state. Already exists for `fox-install`; promote to standard. |
| `--json`                 | Machine-parseable output. Affordance for piping into other fox-* tools or jq.           |
| `--no-color`             | Disable ANSI color; also honored via `NO_COLOR` env var per https://no-color.org/      |

**Standard exit codes** (per `sysexits.h`):
- `0` — success
- `1` — generic failure
- `2` — user-cancelled (Ctrl-C, "no" to confirm prompt)
- `64` — usage error (bad args)
- `66` — input data error (e.g., missing config file)
- `73` — can't create output file (permission, disk full)
- `78` — config error

**Why:** Today every tool reinvents argv parsing. With ~73 subcommands post-migration, that's 73× the bug surface for "this tool's `--help` is missing something" or "this tool exits 0 even on failure." Shared parser fixes the whole class.

### D13: Shell completion generation (zsh / bash / fish)

Auto-generated from the X-macro registries + each leaf's `--list-flags --json` output. Installed by the installer to:
- `~/.config/fish/completions/fox.fish`
- `~/.zsh/completions/_fox` (with `fpath` setup if not present)
- `~/.bash_completion.d/fox` (if user has bash completion enabled)

**User experience:**
- `fox <tab>` → namespace list
- `fox ai <tab>` → subcommand list with descriptions
- `fox ai doctor --<tab>` → flag list with descriptions
- `fox ai doctor --output <tab>` → if flag takes a value, hint type (file path, enum)

**Implementation:** A single `fox sys gen-completions` subcommand that walks the dispatch tree, calls each leaf's `--list-flags --json`, emits the shell-specific completion file. Re-run by the installer on every install/update so completions stay current.

**Cost:** ~1 day of work after dispatcher is up. Massive UX payoff per `fox <tab>` press, daily.

### D14: Structured logging convention

Every fox-* tool emits structured logs to `~/.local/share/foxml/logs/<tool>-<date>.log`. JSON Lines format, one event per line:

```json
{"ts":"2026-05-18T22:33:46.123Z","level":"info","tool":"fox-ai-doctor","event":"started","args":{"json":true}}
{"ts":"2026-05-18T22:33:46.523Z","level":"warn","tool":"fox-ai-doctor","event":"systemd_unit_failed","unit":"foo.service"}
```

**Retention:** Rotate at 10MB per file. Keep 30 days. Logs older than 30 days deleted at next tool invocation.

**Viewer:** `fox sys logs [tool] [--since 1h] [--level error+]` — quick query without grep archaeology. Default: last hour, all levels, all tools, pretty-printed.

**Use cases:**
- "Why did fox-pulse miss that monitor connect?" → `fox sys logs fox-pulse --since 10m` shows the event sequence
- "What did the installer do?" → `fox sys logs fox-install --since 1d` 
- Debug after the fact, without enabling verbose mode upfront and re-running

**Implementation:** Shared `fox-common/log.hpp`. Default-on (writes always), configurable via env var (`FOX_LOG=0` to disable). Library wraps `std::ofstream` with atomic line flush.

### D15: CI pipeline (GitHub Actions)

`.github/workflows/ci.yml` runs on every PR + push to main:

| Job              | What it runs                                                            |
| ---------------- | ----------------------------------------------------------------------- |
| build            | `make` (all native binaries; matrix on Arch + Ubuntu containers)        |
| test             | `make test` (per-tool umbrella)                                         |
| lint-palette     | D10's gate — fail if palette hex appears outside `themes/*/palette.sh` |
| lint-registry    | Validate every X-macro registry (modules.def, each namespace's dispatch.def) |
| lint-keybinds    | R7's gate (once added) — fail on key collisions                         |
| shellcheck       | All bash scripts under `shared/` + `scripts/`                            |
| clang-format     | C++ formatting check                                                    |
| dry-run-install  | `./install.sh --dry-run --full` succeeds                                |

**Why now:** The whole refactor + ongoing development is going to land hundreds of commits. Without CI, "did I break the build" is "wait for next install attempt." With CI, every PR gets a green/red badge in 5 minutes.

**Per Caramel's audience (memory):** repo has high silent clones from hedge funds. A green CI badge is a real signal of "this codebase is actually maintained." Cost: ~half a day of yaml writing.

### D17: Terminal capability detection + graceful TUI fallback

The TUI direction (D11 + ftxui) needs to survive the contexts the installer actually runs in. Critical contexts:

| Context | Capability profile |
| ------- | ------------------ |
| Modern terminal (kitty, alacritty, foot, wezterm) | 24-bit color, full Unicode, Nerd Fonts, mouse, big terminal size |
| Standard `xterm` / `gnome-terminal` | 24-bit color, full Unicode, system fonts only (no Nerd Font glyphs) |
| **Linux console (TTY, fresh Arch install)** | 16 colors, limited Unicode, no Nerd Fonts, no mouse, 80×24 |
| SSH session over slow link | All caps, but redrawing is expensive |
| `screen` / `tmux` nested | Pass-through mostly; some terminfo quirks |

**Detection:** At startup, fox-install (and any other TUI-using tool) queries:
- `$TERM`, `$COLORTERM` → color depth
- `tput colors` → confirm reported color count
- `$DISPLAY` / `$WAYLAND_DISPLAY` → graphical session present?
- Terminal size via `tcgetwinsize` → enough room for full layout?
- Locale charset (`nl_langinfo(CODESET)`) → can render UTF-8 box-drawing?

**Fallback ladder** (each strictly less capable):

1. **Full TUI** — ftxui box-drawing, 24-bit color, Nerd Font glyphs, mouse support
2. **Reduced TUI** — ASCII line chars (`+--+` instead of `╭──╮`), 256 colors, no Nerd Font (substitute ASCII like `[*]`)
3. **TTY-safe TUI** — 16 colors, ASCII only, minimum 80×24, no mouse
4. **Plain output (last resort)** — no TUI at all, sequential prompt-and-print like today's installer. Used if terminal can't even handle minimal TUI redraw (e.g., dumb terminal, log capture). Triggered by `--no-tui` flag for explicit opt-out.

**No-graphical-session mode.** If `$WAYLAND_DISPLAY` and `$DISPLAY` both unset (fresh install in TTY), modules tagged `requires_graphical=true` are auto-skipped with explanation ("requires running Wayland session; rerun after first graphical login"). The installer doesn't pretend to apply waybar/hyprland reloads when there's nothing to reload.

**Network-detection.** Same shape: `requires_network=true` modules check connectivity before running, skip with explanation if offline. Avoids the "downloading package" → 30s timeout failure on a fresh-install machine that hasn't connected to wifi yet.

**Implementation cost:** ~half a day to add capability detection + fallback rendering in fox-common. Pays off the first time someone installs over SSH or in a recovery TTY.

### D19: Safety + correctness conventions for all new C++

Pinned before any new C++ lands so the whole refactor is gated by this baseline, not retrofitting safety after a segfault bites.

**Build-time gates:**
- `-Wall -Wextra -Wpedantic` always
- `-Werror` in CI builds (warnings become PR-blocking failures)
- `-fsanitize=address,undefined` in debug builds; `-fsanitize=thread` for concurrency-touching code
- `-D_GLIBCXX_ASSERTIONS` for stdlib bounds checks in debug
- Treat signed-vs-unsigned comparisons as errors (`-Wsign-compare`)

**Static analysis in CI (D15):**
- `clang-tidy` with the cppcoreguidelines + bugprone + cert + performance check categories
- `clang-analyzer` (scan-build) on full source tree
- `cppcheck` as secondary tool

**Memory + lifetime discipline:**
- **No raw `new` / `delete`.** Use `std::unique_ptr` / `std::shared_ptr` / `std::make_unique`.
- **No raw pointers as owning references.** Raw pointers are non-owning observers only.
- **RAII for every resource:** file handles via `std::ifstream` / `std::ofstream`, sockets via custom RAII wrappers, mutexes via `std::lock_guard` / `std::scoped_lock` (never manual lock/unlock).
- **`std::optional<T>` for nullable values** instead of `T*` or sentinel values.
- **`std::variant<...>` for tagged unions** instead of unions + discriminator.

**Concurrency rules:**
- **One thread by default.** Most fox-* tools are single-threaded — keep them that way unless there's a measured reason to thread.
- **For tools that need concurrency** (fox-pulse, anything daemon-shaped): use `std::async` / `std::thread` with explicit lifetime via RAII (`std::jthread` if C++20 available).
- **Shared state → `std::mutex` + `std::lock_guard`.** No lock-free constructs unless backed by a real performance need + reviewed carefully.
- **No shared mutable globals.** Even thread-local state should be passed explicitly.
- **File-based state (state manifest per D11, logs per D14)** → `flock(LOCK_EX)` before any read-modify-write. Per R17.
- **Atomic file writes** (already in CLAUDE.md): write to `tmp + rename`, never write-in-place. Promotes from CLAUDE.md to D19 enforcement.

**Undefined-behavior pitfalls explicitly avoided:**
- Integer overflow on signed types → use unsigned, or check before arithmetic
- Reading uninitialized memory → always default-initialize (`int x{};`) or initialize at declaration
- Iterator invalidation → no `vec.erase(it++)` patterns; use `it = vec.erase(it)` or range-for with `.erase(remove_if(...))`
- Out-of-bounds indexing → prefer `.at()` over `operator[]` in debug; ASan catches it at runtime

**Testing baseline:**
- Every non-trivial function in `fox-common/` has at least one unit test
- Per-module integration tests use `sh::set_dry_run(true)` (per CLAUDE.md) so they don't mutate state
- ThreadSanitizer runs on every PR for files in concurrency-touching paths
- Fuzzing for parsers (palette parser, state manifest reader, args parser) — `cargo-fuzz`-equivalent or libFuzzer harness

**Code review gates:**
- Any new `std::thread` or `std::async` use requires explicit comment justifying it + documenting the lifetime / shutdown story
- Any new `mutable` member or `const_cast` requires comment explaining why
- Any new use of `reinterpret_cast` or raw pointer arithmetic requires reviewer sign-off

**Why this matters specifically for FoxML:** The dispatcher refactor multiplies the surface area of running C++ code. Today the binary trees that actually run as C++ are fox-install + fox-render + fox-pulse + fox-vault + the 6 fox-ai-*. Post-refactor, every namespace dispatcher + every common-lib function is on the hot path. Bugs in shared code are bugs in every tool. D19 sets the bar high enough that bug shape stays caught at build time, not at runtime on a user's laptop.

### D18: Bootstrap channels — fresh-install path is the load-bearing case

The install architecture must support **getting FoxML onto a machine from zero**, in every context the user lives in. Three supported bootstrap channels, all must hit a working install:

| Channel | How invoked | Context |
| ------- | ----------- | ------- |
| **A — curl bootstrap** | `curl -sL <gh-repo>/raw/main/bootstrap.sh \| bash` | Fresh laptop, TTY only, no git yet. Most common "I want to try this" path. |
| **B — git + install.sh** | `git clone ... && cd Linux_Theme && ./install.sh --full` | User has git already. Manual control. Iterating in-repo. |
| **C — custom archiso** | Boot from FoxML's own archiso, standard Arch installer → handoff to `fox sys install` as final step | Caramel's distro use case. Goal: cold-boot the USB → working FoxML desktop in one flow, no manual download step. |

**All three must work end-to-end on a fresh-install Arch laptop with no graphical session.** TTY-only context. This means:
- Bootstrap script (channel A) does only what's possible without git/network packages pre-installed (`pacman -S git base-devel`, clone, build, exec).
- All install-time TUI fallbacks (D17) kick in: ASCII-only rendering, 16 colors, no Nerd Fonts (yet), no mouse, no Wayland.
- Modules tagged `requires_graphical=true` are deferred — installer does what it can pre-graphical, marks deferred modules in the state manifest, finishes. After reboot into Hyprland, `fox sys install --resume` (or just `--full` per D11's repair-mode semantics) picks up the deferred work and completes.

**The state manifest (D11) is what makes resumable TTY→graphical handoff possible.** Without it, the installer either has to skip Wayland modules forever, or refuse to run pre-graphical. With it, the install is two natural phases:

```
[TTY post-Arch-install]
  $ curl -sL <gh-repo>/.../bootstrap.sh | bash
  → installs: base packages, Hyprland, themes, fonts, configs
  → defers:   waybar reload, mako live-reload, ai-status widget
  → state:    {18 modules done, 9 deferred (graphical)}
  $ reboot

[After first Hyprland login]
  → autostart hook detects deferred modules in state manifest
  → runs them silently (or with TUI notification)
  → state:    {27 modules done, 0 deferred}
```

**Bootstrap.sh post-refactor:** Becomes a ≤30-line script that does ONLY:
1. `pacman -S --noconfirm git base-devel sudo` (assumes pacman + network — true on standard Arch install)
2. `git clone <repo>` into `~/code/Linux_Theme`
3. `cd Linux_Theme && make -C src/fox`
4. `exec ./src/fox/fox sys install --full`

No state management, no module logic, no UX. Pure handoff into the C++ entry. install.sh either becomes the same thing or vanishes (D11 deprecation).

**Why this matters beyond Caramel's use case:** Anyone in the GitHub-clones-the-repo audience can land on a working install from a single curl line. Removes the "where do I even start" friction. Reduces "have you tried turning it off and on again" support to "rerun the curl line, the state-driven installer figures out what to do."

### D11: State-driven installer (single unified entry, idempotent, conflict-aware)

Current install model: `install.sh` (bash wrapper, ~90 lines) + `fox-install` (native binary, runs every module every time) + `update.sh` (separate path, sources `mappings.sh`). Three entry points, no shared state, re-runs everything on every invocation, no notion of "already done."

**Caramel's proposed model (2026-05-18), refined:**

One unified entry — say `fox sys install` (with `install.sh` becoming a thin bootstrap that builds the binary then execs it) — that drives a state machine:

```
┌─────────────────────────────────────────────────────────────┐
│ fox sys install                                              │
└─────────┬───────────────────────────────────────────────────┘
          │
          ▼
   ┌──────────────────┐
   │ Load state       │  ← reads ~/.config/foxml/install-state.json
   │ manifest         │     (per-module: version installed, hash, timestamp)
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ Classify each    │  for each module M:
   │ module           │    state ∈ {noop, update, conflict, fresh}
   └────────┬─────────┘     - noop:     hash(deployed) == hash(source)
            │               - update:   newer source, deployed unchanged
            │               - conflict: deployed has local edits, source changed
            │               - fresh:    never deployed
            ▼
   ┌──────────────────┐
   │ Plan summary +   │  shows the user:
   │ prompt           │    "5 modules already current"
   └────────┬─────────┘    "3 modules have updates available"
            │              "1 module has a conflict — review needed"
            │              "11 modules new since last install"
            ▼
   ┌──────────────────┐
   │ For each         │   conflict: 3-way diff prompt
   │ non-noop module: │   update:    apply silently or with summary
   │ resolve + apply  │   fresh:     apply (this is the first-install case)
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐
   │ Update state     │  write new hashes + version + timestamp
   │ manifest         │
   └──────────────────┘
```

**State manifest format** (`~/.config/foxml/install-state.json`):

```json
{
  "schema_version": 1,
  "fox_version": "5.10.x-commit-sha",
  "modules": {
    "render":     { "version": "...", "source_hash": "...", "deployed_at": "..." },
    "waybar":     { "version": "...", "source_hash": "...", "deployed_at": "..." },
    "hyprland":   { "version": "...", "source_hash": "...", "deployed_at": "..." }
  }
}
```

**Per-module conflict resolution.** If a module deployed `foo.conf` previously and the user hand-edited it, on next install:
- Compute three hashes: `last-deployed`, `current-on-disk`, `new-source`
- If `current-on-disk == last-deployed`: silent update (no user edit, safe overwrite)
- If `current-on-disk != last-deployed && new-source == last-deployed`: silent skip (user customized, source unchanged)
- If `current-on-disk != last-deployed && new-source != last-deployed`: **conflict** — prompt with 3-way diff and options (keep mine / take new / view diff / save mine as `.foxml-bak` and take new)

This matches how Etckeeper, dpkg/apt's conffile handling, and Homebrew handle the same problem. Proven model.

**Sequential-install invariant (Caramel ask, 2026-05-18): "Re-running install must not break existing configs."** This is the load-bearing semantic. Every re-run is *additive or no-op by default* — the installer NEVER silently overwrites a hand-edited file. The three-hash check above guarantees this: if a user modified `foo.conf` and we have a new template version of it, the user gets a prompt, not a surprise. The only path to overwriting a user edit is explicit user consent in the conflict-resolution flow.

**`fox install --full` as repair mode (Caramel reframe, 2026-05-18):** In the current model, `--full` means "re-run every module" (wasteful and slightly dangerous). In the state-driven model, `--full` means "**verify every module is in correct state, repair any detected drift, leave user edits alone**." Concretely:

| Detected state | --full behavior |
| -------------- | --------------- |
| Module deployed and correct | noop, silent |
| Module deployed but file/service drifted (e.g., service disabled that should be enabled, file deleted) | repair: re-enable / re-deploy. Surfaces in summary. |
| Module deployed and user hand-edited file | skip with note. Repair-mode does NOT touch user edits. |
| Module never deployed | install (this is the first-install case) |
| Module's prereqs broken (e.g., masked unit per the etcwatch case) | flagged in config phase, user resolves |

This makes `fox install --full` the right answer when "stuff broke and I don't know what" — runs the full state audit, fixes detected drift, doesn't touch what was working. Becomes the universal "fix my install" command.

**Broken install detection.** Each module's `state_check` function is responsible for catching drift, not just absence:
- For file-deploying modules: does the file exist? Does it match the expected last-deployed hash?
- For service-enabling modules: is the service enabled? Active? Failed?
- For systemd-unit modules: is the unit masked? Loaded?
- For pacman modules: are all expected packages installed?

A module that returns `state=broken{reason="service masked"}` triggers the repair flow with the right hint (offer to unmask, offer to skip, offer to abort). The etcwatch screenshot bug becomes impossible because the broken state is caught in config phase, before any subprocess attempt.

**What this gives us in one move:**
- Re-running `fox sys install` is a near-noop when nothing changed (currently rebuilds everything)
- `update.sh` becomes redundant — same entry point handles both "first install" and "update"
- User customization is preserved by default; never silently overwritten
- The walkthrough UI is *driven by the state classification* — long progress for fresh installs, short summary for noop runs, focused prompts only for conflicts
- Resumable installs come naturally: each module's state transition is atomic in the manifest
- Closes the ❌ missing `_phase_mark` / `_phase_exit_if_done` gap noted in `plans/native-migration-audit.md`

**Implementation notes:**
- The "hash" is content hash of the rendered file (post-template-substitution), not source template — captures what was actually deployed
- For module work that isn't file-based (package installs, systemctl enables), state is "module ran successfully at version X" — re-run is conditional on version change
- The state manifest itself is atomically updated (tmp + rename, per `CLAUDE.md`)

**Walkthrough UX (folds in "installer feels cheap" concerns):**
- Single section per state-classification (Current / Updating / Conflicts / Fresh), not 50 micro-sections
- Prompt only when truly required (conflicts); never "do you want to install pacman packages?" yes/no spam for things the user already confirmed by running install
- Clear progress feedback per module — no jumpy redraws, no silent multi-second pauses
- Summary at end: what changed, what was skipped, what needs follow-up

**TUI direction (Caramel ask, 2026-05-18):** Replace the scrolling-output model with a **single-step-focus TUI** — one pane shows the current module + its activity, log scrolls in a smaller bottom region, forward/backward navigation lets the user step through the plan before committing. Library: `ftxui` (C++17, header-only, MIT). Approximate layout:

```
╭─ fox install — FoxML_Classic ───────────────────────────────╮
│ Phase 1 of 8 · System                                       │
│                                                              │
│ ▶ Module: deps  (3/50)                                       │
│   Installing pacman base packages                            │
│   ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░  62%                    │
│                                                              │
│   5 packages already current, 3 to install, 0 conflicts      │
╰──────────────────────────────────────────────────────────────╯
╭─ Recent log (j/k to scroll, l for full) ────────────────────╮
│ [00:12.4] resolving deps... done                            │
│ [00:13.1] downloading ttf-maple-mono-nf-7.0-1               │
│ [00:14.2] downloading nerd-fonts-monaspace-1.001-1          │
╰──────────────────────────────────────────────────────────────╯
[← prev module] [→ next module] [a abort] [s skip] [q quit]
```

**Specific UX bugs the screenshot (Caramel, 2026-05-18) exposes:**
- ❌ **Stacked Y/N prompts at start** (NVIDIA, Intel, fingerprint) → batch into one "Detected hardware: …. Apply driver setup? [Y/n]" with per-item override if user wants granular. Auto-yes when `--full` is the invocation; only prompt on `--interactive`.
- ❌ **"Execute module deps [Y/n]" after `--full`** → categorical bug. `--full` means "yes to everything that doesn't conflict." Drop this prompt entirely.
- ❌ **Pacman noise** ("warning: ttf-hack-nerd is up to date" × N lines) → fox-install runs pacman, parses output, presents `"5 packages already current, 0 new, 0 updates"`. Raw pacman output goes to the log pane (D14), not the main view.
- ❌ **Progress format** `[#---------------]` → use unicode block characters (`▓▒░`) at 1-char-per-percent precision; smoother and prettier (with ASCII fallback per D17).
- ❌ **Flat 1/50, 2/50 numbering** → group by phase ("Phase 1 of 8 · System · Module 3/26"). User knows where they are in the bigger structure.
- ❌ **Raw systemctl errors leak through** (Caramel screenshot #10): "Failed to reset failed state of unit fox-etcwatch.path: Unit fox-etcwatch.path not loaded.\nFailed to enable unit: ... is masked\nwarning: fox-etcwatch.path enable failed — try `systemctl --user unmask` then re-run". The chronology is jumbled (errors before the explanation) and the user sees raw `systemctl` output. **Fix: subprocess error absorption** (see "Error hygiene" below).
- ❌ **Nvim plugin sync dumps ~600 lines** (Caramel install log, 2026-05-18): every `[plugin] fetch / status / checkout / log` line for 75+ plugins floods the terminal. This is the worst single noise leak. Fix: single line in TUI ("Syncing 75 nvim plugins... 75/75 ✓"), all subprocess output routed to D14 log.
- ❌ **Ollama model pulls** show ~5 progress lines × 12 models = 60+ lines. Condense to one aggregate progress ("Pulling 12 models: ▓▓▓░░ 7/12").
- ❌ **Sequential per-module Y/N prompts** (every `Execute module X (description)? [Y/n]` line). 50 modules × ~1-2 prompts each = 50-100 keystrokes to get through a "full" install. Fix: wizard model batches per-module config into the manifest preview; user confirms ONCE at the manifest commit step.
- ❌ **Module severity annotations** like `[LOCKOUT RISK]` (fprint_pam line) are plain text — should be visually prominent in the wizard config phase (red border, warning icon, explicit risk acknowledgment required).

**What's GOOD and should be preserved** (Caramel feedback, 2026-05-18): The final `Installation summary` block ("theme / script_dir / rendered_dir / gpu / chassis / fingerprint / monitors / wallpapers / backups saved to") is the one part of current installer the user explicitly likes. This becomes the **Phase C output** in the wizard model — static report at the end, not a scroll-to-find-it section.

**Modules without configuration options** (Caramel observation, 2026-05-18): Some modules (privacy, NVIDIA, intel_gpu, post_install) just decide and run — no user-tweakable knobs. The wizard model handles this correctly: each step shows *what will happen + state classification + skip option*, but doesn't fake a Y/N prompt when there's nothing to choose. The interaction surface scales with the actual choice surface.

**Wizard model (Caramel refinement, 2026-05-18):** Cleanly separate the install into two phases.

| Phase | What | Interactive? | Output style |
| ----- | ---- | ------------ | ------------ |
| **A — Configuration** | User walks through modules with `h`/`←` (back) and `l`/`→` (forward). Each step shows: what the module does, current state (already installed / will install / conflict), per-module options. Auto-advances when user confirms a step. | Yes (vim keys) | Single-module TUI, one at a time |
| **A.5 — Manifest preview** | After last config step: full manifest screen. "Here's what's going to happen: 12 install, 3 update, 2 skip (already current), 1 conflict needs resolution. Total estimated time: ~3 min. Press y to commit, e to edit, q to abort." | One y/n | Full plan, scrollable |
| **B — Execution** | Run the manifest. No prompts. TUI shows live progress per module + log tail. Errors get absorbed and reformatted (see below); execution continues even when individual modules fail (track them, show in final summary). | No | Live TUI per D11 sketch above |
| **C — Summary** | "Install complete. 12 installed, 3 updated, 2 skipped, 1 failed (see below). Logs: ~/.local/share/foxml/logs/fox-install-2026-05-18.log." | No | Static report |

The wizard model makes the install **predictable**. User knows everything that will happen before any of it happens. No mid-stream prompts to break flow.

**Per-module state pre-check + prereq declaration.** Each module declares its requirements via X-macro extension:

```cpp
FOX_MODULE_FULL(
    etckeeper,                    // module name
    run_etckeeper,                // entry function
    "--etckeeper",                // CLI flag
    "git-track /etc + drift watcher",  // description
    /* requires_root  = */ true,
    /* requires_graphical = */ false,
    /* requires_network  = */ false,
    /* state_check */ check_etckeeper_state  // function returning {noop, update, conflict, fresh, blocked}
)
```

The dispatcher checks `state_check` for every selected module **during config phase** and surfaces issues before execution:
- `blocked` reason "fox-etcwatch.path is masked" → config-phase prompt: "Unmask now? Skip module? Abort?"
- `noop` → silent (don't even show in execution phase)
- `conflict` → flagged in manifest, user must resolve before commit

This catches the etcwatch-style issue *before* the user is committed to the install, not midway through.

**Error hygiene (subprocess output absorption):** Every subprocess call (`sh::run`, `sh::capture`) returns structured output: `{exit_code, stdout, stderr, duration}`. The installer never lets raw stderr leak to the user TUI. Mapping:

| What | Goes to |
| ---- | ------- |
| Successful subprocess output | D14 log only |
| Failed subprocess output | D14 log + reformatted error in TUI (with hint when available) |
| User-actionable hints | TUI as primary message |
| Recovery options | Interactive prompt (continue / skip / abort) |

The current bash-script-style "let systemctl print its own warning, then we print a hint" pattern is replaced with: catch stderr, parse it, present *one* clean message with the hint inline.

## Out of Scope

Explicit non-goals to prevent scope creep:

- **Port of trivial bash wrappers** (under ~20 lines, single external command + `notify-send`). Porting a 5-line script to 80 lines of C++ produces verbosity, not depth. Per Caramel: bash → C++ port IS in scope for substantial scripts (see phase 8 + D9 below).
- **Contributor scaffolding** (`make new-tool TOOL=foo`). YAGNI until someone other than Caramel tries to contribute.
- **Plugin/extension system.** Out-of-tree tools registering into `fox` is not a use case yet. (Different from D7/D8 extensibility hooks — those are first-party seams, not third-party APIs.)
- **Implementing niri/sway support.** D7 designs the seam; actual non-Hyprland backends are future slices.
- **Implementing config profiles beyond the mechanism.** D8 designs the surface and storage; actual `work`/`personal`/`demo` profile content is user-authored, not shipped.
- **Internationalization, multiple shells beyond zsh, Windows support.** Not in scope.
- **Behavioral changes to existing tools.** This refactor is structural — `fox ai doctor` should produce byte-identical output to `fox-ai-doctor` for the same inputs. Behavior changes are tracked as separate work.

### D9: Bash → C++ port policy (substantial-scripts threshold)

Phase 8 ports bash scripts that meet ONE of:

- **>50 lines of real logic** (excluding comments, blank lines, here-docs)
- **Multiple state transitions** (toggle on/off, mode A/B/C, conditional branching with side effects)
- **Already meets a `CLAUDE.md` criterion** (>1/sec, daemon, security-critical, registry-extensibility, complex parsing)

Skip scripts that are:
- Pure one-shot wrappers (`notify-send "X"; tool --flag`)
- Under ~20 lines and doing one thing

Concrete examples from the current tree:
- ✅ Port: `ghost-mode.sh` (130 lines, multi-state, mutates global blur/opacity/audio), `rotate_wallpaper.sh` (if it has logic beyond `swww img`)
- ❌ Skip: `fox-knock` if it's just `knock <host> 1234 5678 9012; notify-send`, similar trivial wrappers

The "skip" list is not "stay bash forever" — it's "the dispatcher treats them identically to C++ leaves, so language is invisible at the user surface, port them later if the script grows."

## Phased Rollout

Each phase is independently shippable. Repo stays in a working state at every commit boundary. Subplan files (`plans/refactor/NN-<slice>.md`) are authored at the start of each phase, not upfront.

| Phase | Slice                                | Outcome                                                                                            | Subplan                                     |
| ----- | ------------------------------------ | -------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| 0     | This master plan                     | Vision documented, design decisions pinned, scope bounded                                          | *(this file)*                               |
| 1     | `fox-common/` extraction + `src/fox/` skeleton | `fox help` works (prints empty namespace list). No behavior change. fox-install still builds.       | `plans/refactor/01-skeleton.md`             |
| 2     | `fox ai *` migration                 | All AI tools accessible via `fox ai <cmd>`. Old `fox-ai-*` binaries removed. Call sites updated.    | `plans/refactor/02-ai-namespace.md`         |
| 3     | `fox sec *` migration                | All security tools accessible via `fox sec <cmd>`. Old binaries removed. Call sites updated.        | `plans/refactor/03-sec-namespace.md`        |
| 4     | `fox theme`, `fox dev`, `fox sys` migrations | Remaining namespaces migrated. Full surface unified.                                                | `plans/refactor/04-remaining-namespaces.md` |
| 5     | `fox sys font` (new tool)            | Font management via `fox sys font <name>`. Maple Mono + Monaspace available alongside Hack.        | `plans/refactor/05-font-tool.md`            |
| 6     | State-driven installer rebuild       | Implements D11 + D17. Replaces install.sh + fox-install + update.sh with single `fox sys install` entry. **Deprecates bash install entirely** — `install.sh` becomes ≤5-line bootstrap (build + exec) or vanishes. State manifest, conflict resolution, ftxui wizard UX with h/l navigation, manifest preview before commit, repair-mode semantics for `--full`, idempotent re-runs, terminal-capability detection + TTY fallback, subprocess error absorption (no more raw systemctl/pacman/nvim-plugin-sync leaks). Subsumes old "installer UX fixes" and "bootstrap dedupe" slices. Folds in R4a (Firefox install gap) since it's the same surface. Folds in R12 (conditional power profiles) via redesigned perf module. Preserves the existing Installation Summary block (per Caramel: "i like that"). | `plans/refactor/06-state-driven-installer.md` |
| 7     | Substantial bash → C++ ports         | Port all scripts meeting D9 criteria. Inventory authored at start of slice; trivial wrappers explicitly skipped. | `plans/refactor/07-substantial-ports.md`    |
| 8     | Hardcoded-value audit + centralization | One-time pass: every palette/aesthetic value outside `themes/*/palette.sh` either gets templated or documented. `make lint-palette` added as a permanent gate. tmux.conf moved under `templates/tmux/`. | `plans/refactor/08-palette-centralization.md` |
| 9     | Comprehensive docs update            | Update CLAUDE.md (dispatcher contract, "how to add a subcommand," compositor abstraction, profile system, palette source-of-truth rule, updated migration status), README.md (new CLI structure), KEYBINDS.md (consistent `$mainMod`/`Super`/`Alt` usage), RECOVERY.md (verify covers known scenarios per R9), and add a one-page migration guide for users coming from old `fox-*` binary names. | `plans/refactor/09-docs-comprehensive.md`   |
| 10    | (future) Niri backend                | Implement `src/fox-common/compositor_niri.cpp`. Slice exists once Caramel wants to try niri.        | `plans/refactor/10-niri-backend.md`         |
| 11    | (future) Profile content authoring   | Author actual `work` / `personal` / `demo` profile overrides. Slice exists once profiles are needed. | `plans/refactor/11-profile-content.md`      |

## Per-Slice Subplan Convention

Each slice gets its own file under `plans/refactor/` authored at the START of that slice's work (not upfront). Convention:

```markdown
# Slice NN: <Title>

## Goal
One sentence on what shipping this slice produces.

## Inventory
Concrete list of files to create/modify/delete, with current → target state.

## Implementation Order
Numbered steps, each individually committable.

## Exit Criteria
- [ ] checkbox list of what "done" means
- [ ] tests pass
- [ ] call sites updated
- [ ] CLAUDE.md updated if user-visible

## Risks
What could break, what to watch for, rollback strategy.
```

Subplans are short (1-2 pages). They are not architecture docs — they are execution checklists. The architecture lives in this file.

## Tentative Namespace Groupings

Authored from binary names alone — not from reading what each tool actually does. Caramel to review/correct before phase 2 starts.

| Namespace   | Members (tentative)                                                                                                                                                                                                                                                                                                                                  | Notes |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `fox ai`    | doctor, snitch, review, oracle, audit, bouncer, cmd, commit, explain, find, history, log, quick, test, trace, watch, swap, default, bench, purge, status, strategy, ask (was `fask`), index (was `findex`), help (was `fhelp`), setup-project, aider | ~26  |
| `fox sec`   | audit, snitch, firewall, vpn, usb, deadman, dns-shield, dnssec, fingerprint, harden, honey, honeypot, jail, knock, mac, offline, overwatch, ports, proximity, sandbox, sentry-audit, spa, tripwire, allowlist, arm, cafe, bouncer, backup, dispatch                                                                                                | ~29  |
| `fox theme` | tweak, wallpaper, develop                                                                                                                                                                                                                                                                                                                            | 3    |
| `fox dev`   | new-project, init, build-verify, test, word-count, distro-build, distro-flash                                                                                                                                                                                                                                                                        | 7    |
| `fox sys`   | install, uninstall, lock, font (new), hw-info, doctor (the non-AI one)                                                                                                                                                                                                                                                                               | 6    |
| `fox menu`  | menu, cheatsheet                                                                                                                                                                                                                                                                                                                                     | 2    |

Total post-migration surface: 6 namespaces, ~73 subcommands. Same surface, hierarchical.

## Open Questions

Need Caramel input before specific slices begin. Not blocking phase 1.

1. **Installer UX complaints (blocks phase 6).** "Broken and choppy" / "feels cheap" — need specifics. Examples of useful detail: which phase felt slow, what prompts felt redundant, did anything fail silently, did the output look misaligned/ugly, did recovery from partial-install work. Running `./install.sh --dry-run` and noting reactions in real time is the fastest way to surface this.
2. **Namespace grouping corrections (blocks phase 2).** The table above is best-effort from binary names. Caramel to flag any miscategorizations — e.g., does `fox-arm` belong in `sec` or `sys`? Is `fox-dispatch` (phone notification wiring) really security or its own thing?
3. **Short aliases for high-frequency tools (blocks phase 2).** `fask` is short enough to feel like a keystroke saver vs `fox ai ask`. Keep short aliases as symlinks pointing at the namespaced version, or hard-cutover?
4. **Specials handling (blocks phase 4).** `fox-cheatsheet` and `fox-menu` are launchers, not really categorizable. `fox sys menu` and `fox sys cheatsheet`, or top-level `fox menu` / `fox cheatsheet`? Top-level keeps them fast to type but breaks the strict hierarchy.
5. **Compositor abstraction interface scope (blocks phase 1).** What's the minimal set of operations the interface needs to expose? Caramel to enumerate current `hyprctl` usage sites — that's the floor of what `compositor.hpp` needs to wrap.
6. **Profile system trigger (blocks phase 1).** D8 designs the storage + CLI but doesn't ship any actual profiles. Should phase 1 include the `fox config` namespace stub (so the surface exists), or defer that to a later phase since no tools consume it yet?

## Related But Separately Tracked Work

Known concerns that are NOT part of this dispatcher refactor but should not be lost. Each item is a candidate for its own subplan or a one-off fix; they live here so they're visible alongside the architecture work.

### R1: Per-monitor wallpaper quality (low source resolution / blunt center-crop)

**Symptom (Caramel, 2026-05-18):** Vertical-monitor wallpapers look "super zoomed in" — detail loss on the 1.78× upscale + lost subject on the center-crop.

**Root cause** (`src/fox-install/modules/personalize.cpp:156-159`): ImageMagick invocation does cover-fit + center-crop with default filter, no sharpening. For 1920×1080 → 1080×1920 portrait, this upscales 1.78× then crops the middle 1080 strip. Standard "cover" behavior but:
- Default filter (Lanczos, no unsharp mask) → soft upscale
- `-gravity center` → loses off-center subjects
- Source resolution ceiling → no real new detail can be created from a 1920×1080 source

**Fix tiers (cheapest → best):**
1. **Add `-filter Lanczos -unsharp 0x0.5+0.5+0.005`** — sharper upscale, no new deps. ~1 line change.
2. **Use `-gravity entropy`** if ImageMagick version supports it (≥7.0.8-41) — smart crop centers on the most interesting region.
3. **Optional realesrgan-ncnn-vulkan pre-upscale** when available — AI-upscale to 4K first, then crop. Best quality, +1-2s per wallpaper at install time, requires AUR dep.

**Status:** Tracked, not in any phase yet. Fix can land independently of the dispatcher refactor.

### R2: tmux config not templated

Today's tmux edits hardcoded `#d4985a` in five places. `templates/tmux/` is empty. Already captured under D10 + phase 9, listed here for cross-reference.

### R3: Hyprland keybind doc drift

`KEYBINDS.md:519` documented `ALT + B` as "Toggle waybar visibility." That's correct (since `$mainMod = ALT`), but during today's session I misread it. The doc would be less ambiguous if it used `$mainMod` or `Super` consistently with what the bindings file uses. Cosmetic, not blocking anything.

### R4: Firefox install gap, slow startup, theme drift

Three related concerns Caramel raised 2026-05-18:

**R4a: Install automation gap (known regression).** `plans/native-migration-audit.md` line 39 explicitly marks `install_specials` as ❌ missing in the native port:

> install_specials | ❌ missing | Firefox CSS deploy + user.js pref + restart, Cursor/VS Code extension package, Bat cache rebuild, Gemini settings jq-merge. **No native equivalent.**

This means the Firefox CSS theme + `user.js` prefs are NOT deployed by `fox-install`. User has to do those steps manually. Fix: port `install_specials` to a native `src/fox-install/modules/specials.cpp`, register in `modules.def`. Likely produces several distinct modules — Firefox is one, Cursor/VS Code extension is another, Bat cache another, Gemini jq-merge another. Could become a `firefox`, `editor_extensions`, `bat_cache`, `gemini_settings` set of modules.

**R4b: Slow startup — needs investigation, not blind fixing.** Symptoms: Firefox takes "a while" to launch. Real causes vary widely:
- Extension load (count + which ones)
- Profile bloat (history DB > 100MB, places.sqlite fragmentation, large `storage/` dir)
- Update-ping at startup (network round-trip to addons.mozilla.org + Mozilla telemetry)
- GTK theme load time
- dconf / fontconfig cache warm-up
- Wayland startup path on first launch

Investigation steps before any fix:
1. `firefox -profile-manager` → check profile count + size
2. `du -sh ~/.mozilla/firefox/*default*/` → look for obvious bloat
3. Time a clean-profile startup (`firefox -no-remote -profile $(mktemp -d)`) vs current — isolates profile-related slowness vs system slowness
4. `strace -fe trace=openat -c firefox` (briefly) to see if it's stuck waiting on something
5. Check `about:performance` after launch for extension cost

Fix is whatever the investigation surfaces — could be "kill an extension," could be "vacuum places.sqlite," could be "disable telemetry network call." No fix until cause is identified.

**R4c: Theme drift.** `templates/firefox/` exists; whether it still matches the broader FoxML_Classic aesthetic depends on what's drifted since the templates were last touched. Audit pass: render the current Firefox CSS, screenshot the chrome, compare to waybar/rofi/dunst styling for cohesion. Likely outputs: a list of color/border/spacing tweaks to bring it back in line.

**Suggested grouping:** R4a is a regression and a real bug — should be a near-term fix (folds naturally into phase 6 state-driven installer rebuild, since it's exactly the "feels broken/manual" complaint surface). R4b is an investigation, not a slice — outcomes determine whether anything ships. R4c is a small theme-polish slice once the install part works (no point polishing CSS that doesn't deploy).

### R5: Hyprland live-state drift reconciliation

**Symptom (Caramel, 2026-05-18):** Today's blur was stuck at `size=12, passes=4` despite the active hyprland.conf declaring nothing for blur — it inherited whatever a previous `hyprctl keyword` call left in memory. Ghost-mode was the proximate bug, but the broader pattern (any tool that touches `hyprctl keyword` can leak state with no reconciliation) is a class problem.

**Mechanism:**
- Hyprland keeps two sources of truth: the declared config (parsed from files at startup or `hyprctl reload`) and the live in-memory state (mutated by `hyprctl keyword` calls).
- These can diverge silently. There's no mechanism that says "after toggle script X exits, restore declared state."

**Proposed fix tiers:**
1. **`fox sys reconcile`** — one-shot command that runs `hyprctl reload` and re-applies declared theme. User runs after toggling something that went weird. ~5 min impl.
2. **Systemd user unit on `graphical-session.target`** that runs `fox sys reconcile` once at login. Catches any state that survived a logout (it shouldn't, but defense-in-depth). ~30 min impl.
3. **Declared-vs-live audit subcommand** (`fox sys audit-live`) that diffs current `hyprctl getoption` output against what config files declare, flags drift. Useful for diagnosis. ~1 hr impl.

**Decision needed:** Probably ship tier 1 + 2 together. Tier 3 is a "nice when debugging" diagnostic.

### R6: Toggle-script audit (ghost-mode-shape bugs in OTHER toggles)

**Hypothesis:** "Set state on entry, forget to fully restore on exit" is a class of bug, not a one-off. Today's ghost-mode bug had exactly this shape (set blur to 12/4, the OFF path forgot to restore size/passes). Other scripts with the same toggle-on / toggle-off structure are candidates:

| Script              | Toggle pattern                                                | Audit priority |
| ------------------- | ------------------------------------------------------------- | -------------- |
| `fox-cafe`          | Café Mode: tightens security posture on entry, restores on exit | High           |
| `fox-arm` / `fox-harden` | Arms hardening profile, optionally reverts                    | High           |
| `fox-develop`       | Toggles dev mode for live theme iteration                     | High           |
| `fox-theme-tweak`   | Live-updates aesthetic vars                                   | Medium         |
| `fox-cafe` (already listed) — duplicate, ignore           |                                                               |                |
| Any other `*-mode` script | TBD — full audit                                              | Medium         |

**Audit method:** For each script with an on/off toggle:
1. Extract the "ON" set of `hyprctl keyword` / `systemctl` / similar mutating calls
2. Extract the "OFF" set
3. Set-diff: any key in ON that doesn't appear in OFF is a leak candidate
4. Manually confirm whether each leak is intentional (e.g., "we permanently set X, don't restore") or a bug

**Output:** Per-script bug list + fixes. Likely produces several PRs of the same shape as today's ghost-mode fix.

### R7: Keybind collision audit

**Symptom (Caramel, 2026-05-18):** Alt+G was bound to BOTH `togglegroup` AND `exec ghost-mode.sh`. Hyprland fires both on keypress, producing the "blur creeps up + groupbar appears + waybar disappears" cascade. Already fixed (removed togglegroup since unused). Alt+Shift+G has a SECOND known dual-bind (`togglefloating` + `centerwindow`) — confirmed intentional by Caramel (the combo composes).

**Hypothesis:** There may be other unintentional collisions hidden in `~/.config/hypr/modules/keybinds.conf` (~160+ lines).

**Audit method:** A 10-line script that parses keybinds.conf, groups by `(modifier, key)` tuple, prints any tuple with multiple actions:

```bash
grep -E "^bind\s*=" ~/.config/hypr/modules/keybinds.conf \
  | awk -F, '{print $1","$2}' \
  | sort | uniq -c | awk '$1 > 1'
```

For each multi-bind: confirm intentional (compose case) or flag as bug. ~30 min total.

**Future-proofing:** Could become a `fox sys audit-keybinds` subcommand that runs as part of `fox sys reconcile` or `make lint`. Permanent gate against future collisions.

### R8: Tmux session/window garbage collection

**Symptom (Caramel, 2026-05-18):** Tmux session "49" visible — implies 49+ sessions have been created in the lifetime of the current tmux server, many likely stale (popped sessions from `bind m` workflow, abandoned terminal contexts). Tmux doesn't auto-clean. Stated as "really annoying but kind of minor."

**Proposed:** `fox dev tmux-gc` (or `fox sys tmux-gc`) subcommand:
- Lists sessions with last-activity timestamps
- Default mode (`fox dev tmux-gc`): interactive — show stale sessions (no clients attached + idle >N hours), prompt to kill batch
- Aggressive mode (`fox dev tmux-gc --auto --older-than 24h`): non-interactive, kill anything matching
- Optional systemd timer: weekly auto-gc of empty sessions (configurable)

Implementation: bash one-pager wrapping `tmux list-sessions -F '#{session_name} #{session_attached} #{session_activity}'`. ~30 lines, fits R-section work, doesn't need to be C++ (per D9).

### R9: RECOVERY.md verification

**Background (memory):** Caramel has previously hit the `pam_fprintd` sudo lockout — `/etc/pam.d/sudo` line 1 placing `pam_fprintd` before faillock preauth → password "eaten" by faillock → account locks. Bypass: touch reader. Recovery: `su -`, `faillock --reset <user>`, restore `.foxml-bak`.

**Task:** Audit `RECOVERY.md` (repo root) to confirm:
1. ✅ The pam_fprintd lockout scenario is documented with the exact recovery steps (bypass + recovery commands literal, not paraphrased)
2. ✅ Other known recovery scenarios are covered (look in saved memory + `plans/` for incidents)
3. ✅ The doc is structured so under-pressure-Caramel can find the right section in 30 seconds (table of contents, problem → fix format)
4. ✅ No assumption of working `sudo` in any step (the doc is only consulted when `sudo` is broken)

**Output:** A short PR updating RECOVERY.md, OR a confirmation that it's already good. Either way, log the audit date in the doc footer.

### R10: Readability audit (inactive panes + muted palette values)

**Symptom (Caramel, 2026-05-18):** Inactive tmux panes are hard to read. Comments in nvim, muted output in bat/help-text, and similar low-contrast text become near-invisible — especially noticeable when running claude-code in tmux while viewing other panes for reference.

**Two distinct mechanisms compound:**

**M1 — tmux actively dims inactive panes.** `~/.tmux.conf:43-44`:
```tmux
set -g window-style        'fg=#3a3a3a,bg=default'
set -g window-active-style 'fg=#c4b4a0,bg=default'
```
The inactive fg `#3a3a3a` is dark gray-on-dark-bg with transparent kitty bg (`KITTY_BG_OPACITY=0.6`) + wallpaper showing through. Default-fg text in inactive panes effectively disappears.

**M2 — comment / muted palette values are low-contrast at baseline.** From `themes/FoxML_Classic/palette.sh`:
```
BG=1a1214            # near-black plum
COMMENT=5a6270       # dark blue-slate
FG_DIM=7a7a7a        # medium gray
```
`COMMENT` against `BG` at 100% opacity is already at the edge of WCAG AA. At 0.6 opacity with wallpaper bleed-through, contrast drops below readable. In tmux's inactive pane (M1) these stack — invisible.

**Affected surfaces:** tmux inactive panes, nvim comment color, bat/cat with syntax highlighting, fzf preview pane, any TUI using palette muted colors, possibly hyprlock muted text.

**Caramel clarification (2026-05-18):** Want to *read* the unfocused pane without switching to it, but still want clear visual differentiation between focused and unfocused. Goal is "loosen the dimming," not "remove dimming."

**Further clarification (2026-05-18):** Specifically, *syntax-highlighted code in bat/nvim is fine* in inactive panes — it uses explicit bright ANSI colors that survive the dimming. The problem is **comments** (which use the low-contrast COMMENT palette value) and **plain text** (which uses terminal default fg, killed by `window-style fg=#3a3a3a`). Practical impact: when claude-code is running in one pane telling Caramel to run a command, she has to switch panes or squint to read the command — degrading the actual usefulness of multi-pane work with an AI assistant. This is the load-bearing user-impact framing for R10.

**Two-mechanism diagnostic confirmed:**
- M1 (tmux dim of default-fg) → kills *plain text*. Affects claude-code output, shell prompts, help text, anything not explicitly ANSI-colored. **Fix: tier 1a/1b below.**
- M2 (low-contrast COMMENT) → kills *comments specifically*. Affects nvim/bat/cat with syntax highlight. **Fix: tier 2 below.**

The two fixes are independent and address different symptoms — both needed for full repair, but tier 1 alone fixes the "Claude told me to run X and I can't read it" case (highest immediate value).

**Fix tiers:**

1. **Loosen tmux dimming — keep differentiation, restore readability.** Two complementary levers, can apply either or both:

   **1a — Brighten inactive fg.** `window-style 'fg=#3a3a3a'` → `'fg=#8a7d70'`. Warm dim gray that picks up the palette's earthy tone. Readable on dark bg even with wallpaper bleed, but still visibly dimmer than the active pane's `#c4b4a0` beige. RGB sums: active 536, current inactive 174, target inactive 375 — restores ~70% of active brightness without matching it.

   **1b — Add subtle bg fill to inactive panes only.** `window-style 'fg=#8a7d70,bg=#0d0808'`. Active pane stays transparent (sees wallpaper); inactive pane gets a near-black plum solid bg so wallpaper bleed-through stops fighting the text. Differentiation becomes: **active = alive/transparent, inactive = solid/quiet**. Counterintuitive at first (you'd expect the focused thing to be more solid) but works because the focused pane needs no extra signaling — cursor + border + active-fg already mark it — while the unfocused pane benefits from maximum text contrast.

   **Recommendation:** Apply 1a + 1b together. Restores readability AND strengthens the active/inactive visual story rather than just weakening it.

2. **Brighten muted palette values.** `COMMENT` `#5a6270` → `#7d8290` (still muted but readable on dark bg, even at 0.6 opacity with bleed). `FG_DIM` similar bump. Update across all themes (Classic + Cave_Data_Center; Paper is light-on-light so different math applies). Render + reload.

3. **Audit transparent-bg contrast as a permanent rule.** Add a check to `make lint-palette` (D10) that flags any palette value where contrast against BG at the theme's stated `KITTY_BG_OPACITY` falls below a threshold (e.g., WCAG AA 4.5:1). Prevents regression.

**Tier 1 alone solves the immediate "I can't read the other pane" problem in <1 min.** Tier 2 makes comments readable everywhere. Tier 3 prevents the issue from creeping back.

### R11: Screenshot workflow — split quick-capture from edit-with-tools

**Symptom (Caramel, 2026-05-18):** Current `Mod+Shift+O` always launches the swappy editor after capture. Swappy takes ~1 second to close after save (GTK shutdown + image encoding), so every screenshot has a built-in delay even when no annotation is needed. Caramel wants two distinct keybinds:

- **`Mod+Shift+O`** → quick capture, no editor, straight to file + clipboard (fast path, becomes the default)
- **`Mod+Shift+P`** → capture and open in swappy for annotation (slow path, opt-in)

**Current state** (`~/.config/hypr/scripts/screenshot.sh`):
```bash
slurp → grim → swappy → wl-copy → notify
```

**Proposed** — one script, mode flag, two keybinds. DRY but explicit:

```bash
# ~/.config/hypr/scripts/screenshot.sh
mode="${1:-quick}"  # 'quick' or 'edit'
geom=$(slurp -b 00000000 -c c4956eff 2>/dev/null) || exit 0
[[ -z "$geom" ]] && { notify-send -t 2000 "Screenshot" "Cancelled"; exit 0; }
file="$HOME/Pictures/Screenshots/screenshot-$(date +%Y%m%d-%H%M%S).png"
mkdir -p "$(dirname "$file")"

if [[ "$mode" == "edit" ]]; then
    grim -g "$geom" - | swappy -f - -o "$file"
else
    grim -g "$geom" "$file"
fi

[[ -f "$file" ]] && wl-copy --type image/png < "$file" && \
    notify-send -i "$file" "Screenshot saved" "File: $(basename "$file")"
```

**Keybind change** (`~/.config/hypr/modules/keybinds.conf`):
```
bind = $mainMod SHIFT, O, exec, ~/.config/hypr/scripts/screenshot.sh quick
bind = $mainMod SHIFT, P, exec, ~/.config/hypr/scripts/screenshot.sh edit
```

**Conflict to resolve:** `Mod+Shift+P` is currently bound to `hyprpicker -a` (color picker). Two options, Caramel call:

- **Option A:** Move hyprpicker to a less-trafficked combo (e.g., `Mod+Shift+C` for "color" — currently free per quick check). Frees P for screenshot-edit per Caramel's proposal.
- **Option B:** Keep hyprpicker on `Mod+Shift+P`, use a different combo for screenshot-edit (e.g., `Mod+Shift+E` for "edit"). Hyprpicker stays where muscle memory expects it.

**Lower-priority polish (could fold into same slice):**
- The 1-second swappy lag is partly unavoidable (GTK init) but can be hidden by closing the swappy window before the file fully flushes (race-condition-y, skip)
- Alternative editors that are faster: `satty` (Rust, sub-100ms cold start), but introduces a new dep — only worth it if swappy continues to feel slow after the split

**Scope:** Phase 7 (substantial bash ports) territory — but this script is ~30 lines so it stays bash per D9. Just a config edit + script tweak. Could land independently as a small PR outside the dispatcher refactor.

### R12: Conditional power profiles (perf module — battery/AC/temperature-aware)

**Symptom (Caramel, 2026-05-18):** The `perf` module's CPU throttling step lets you set a single max-freq cap (e.g., 2500 MHz), Intel turbo on/off, and governor. But real-world need is *conditional*: cap higher when plugged in, lower on battery, throttle when CPU is hot. Currently no way to express this through the installer — it's a one-shot single-value configuration.

**Concrete request (verbatim, 2026-05-18):** "allowed to configure the actual voltage caps that are in the settings for like performance, when on battery, when plugged in etc? like the 45 when plugged in, 35 when not, 45 when under X temp?"

**Mechanism options:**

1. **TLP** (Arch: `tlp`, `tlp-rdw`) — mature, has per-power-state config (`CPU_MAX_PERF_ON_AC`, `CPU_MAX_PERF_ON_BAT`, etc.), already a standard tool. Probably the right backend.
2. **auto-cpufreq** — alternative, also opt-in, more aggressive auto-adjustment. Less granular than TLP for power-state-specific caps.
3. **`throttled`** (already mentioned in the perf module per the screenshot) — ThinkPad-specific, MSR-based undervolting + thermal cap. Doesn't address power-state-conditional behavior on its own.
4. **Custom systemd-on-power-source-change** — write own scripts triggered by `udevadm monitor` for AC plug/unplug. DIY, full control, more code.

**Recommended:** TLP as the primary mechanism, exposed through the perf module config phase as a structured prompt:

```
╭─ Power profile setup ──────────────────────────────────────────╮
│ AC (plugged in):                                               │
│   Max CPU freq:        2500 MHz [adjust]                       │
│   Governor:            performance                              │
│   Intel turbo:         on                                       │
│                                                                 │
│ Battery:                                                        │
│   Max CPU freq:        2000 MHz [adjust]                       │
│   Governor:            powersave                                │
│   Intel turbo:         off                                      │
│                                                                 │
│ Thermal cap (regardless of power source):                       │
│   Throttle when temp ≥ 85°C: yes                                │
╰─────────────────────────────────────────────────────────────────╯
```

The installer translates this into TLP config + `throttled.conf` (for ThinkPad) atomically. Per the D11 wizard model, this is a single config-phase step with structured options, not a string of Y/N prompts.

**Fits naturally with D11's state-aware repair-mode:** Once profiles are set, `fox install --full` verifies TLP is still configured and active, reapplies if drifted. Profile values are part of the install manifest, so they survive across machines + sync via the state file.

**Scope:** Folds into Phase 6 (state-driven installer rebuild) as part of the perf-module redesign, OR can land separately as a perf-module-only update. Caramel's call.

### R13: Custom archiso integration — ensure `distro/` chains into fox sys install

**Context (Caramel, 2026-05-18):** The repo already has a `distro/` directory and `fox-distro-build` / `fox-distro-flash` tools. The end-state Caramel wants: boot from FoxML archiso USB → run standard Arch installation → final step automatically chains into `fox sys install --full`. Result: cold-boot to working FoxML desktop with zero manual download / clone / build steps.

**Today's state (needs verification, no audit done yet):**
- `fox-distro-build` exists but unknown if it bakes FoxML into the ISO or just produces vanilla Arch
- `fox-distro-flash` exists for the USB writing step
- archiso post-install hook integration: unknown if wired up
- Compatibility with the new state-driven model (D11 + D18): definitely needs reverification once Phase 6 lands

**Per-slice work needed:**

1. **Audit current `distro/` state** — read `fox-distro-build` source, identify what's actually in the ISO today and how it integrates (if at all) with first-boot.
2. **Decide ISO content model:**
   - **Light:** ISO is vanilla archiso + a post-install hook that runs the curl bootstrap (channel A from D18). Smallest ISO, requires network at install time.
   - **Heavy:** ISO ships FoxML source + native binaries pre-built. No network needed for install; first run is offline. ~500MB-1GB ISO.
   - **Hybrid:** ISO ships bootstrap + offline mirror of the most critical packages (base, Hyprland, fonts). Falls back to network for the rest.
3. **Wire archiso post-install hook** to chain into `fox sys install --full` (with `--bootstrap-mode` flag that knows it's running fresh-install context, picks appropriate defaults).
4. **Test on a real fresh boot** in a VM — boot ISO, run Arch installer, verify chain works, verify deferred-graphical handoff (per D18) on first reboot into Hyprland.

**Dependencies:** Blocked on Phase 6 landing (state-driven installer + bootstrap channels) — no point integrating the distro with the OLD install model that's about to be replaced.

**Why important:** The custom-distro use case is what makes FoxML deployable as a *product*, not just a config repo someone clones. For Caramel's audience (silent hedge fund tracking + community discovery), having "download our ISO, boot, you're done" as the easy path is a meaningful step beyond "clone our repo and follow these 12 setup steps."

**Slice ordering:** R13 work happens AFTER Phase 6 lands. Add as Phase 6.5 or a deferred Phase 12, Caramel's call.

### R14: Preflight boot-partition free-space math bug

**Symptom (Caramel, 2026-05-18):** The preflight check reports boot-partition free space incorrectly. Concrete number not provided but Caramel flagged that the math is wrong somewhere.

**Where to look:** `src/fox-install/modules/preflight.cpp` (or wherever the preflight output in the screenshot — `$HOME free / / free / /boot capacity 1021 MB (775 MB free)` — is generated). Likely culprits:
- Unit mix-up (MB vs MiB, bytes vs KB at intermediate step)
- `statvfs` field misread (`f_bavail` vs `f_bfree` — the first excludes blocks reserved for root)
- Subtraction order error (used = total - free, vs free = total - used)
- Integer overflow on a 32-bit count of large blocks

**Audit method:**
1. Compare reported numbers against `df -h /boot` and `df -h /` on the same system
2. Trace the calculation in source
3. Fix + add a regression test that mocks `statvfs` with known values

**Scope:** Small bug fix, ~30 min once located. Can land independently of the dispatcher refactor (won't conflict). Belongs in Phase 6 if not fixed sooner — the preflight module is one of the first things the user sees, looking wrong undermines trust in everything downstream.

### R15: No user feedback during bootstrap-compile phase

**Symptom (Caramel, 2026-05-18):** When running `install.sh` on a fresh system (or after pulling updates), the script asks for sudo password, then **appears to hang silently** while compiling C++ binaries. User sees "sudo: ..." prompt → enters password → terminal sits with no output for seconds-to-minutes. Looks broken — user can't tell if it's working or wedged.

**Cause:** The bootstrap wrapper (`install.sh`) runs `make -C src/fox-install` before exec'ing the binary. `make` is mostly silent unless something fails, and during a clean build the C++ compile of ~50 module files + linking takes 10-60s depending on the machine. No progress message bridges sudo → exec.

**Fix (cheap):** Add explicit progress message before the build step:

```bash
echo "Compiling FoxML installer (this takes 10-60s on first run)..."
make -C src/fox-install 2>&1 | tee -a "$LOG"
echo "Build complete, starting installer..."
```

Even one printed line bridges the silence. Optionally pipe make output through a filter that shows file-by-file progress (`make -j8 V=1 | grep -E '^Compiling|^Linking'`).

**Fix (better):** During the dispatcher refactor (D18 bootstrap.sh redesign), the bootstrap shows a one-line progress: `[compiling: 23/47 module files]`. Doable with awk over make's output.

**Fix (best):** Ship pre-built native binaries in the GitHub release. Bootstrap downloads pre-built binary if the architecture matches, falls back to source build only if no prebuilt is available. Removes the compile time entirely for the common case (x86_64 Arch). Bigger change but Phase 6+ scope.

**Why it matters:** First-impression UX. A user who types `curl ... | bash` and sees terminal silence for 60 seconds thinks the script crashed. Even the cheap fix (one echo line) prevents this.

**Scope:** Trivial fix (cheap version) can land now, independent of refactor. Better/best versions land with Phase 6 (D18 bootstrap redesign).

### R16: tmux text-duplication-across-panes (`synchronize-panes` accidental trigger)

**Symptom (Caramel, 2026-05-18):** "Sometimes when I type in one tmux pane, it duplicates the text across multiple panes — really annoying."

**Root cause:** `~/.tmux.conf:94` has `bind e setw synchronize-panes` — tmux's "broadcast typing to all panes in this window" mode toggle. With `prefix = C-a` (line 68), accidental `Ctrl-A e` (e.g., typo when meaning Ctrl-A + something else, or hitting prefix while reaching for a different key) silently enables synchronize-panes for the window. No visual indicator. Every subsequent keystroke fires in every pane until toggled off.

**Why it's hard to notice and easy to trigger:**
- `e` is adjacent to common prefix-followed keys (`w` for windows list, `d` for detach)
- No status bar (`set -g status off` on line 33), so the standard sync-on indicator (typically shown in status line) isn't visible
- No notification when sync state changes

**Fix tiers:**

1. **Move binding to a less-collision-prone key.** E.g., `bind S setw synchronize-panes` (capital S, less likely accidental than lowercase e). Trivial one-line change.
2. **Add a visible indicator in the pane border format** (D11/tmux border) — when sync is on, all pane borders glow red (or similar) so it's immediately visible. Modify `pane-border-format` to include `#{?synchronize-panes,#[fg=red]⚠ SYNC ON ,}`.
3. **Both.** Move binding AND add indicator. Belt + suspenders.

**Recommended:** #3. Trivial cost (two-line change in `.tmux.conf`), eliminates the recurring annoyance entirely.

**Scope:** Tiny config edit. Could land independent of the dispatcher refactor as a one-PR fix. Pairs nicely with R7 (keybind collision audit) — both are "this binding is too easy to trigger by accident" class problems.

### R17: Install lockfile (concurrency safety)

**Problem:** Today's `fox-install` has no mutex against itself. Two invocations racing (terminal opens twice + autorun, systemd-on-graphical fires while user re-runs manually, anaconda hook + manual install, etc.) can interleave file deploys + state writes → corrupt install state.

**Fix:** `flock(LOCK_EX)` on `/run/foxml-install.lock` (or `~/.local/run/foxml-install.lock` for non-root invocations). Second invocation either waits or fails fast with a clear message ("Another fox install is running, started at TIME, PID N. Wait or kill?").

**Scope:** ~30 lines in `src/fox-install/main.cpp` (or `src/fox/main.cpp` post-refactor). Lands in Phase 6 by default; could be added earlier as a one-off if Caramel hits a race in the meantime.

### R18: Diagnostic bundle (`fox sys diag`)

**Goal:** Single command that produces a paste-able dump of system + FoxML state for debugging. Useful when something breaks: "share the output of `fox sys diag`" replaces ad-hoc "run these 12 commands and paste each one."

**Bundle contents:**
- Hardware: lspci, lsusb, GPU, chassis, monitor topology
- Compositor: `hyprctl getoption` tree, `hyprctl monitors`, `hyprctl layers`
- FoxML state: install-state.json (per D11), active theme, fox-vault status (no contents!), last N entries from each D14 log
- System: kernel version, systemd-failed units, recent `journalctl -p err`
- Tool versions: every fox-* binary `--version` output
- Redacted: SSH host keys removed, vault contents NEVER included, `$HOME` paths anonymized to `~`

**Output:** Single markdown file `/tmp/foxml-diag-<timestamp>.md` (or `--clipboard` to wl-copy directly). Pastable to GitHub issue / Discord / chat.

**Scope:** ~200 lines, new `src/fox-sys/diag.cpp` post-refactor. Phase 6 ideally, or as a standalone phase. High value for support / self-debug.

### R19: Uninstall coverage audit

**Question:** `fox-uninstall` exists per binary list. Does it actually undo everything?

**Audit method:**
1. Snapshot system state (file hashes, enabled services, installed packages) on a clean Arch VM
2. Run full `fox install --full`
3. Diff system state — record everything FoxML touched
4. Run `fox-uninstall`
5. Diff again — record what got removed
6. Compare lists: anything in (3) not undone by (5) = gap in uninstaller

**Expected gaps (best guess pre-audit):**
- Packages installed via pacman aren't removed (uninstall ≠ package purge)
- Services enabled aren't disabled
- AUR builds aren't cleaned up
- Vault state in `~/.local/share/foxml/` may persist

**Output:** Either confirmation that `fox-uninstall` is complete OR a list of gaps + decision per gap (fix uninstaller / document as intentional / move to a `fox sys purge --everything` mode).

**Scope:** ~half-day audit + however much patching the gaps takes. Phase 6+ territory.

### R20: Hyprland config validation gate (`fox theme validate`)

**Problem:** Editing `~/.config/hypr/modules/keybinds.conf` (or any sourced file) and reloading puts you one syntax error away from a broken session. No pre-reload syntax check.

**Fix:** `fox theme validate` (or `fox sys validate-hypr`) that:
1. Spawns a temporary Hyprland instance with a virtual headless backend
2. Loads the config files
3. Captures any parse errors
4. Reports without affecting your live session

Alternatively (cheaper): `hyprctl reload --dry-run` if Hyprland supports it (need to verify). If it does, fox theme validate is a one-line wrapper.

**Scope:** Depends on which Hyprland feature works. Cheap if `--dry-run` exists, ~half-day if we need the headless-spawn approach. Phase 4 (`fox theme` namespace) territory.

### R21: Theme hot-preview (live palette iteration)

**Problem:** Today, changing a palette value requires render → reload-each-app → see effect. Slow iteration loop for aesthetic work. Caramel hits this often (every "is this blush color right?" requires the full cycle).

**Fix:** `fox theme preview <var>=<value>` that:
- Writes a single overridden palette value to a temp file
- Re-renders only the affected templates
- Soft-reloads (or signals) only the affected running apps
- After 30s without confirmation, reverts automatically (no permanent damage from a typo)

**Bonus mode:** `fox theme preview --interactive` opens a TUI palette editor where you arrow through values, see live changes, commit-or-revert on exit.

**Connects to:** The deferred TUI color selector idea Caramel mentioned. R21 IS that, basically — keeping it deferred unless preview ergonomics drive it earlier.

**Scope:** Phase 4 (`fox theme` namespace). Medium lift — needs to know which apps care about which palette keys (already implicit in templates/<app>/ structure). Real value for aesthetic iteration days.

### R22: Tmux session naming convention (slug-from-cwd)

**Problem:** Tmux assigns sequential names ("0", "1", ..., "49") when you don't pass `-s`. Caramel's `bind m` (pop-pane-to-session) currently uses `pop-${cmd}-$$`. Result: lots of `pop-zsh-12345`, `pop-nvim-67890` sessions accumulating.

**Fix:** Default session naming uses slug of current directory (or git repo name if in a repo). So sessions read as `Linux_Theme`, `tick_trader`, `FoxML_Trader_v2` — semantic and memorable.

**Implementation:** Add a tmux hook on `session-created` that renames if the name matches the default pattern. Plus update `bind m` / `bind M` per earlier work.

**Pairs with R8 (tmux session gc):** Named sessions make the gc more meaningful — "killing 5 sessions for repos I haven't touched in a month" beats "killing 5 sessions named 17, 23, 41, 42, 49."

**Scope:** Tiny — ~10 lines in `~/.tmux.conf`. Independent of refactor.

### R23: Pre-commit hook for fox-ai-review

**Status:** `fox-ai-review` exists per binary list, per CLAUDE.md it "emits BLOCK / WARN / OK lines, exits non-zero on BLOCK — wire as pre-commit hook." Need to confirm whether it's *actually wired up* in this repo.

**Audit:**
1. Check `.git/hooks/pre-commit` — does it call fox-ai-review?
2. If not, install it via `fox dev init` (or equivalent)
3. Add `core.hooksPath` config so the hook ships with the repo (not just per-clone)
4. Document the bypass (`--no-verify`) for genuine emergencies and the policy ("don't bypass except for hot fixes")

**Scope:** ~5 min if just an install step. ~30 min if we need to add proper hooks-shipped-with-repo infrastructure. Phase 9 (docs + CI) territory.

### R24: (deferred) TUI color picker for live palette editing

**Status:** Mentioned by Caramel as a "maybe defer" idea (2026-05-18). Captured for future consideration; not on near-term roadmap.

**Vision:** Interactive TUI that shows the current palette, lets you arrow through colors, opens an HSL/RGB editor on Enter, previews changes live across running apps (via R21 mechanism), commits or discards on exit.

**Why deferred:** Real value only kicks in if palette editing happens often. Currently aesthetic iteration is infrequent enough that R21's CLI hot-preview probably covers 90% of the need. Revisit if/when aesthetic work cadence picks up.

**Pre-reqs:** R21 (theme hot-preview) must exist first — R24 is fundamentally a TUI front-end on R21's mechanism.

### R25: Claude Code TUI theme alignment with FoxML

**Ask (Caramel, 2026-05-18):** Make Claude Code's interface match the active FoxML theme (peach/blush for Classic, paper-tones for Paper, etc.) so the AI-assistant context feels native to the desktop rather than visually disconnected.

**Surface inventory (needs verification — Claude Code theming is more limited than full app theming):**
- Built-in themes: `dark`, `light`, `dark-daltonized`, `light-daltonized`, `dark-ansi`, `light-ansi` — selectable via `/config` or `theme` key in `~/.claude/settings.json`
- Custom color overrides: unclear if Claude Code supports per-key color customization beyond preset selection. Worth investigating before scoping.
- Status line: configurable via `statusline-setup` (see Caramel's available skills) — colors + content controllable.

**Likely deliverable shape (best-effort, scope-dependent on what Claude Code actually exposes):**
1. **At minimum:** add a `templates/claude/` directory with a `settings.json.tmpl` that sets `theme` to whichever built-in preset is closest to the active FoxML palette (Classic → `dark-ansi` probably; Paper → `light-ansi`). Render swaps it on theme change.
2. **If custom colors are supported:** template the actual hex values so Classic uses peach, Paper uses paper-tones, etc.
3. **Statusline tweak:** configure Claude Code's status line via `statusline-setup` to show FoxML-relevant info (active theme, current tmux session, git branch) in palette colors.

**Investigation needed before authoring slice:**
- Read Claude Code's docs (or `~/.claude/settings.json` schema) for the actual theming surface
- Test what changing `theme` key does (apply → reload Claude Code → see effect)
- Confirm whether settings.json supports color overrides or just preset selection

**Scope:** Small — ~1-2 hours including investigation. Phase 4 (`fox theme` namespace) or standalone. The bigger value is the *integration story*: "swap FoxML theme → everything follows, including the AI assistant pane" — cohesion across the whole desktop including the tools running inside it.

**Theme-update angle Caramel mentioned:** The FoxML_Classic palette was designed with the assumption of opaque BG. With `KITTY_BG_OPACITY=0.6` and a green-forest wallpaper, certain muted colors drift toward invisible. Either bump palette values for transparent compatibility, OR raise opacity to 0.75-0.8 for Classic (preserves the wallpaper feel without crushing low-contrast text). Tradeoff between aesthetic and readability — Caramel call.

## Status & Sign-off

- **Master plan written:** 2026-05-18
- **Design approved:** *pending Caramel review of this document*
- **Phase 1 subplan authored:** *not yet*
- **First commit:** *not yet*
