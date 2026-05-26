# Linux_Theme — Agent Mandates

Persistent context for AI assistants working on this repo. Project-specific rules; supplements [`CLAUDE.md`](CLAUDE.md), [`INVARIANTS.md`](INVARIANTS.md), and [`RECOVERY.md`](RECOVERY.md).

## What this repo is

Native C++ install orchestrator (`fox-install`) + AI tooling layer (`libfox-intel.a` + six `fox-ai-*` tools) + theme-driven dotfiles for ~25 apps, targeting Arch Linux + Hyprland.

Install logic is **not** in `install.sh` — that's a 90-line wrapper. Every install step is a `void run_X(Context&)` function under `src/fox-install/modules/`, registered via the X-macro in `core/modules.def`. The args parser, `--help`, dry-run plan, dispatcher, and registry test all derive from that single file.

## Core mandates

- **Don't add to `install.sh` or `mappings.sh`.** New install logic is a new module under `src/fox-install/modules/` plus one line in `core/modules.def`. `mappings.sh` survives only because three runtime Hyprland helper scripts source it.
- **Subprocess goes through `sh::`.** No `system()` / `popen()` outside `core/shell.cpp`. Use `sh::run`, `sh::capture`, `sh::pacman`, `sh::systemctl_enable`, `sh::sudo_warmup`. `--dry-run` and logging are centralized there.
- **Atomic file writes.** Write to `tmp + rename`. Never write-in-place. For directories, `std::filesystem::create_directories` (no `mkdir -p` shellouts).
- **Backups before overwrites.** The `symlinks` module snapshots existing files into `ctx.backup_dir` (`~/.foxml-bak/<timestamp>/`) before replacing them. Don't bypass this — `deploy_file` and `deploy_dir` in `modules/symlinks.cpp` already handle it.
- **Path agnosticism.** Use `ctx.home`, `ctx.config_home`, `ctx.script_dir`. No hardcoded `/home/<user>` strings.
- **Hyprland v0.54+.** Unified `windowrule` keyword and `col.active_border` property only. `windowrulev2` and `bordercolor` will silently break the theme.
- **No exceptions in hot paths.** Return codes or `std::optional`. Modules that throw won't get the per-module progress bar's failure handling.
- **Comments explain *why*, not *what*.** No multi-paragraph docstrings; function names already say what. Save sentences for non-obvious invariants and surprising workarounds.
- **Commits ≠ releases.** Don't bump `CHANGELOG.md` version numbers or cut a git tag just because a fix landed. Push fixes to `main` freely — they accumulate as "next release" content at the top of `CHANGELOG.md`. Tag + release only when there's a meaningful chunk users would benefit from (~every 2-4 weeks, not every PR). The project has thousands of users tracking tags; bumping after every commit batch is churn for them. If you're authoring a CHANGELOG entry, write it as if a release is imminent but do NOT pick a version number or `git tag` unless explicitly asked.

## Adding a module

```cpp
// src/fox-install/modules/foo.cpp
#include "../core/context.hpp"
#include "../core/shell.hpp"
#include "../core/ui.hpp"

namespace fox_install {
void run_foo(Context& ctx) {
    ui::section("Doing foo");
    sh::pacman({"some-pkg"});
    sh::systemctl_enable("some.service", /*user=*/false);
}
}  // namespace fox_install
```

Then one line in `src/fox-install/core/modules.def`:

```
FOX_MODULE( foo, run_foo, "--foo", "What foo does", false )
```

Rebuild. `--help`, `--foo`/`--no-foo` parsing, dry-run preview, and the dispatcher pick it up automatically. The registry sanity test (`src/fox-install/tests/test_registry.cpp`) will fail to link until you add a stub for `run_foo` there too — that's the enforcement.

## Adding an AI-flavoured tool

Pattern is identical across all six current `fox-ai-*` tools:

```cpp
#include "../fox-intel/fox_intel.hpp"

FoxIntel ai;
if (!ai.ensure_ollama_running()) return 1;

std::string prompt = "Diagnose: " + captured_context;
ai.ask(prompt, /*stream=*/true);
```

