# Architecture and development

[← Back to the README](../README.md)

How templates, deployment and the native tools fit together.

## Native tools

`install.sh` handles self-updates, sudo and native builds, then runs `desk-install`. Each install step lives in a C++ module.

Native C++ tools under [`src/`](../src/):

| Tool | Role |
|---|---|
| `desk-install` | Install orchestrator driven by a shared module registry |
| `desk-intel` | `libdesk-intel.a` — local model client (llama.cpp's router) + embedding API; linked into every AI tool |
| `desk-render-fast` | Concurrent template engine; drop-in for the old `render.sh` |
| `desk-pulse` | Single-epoll daemon multiplexing Hyprland IPC + inotify + debouncers; runs the one-shot focus handler `~/.config/foxml/pulse.d/focus.sh`, which posts nothing by default since the bar already shows the workspace (the old `foxml-focus-pulse.service` is retired on upgrade) |
| `desk-vault` | `mlock()`-protected in-RAM secret store with Unix-socket CLI |
| `desk-ask`, `ai-doctor`, `ai-oracle`, `ai-snitch`, `ai-audit`, `ai-bouncer`, `ai-review`, `ai-swap` | One-shot AI tools that link `libdesk-intel.a` — pattern is `#include "desk_intel.hpp"` + `ai.ask(prompt)`. No plugin framework. |

The X-macro registry in `src/desk-install/core/modules.def` is the single source of truth for install modules. Each module is a `void run_foo(Context&)` function. Subprocess goes through `sh::run` / `sh::capture` / `sh::pacman` / `sh::systemctl_*` so `--dry-run` and logging stay centralized.

Bash handles small Hyprland event scripts and configuration capture.
`mappings.sh` remains a runtime helper for deployed scripts and `update.sh`.
The installer itself uses native modules; aider brings its own Python dependencies.

## How it works

```
templates/                 config files with {{PLACEHOLDER}} tokens
  kitty/kitty.conf         background #{{BG}}, foreground #{{PRIMARY}}, ...
  nvim/init.lua            colors with #{{RED}}, ...
  waybar/style.css         @define-color bg #{{BG}}, ...
  ...                      (application templates)
  foxml/ansi_colors.json   palette → libdesk-intel theme bridge

themes/
  FoxML_Classic/
    palette.sh             color and application variables
    theme.conf             name, type=dark, description

shared/                    non-color files copied as-is (keybinds, scripts)
src/                       C++ orchestrator + tools

install.sh                 wrapper → builds + execs desk-install
update.sh                  reverse-renders system configs → templates
swap.sh                    interactive theme switcher
```

A theme supplies `palette.sh` and `theme.conf`. Application colors render from
templates; shared files supply configuration that does not change with the palette.

## Build and verify

```bash
make
make test
```

The root Makefile discovers tools through `src/*/Makefile`. Each component supplies
its own build and optional test targets; `make test` also runs the script tests.
Use `make install` to copy the native tools into `~/.local/bin`.

## Extend the installer

Add a `void run_foo(Context&)` implementation under `src/desk-install/modules/`
and register it in `src/desk-install/core/modules.def`. The registry drives argument
parsing, help, dispatch and the install plan. Route subprocesses through the shared
`sh::` helpers so logging and dry-run handling stay consistent.

For a new theme, see [Theming](theming.md#creating-a-new-theme).