`libfox-intel.a` is the dependency. There is no plugin framework, no "AI module" base class. Capture context via short-lived `execvp` calls (`systemctl`, `journalctl`, `ufw`, `lspci`), build a focused prompt, stream the answer.

Embedding-backed RAG: `ai.get_embedding(text)` + `FoxIntel::cosine_similarity(a, b)`. Reference impl: `src/fox-intel/fask.cpp`.

## When to port shell → C++

Port when **one or more** apply:
- Frequently invoked (>1/sec or in Hyprland event hot path).
- Long-running daemon.
- Security-critical (secrets, kernel APIs, signing).
- Needs registry-based extensibility (more than a handful of modes).
- Complex parsing or data structures (templates, palettes, graphs, JSON).

**Leave alone** when the script orchestrates 2–3 commands once per user action — porting it buys verbosity, not perf.

## Reusable headers

Modules and tools share these by `#include`-ing them; never duplicate the functionality.

| Header | Provides |
|---|---|
| `src/fox-intel/fox_intel.hpp` | `FoxIntel.ask()`, embeddings, `cosine_similarity`, Ollama lifecycle. |
| `src/fox-install/core/ui.hpp` | Pacman-style `section` / `substep` / `ok` / `warn` / `err` / `progress` / `summary_row` / `ask_yn`. |
| `src/fox-install/core/shell.hpp` | `sh::run` / `capture` / `pacman` / `systemctl_*` / `sudo_warmup` + `set_dry_run`. |
| `src/fox-install/core/context.hpp` | Install state passed into every module: hardware flags, paths, theme name, global flags. |

## Theme rendering pipeline

```
templates/<app>/<file>    ─┐
                          │  fox-render-fast (or render.sh)
themes/<theme>/palette.sh ─┤  substitutes {{TOKEN}} → palette value
                          │
rendered/<app>/<file>     ─┘  staged output

symlinks module           ─┐  atomic deploy with backup_and_copy
                          │  → ~/.config/<app>/<file>
                          │
post_install module       ─┘  restart waybar / dunst / mako; nvim
                             Lazy + TSUpdateSync; Cursor / VS Code
                             colorTheme=Fox ML
```

Templates use `{{TOKEN}}` placeholders (e.g. `{{PRIMARY}}`, `{{BG_R}}`/`{{BG_G}}`/`{{BG_B}}` for rgb-split). The render engine is byte-identical to the old `render.sh`; both are in-tree until the bash one is removed.

`--render` implies `--symlinks` and `--post-install`, so `./install.sh --render` does the full render → deploy → live-reload cycle.

## Multi-monitor

The `monitors` module writes name-keyed Hyprland rules to `~/.config/hypr/modules/monitors.conf` and a sidecar at `~/.config/foxml/monitor-layout.conf`. Downstream consumers parse the sidecar — `start_waybar.sh` for per-bar config, `rotate_wallpaper.sh` for per-monitor wallpaper. **Parse, don't `source`**: the sidecar contains user-controlled monitor names and must never reach shell eval.

## What NOT to do

- Don't reintroduce centralized helper bash files. Bash that survives is small, scoped to one tool, called from a `fox-install` module.
- Don't add AI integration as a separate framework. It's `#include "fox_intel.hpp"` + `ai.ask()`.
- Don't add a feature-flag system for in-development C++ code. Compile it in, gate behind a CLI flag if needed, delete the flag when stable.
- Don't pre-fork registries or plugin loaders for features without at least three concrete callers.
- Don't add `mkdir -p` shell-outs. Use `std::filesystem::create_directories`.

## See also

- [CLAUDE.md](CLAUDE.md) — full architectural guide with worked examples
- [INVARIANTS.md](INVARIANTS.md) — load-bearing rules with explicit enforcement criteria
- [RECOVERY.md](RECOVERY.md) — what to do when an install bricks something (pam_fprintd sudo lockout, etc.)
- [CONTRIBUTING.md](CONTRIBUTING.md) — add-an-app and add-a-theme workflows
- [SECURITY.md](SECURITY.md) — threat model and hardening reasoning
- [TECHDEBT.md](TECHDEBT.md) — known issues and planned cleanups
