# Linux_Theme

Opinionated Arch Linux + Hyprland workstation provisioner. Native C++ install orchestrator, integrated local-AI tooling, hardened security baseline, multi-theme rendering for ~25 apps.

Not just dotfiles. `install.sh` is a 90-line wrapper around `fox-install` — a 51-module native C++ orchestrator. Adding an install step is one `.cpp` and one line in `core/modules.def`; the args parser, `--help`, dry-run plan, dispatcher, and registry test all derive from it.

## Screenshots

FoxML_Paper: the Quickshell drawer over Neovim, the lock screen, and Firefox's new tab.

![FoxML_Paper desktop with the drawer open](shared/screenshots/paper_desktop.png)

![FoxML_Paper lock screen](shared/screenshots/paper_lock.png)

![FoxML_Paper Firefox new tab](shared/screenshots/paper_firefox.png)

![Terminal](shared/screenshots/terminal.png?v=2)

![Neovim](shared/screenshots/nvim.png?v=2)

![Neovim + Avante](shared/screenshots/nvim_avante.png?v=2)

## Install

**Fresh machine, no clone needed:**
```bash
curl -fsSL https://raw.githubusercontent.com/Jennifer-214/Linux_Theme/main/bootstrap.sh | bash
```
Caches sudo, installs git+curl, clones to `~/code/Linux_Theme`, runs the full setup (theme + deps + AI stack + GitHub workspace clone). One `gh auth login` prompt mid-flow, otherwise hands-off.

**Already cloned:**
```bash
./setup            # full kitchen sink — every default module + deps + AI + GitHub clone
./setup-minimal    # theme + system deps only (no security, login screen, AI or GitHub clone)
./install.sh       # interactive, prompts at each step
```

These use your saved theme, or FoxML_Classic on a first install. Add a theme name to pick one: `./setup-minimal FoxML_Paper`.

**Fine-grained:**
```bash
./install.sh monitors                              # surgical run: just the monitor wizard
./install.sh Cave_Data_Center monitors render      # specific theme + specific modules only
./install.sh FoxML_Classic --deps --yes            # specific flags, no prompts
```

### Install flags

| Flag | What it does |
|------|--------------|
| `--monitor` | Surgical run of the multi-monitor layout wizard only |
| `--deps` | Install Arch packages, Oh My Zsh, zsh plugins |
| --yes | Auto-confirm every prompt |
| --ai | Install OpenCode + aider (see [AI layer](#ai-layer-optional)) |
| --models | Queue the RAM-tiered model stack + your personal model lists — Hugging Face GGUFs, downloaded in the background, resuming across reboots |
| --llama-server | llama.cpp router — the default local model server for OpenCode + pi (`127.0.0.1:8080`) |
| --llama-turbo | TurboQuant llama.cpp fork, built from source — optional second engine for long-context roles |
| --github | Clone all your repos into ~/code |
| --secure | UFW + Fail2ban + Auditd + SSH hardening wizard |
| --perf | Chrony for high-precision time sync |
| --privacy | DNS-over-HTTPS |
| `--vault` | GPG-encrypted `pass` manager + Git signing |
| `--nvidia` | nvidia-open-dkms + Hyprland on dGPU (Optimus laptops) |
| `--render` | Apply the theme everywhere: render, deploy, scripts, drawer, cursor and banner, then restart waybar/mako/dunst. Folder colours can need sudo, so it warns and leaves them to `--only papirus_icons` |
| `--dry-run` | Print every step without executing |

The installer exits `0` when everything finished, `1` when a module failed, `2` when a render stopped to protect live edits, and `3` when it finished but a module reported an error.

`--nvidia` requires `systemd-boot`; other bootloaders print manual instructions. Reboot afterwards.

`./install.sh --help` lists all 51 module flags.

### Archinstall profile

Boot the Arch ISO and load FoxML directly:

```bash
archinstall --config https://raw.githubusercontent.com/Jennifer-214/Linux_Theme/main/shared/foxml-profile.json
```

Installs `linux-zen`, NVIDIA drivers, and runs the bootstrap on first boot.

## Architecture

`install.sh` is a 90-line wrapper that self-updates, warms sudo, builds the native orchestrator, and `exec`s it. The 2400-line bash predecessor is gone; every install step now lives as a C++ module.

Native C++ tools under `src/`:

| Tool | Role |
|---|---|
| `fox-install` | Module-registry-driven install orchestrator (51 modules) |
| `fox-intel` | `libfox-intel.a` — local model client (llama.cpp's router) + embedding API; linked into every AI tool |
| `fox-render-fast` | Concurrent template engine; drop-in for the old `render.sh` |
| `fox-pulse` | Single-epoll daemon multiplexing Hyprland IPC + inotify + debouncers |
| `fox-vault` | `mlock()`-protected in-RAM secret store with Unix-socket CLI |
| `fox-ask`, `fox-ai-doctor`, `fox-ai-oracle`, `fox-ai-snitch`, `fox-ai-audit`, `fox-ai-bouncer`, `fox-ai-review`, `fox-ai-swap` | One-shot AI tools that link `libfox-intel.a` — pattern is `#include "fox_intel.hpp"` + `ai.ask(prompt)`. No plugin framework. |

The X-macro registry in `src/fox-install/core/modules.def` is the single source of truth for install modules. Each module is a `void run_foo(Context&)` function. Subprocess goes through `sh::run` / `sh::capture` / `sh::pacman` / `sh::systemctl_*` so `--dry-run` and logging stay centralized.

Bash is retained where it makes sense — small Hyprland event scripts, `mappings.sh` as a *runtime* helper sourced by `~/.config/hypr/scripts/`. `aider` is the one Python install (~60 transitive deps).

## Security hardening

`--secure` installs the kernel/userspace baseline:

- **UFW firewall** with default-deny outbound + curated allowlist
- **Fail2ban** brute-force protection on sshd
- **Auditd** kernel honeypot rules (`foxml_honey` tag → `fox-dispatch` phone alert)
- **SSH hardening wizard** — passphrase enforcement, no password auth, agent-hijack masking of newer `gnome-keyring-daemon` units
- **USBGuard** allowlist with `fox-bouncer` alerting when blocked devices appear during screen-lock
- **AppArmor**, **polkit-strict** (under `--full`), kernel sysctls, IOMMU, `noexec_tmp`, `hidepid`, `no_coredumps`, makepkg signing
- **arch-audit** systemd-user timer (daily CVE surface)
- **DNS sinkhole** — StevenBlack blocklist + DNSSEC strict-mode picker

Opt-in via dedicated flags: `--browser-harden` (arkenfox + Firejail), `--vault` (mlock-protected secret store), `--endlessh` (SSH tarpit on `:22`, real sshd moved to high port), `--mac-random` (NetworkManager randomization), `--fprint` + `--fprint-pam` (fingerprint + safe PAM splice into `system-local-login` only — never `/etc/pam.d/sudo`).

Day-to-day tooling:

| Command | What it does |
|---|---|
| `fox doctor [--ai]` | Config drift + posture check |
| `fox sec [--live]` | Unified security dashboard |
| `fox audit [--score]` | Lynis wrapper, 0-100 hardening score |
| `fox snitch` | Per-app outbound firewall (OpenSnitch) |
| `fox honey plant <dir>` | Honeytoken + auditd watch in a repo |
| `fox vpn [up\|down]` | WireGuard wizard with UFW kill-switch |
| `fox cafe` | Auto-tighten on untrusted WiFi (NetworkManager dispatcher) |

See `fox help` for the full surface (70+ subcommands).

## AI layer (optional)

Installed via `--ai` + `--models` + `--llama-server` (the desktop preset turns all three on). Every model is a Hugging Face GGUF in llama.cpp's own format, and **llama.cpp's router serves them all** — the one server for the terminal agents, the `fox-ai-*` tools and their embeddings: one loopback URL (`127.0.0.1:8080`), every downloaded model loaded on demand, GPU placement left to llama.cpp's MoE-aware auto-fit, a 128k-context agent role. `--ai` installs OpenCode (terminal agent) and aider (git-native pair programmer); `--models` queues the chat/coder stack sized to your RAM, plus the `mxbai-embed-large` embedder; `--llama-server` installs llama.cpp and the router.

### Agents

- **OpenCode** — Claude-Code-style terminal agent. Multi-provider; its local default is the llama.cpp router. Theme and skill paths are generated (skills from `~/code/*/claude-skills/`); `fox-llm-update --sync` fills the model picker from what the router serves. Auto-wakes the router on launch.
- **pi** — minimal terminal coding agent with FoxML extensions (permission gate, desktop notifications, per-project Claude skills); same local default as OpenCode.
- **aider** — git-native pair programmer. Commits its own edits per change. Useful for surgical "make this change" workflows where OpenCode's multi-turn agent loop is overkill.

### Local models (`fox-llm-*`)

| Piece | What it does |
|-------|--------------|
| `~/code/custom_models/roles.conf` | Your roles: which model fills each role (`agent`, `quick`, `fim`, `title`, `embed`) and on which router (`llama`, `llama-turbo`). Kept in a private `custom_models` repo, so `--github` brings it back on a reinstall; the installer links `~/.config/foxml/llm/roles.conf` to it (a real file there overrides it on one machine); `roles.default` ships |
| `~/code/custom_models/gguf-models.conf` | Your models: `name user/repo/file.gguf` lines (Hugging Face, single-file GGUFs); a `-name` line skips one from every list. `~/.config/foxml/llm/gguf-models.txt` is the same for one machine; `core-models.txt` ships the RAM-tiered defaults |
| `fox-llm-update` | Downloads the lists into `~/.local/share/fox-llm/gguf/` — sha256-checked against Hugging Face's record, and each file's header through llama.cpp's loader before the download, so a model the build can't run never costs one. Daily timer: update notices, newer uploads, discovery of new tool-capable models on Hugging Face (`fox-llm-discover`). `--queue` downloads in the background (resumes across reboots); `--sync` wires the models into OpenCode + pi |
| `fox-llm-serve` | Builds the router's preset from the roles and the downloaded models — chat and embedding models; a once-per-file load check leaves out a model this llama.cpp can't run |
| `fox-llm-run` | One answer from the router for scripts — `fox-llm-run "prompt"`, `--list`, `--ps`, `--unload`; what the `fox-ai-*` shell tools use |

### RAG (`fask` / `findex`)

`findex` builds a chunked semantic index of the current directory using `mxbai-embed-large`. Files are split into 100-line chunks with 10-line overlap so functions spanning chunk boundaries still appear whole somewhere. The model name is persisted in the index — re-running with a different embedder triggers a clean rebuild instead of mixing incompatible vectors. `fask` cosine-ranks chunks against your question, opens each top-K match at its exact line range, and streams a model answer.

| Command | What it does |
|---------|--------------|
| `findex [opts]` | Build semantic index (tunable via `--size`, `--model`, etc.) |
| `fask "<q>"` | RAG Q&A over the current project's `.foxml_index.json` |
| `fox ask "<question>"` | One-shot terminal Q&A — no index needed; uses the OpenCode-configured model |
| `fox-ai-commit` | AI-drafted commit message from staged diff |
| `fox-ai-explain <file>` | Plain-English explanation of code/logs/errors |
| `fox-ai-swap [tag]` | Switch the default model (OpenCode + the fox-ai tools) and free the old one's memory on whichever server runs it |
| `fox-ai-doctor` | AI-augmented system diagnostics |
| `fox-ai-review` | Pre-commit guardrail (`BLOCK:` / `WARN:` lines from local model) |
| `fhelp` | Full command reference |

`cd`-ing into a directory containing an `AGENT.md` auto-exports project context, scoping `fask`/`findex` to that workspace.

### Theme integration

- Palette-driven OpenCode theme (`templates/opencode/foxml.json`) rendered through the same `{{TOKEN}}` system — theme swaps re-render OpenCode too.
- `fask`/`fox-ask` pick up the active palette's `ANSI_ACCENT1` via `~/.config/foxml/ansi_colors.json` for status banners like `[Thinking...]`.

## Themes

### [FoxML Classic](themes/FoxML_Classic/) (dark)
Earthy, muted: warm peach, dusty rose, sage, wheat on a deep plum background.

| Role | Color | |
|------|-------|-|
| Background | `#1a1214` | Warm dark |
| Foreground | `#d5c4b0` | Warm cream |
| Primary | `#c4956e` | Peach |
| Secondary | `#b8967a` | Dusty rose |
| Accent | `#8a9a7a` | Sage |
| Surface | `#3a414b` | Slate |

### [Cave Data Center](themes/Cave_Data_Center/)
Alternate palette — see `themes/Cave_Data_Center/palette.sh`.

### Switching themes

```bash
./swap.sh
```
Interactive picker with color previews.

### Editing configs

Edit the templates in `templates/`, not your live configs. Templates use `{{TOKEN}}` placeholders; `install.sh --render` renders them with the active theme's colors and restarts waybar/mako/dunst so the new look applies live.

If you've already edited a live config and want to keep the changes:
```bash
./update.sh
```
Reverse-renders your live configs back into templates, replacing rendered colors with `{{PLACEHOLDER}}` tokens so the edits survive theme swaps.

## How it works

```
templates/                 config files with {{PLACEHOLDER}} tokens
  kitty/kitty.conf         background #{{BG}}, foreground #{{PRIMARY}}, ...
  nvim/init.lua            colors with #{{RED}}, ...
  waybar/style.css         @define-color bg #{{BG}}, ...
  ...                      (30+ files across 25 app directories)
  foxml/ansi_colors.json   palette → libfox-intel theme bridge

themes/
  FoxML_Classic/
    palette.sh             ~60 color variables
    theme.conf             name, type=dark, description

shared/                    non-color files copied as-is (keybinds, scripts)
src/                       C++ orchestrator + tools (see Architecture above)

install.sh                 wrapper → builds + execs fox-install
update.sh                  reverse-renders system configs → templates
swap.sh                    interactive theme switcher
```

Adding a new theme = writing one `palette.sh` file. All app configs render from templates.

## Themed apps

| App | Template | Installs to |
|-----|----------|-------------|
| Hyprland | `templates/hyprland/theme.conf` | `~/.config/hypr/modules/theme.conf` |
| Hyprlock | `templates/hyprlock/hyprlock.conf` | `~/.config/hypr/hyprlock.conf` |
| Neovim | `templates/nvim/init.lua` | `~/.config/nvim/init.lua` |
| Swappy screenshot editor | `templates/swappy/config` | `~/.config/swappy/config` |
| Kitty | `templates/kitty/kitty.conf` | `~/.config/kitty/kitty.conf` |
| Waybar | `templates/waybar/style.css` | `~/.config/waybar/style.css` |
| Tmux | `templates/tmux/.tmux.conf` | `~/.tmux.conf` |
| Zsh | `templates/zsh/` (7 files) | `~/.zshrc` + `~/.config/zsh/` |
| Rofi (legacy assets) | `templates/rofi/glass.rasi` | `~/.config/rofi/glass.rasi` |
| Dunst | `templates/dunst/dunstrc` | `~/.config/dunst/dunstrc` |
| Mako | `templates/mako/config` | `~/.config/mako/config` |
| Fastfetch | `templates/fastfetch/config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| GTK 3 | `templates/gtk-3.0/gtk.css` | `~/.config/gtk-3.0/gtk.css` |
| GTK 4 | `templates/gtk-4.0/gtk.css` | `~/.config/gtk-4.0/gtk.css` |
| btop | `templates/btop/foxml.theme` | `~/.config/btop/themes/foxml.theme` |
| Yazi | `templates/yazi/theme.toml` | `~/.config/yazi/theme.toml` |
| Zathura | `templates/zathura/zathurarc` | `~/.config/zathura/zathurarc` |
| Firefox | `templates/firefox/` (CSS + find-color preferences) | `<profile>/chrome/`, managed block in `user.js` |
| Cursor / VS Code | `templates/cursor/` | `~/.cursor/extensions/foxml-theme/` |
| Bat | `templates/bat/foxml.tmTheme` | `~/.config/bat/themes/Fox ML.tmTheme` |
| Lazygit | `templates/lazygit/config.yml` | `~/.config/lazygit/config.yml` |
| Git delta | `templates/git/delta.gitconfig` | `~/.config/git/delta-foxml.gitconfig` |
| OpenCode | `templates/opencode/foxml.json` | `~/.config/opencode/themes/foxml.json` |
| Codex CLI | `templates/codex/foxml.tmTheme` | `~/.codex/themes/foxml.tmTheme` |
| ReGreet (login) | `templates/regreet/regreet.css` | `/etc/greetd/regreet.css` (sudo) |

For Codex CLI, select `foxml` once with `/theme` (or set `theme = "foxml"`
under `[tui]` in `~/.codex/config.toml`). Code blocks use the active palette;
the surrounding interface inherits the terminal's colors. Restart Codex after
a theme swap. With a custom `CODEX_HOME`, copy the rendered theme into
`$CODEX_HOME/themes/foxml.tmTheme`. Edit `templates/codex/foxml.tmTheme` directly;
the legacy `update.sh` capture list does not include Codex.

## Shared (non-color) files

### Desktop drawers

`fox-desktop-menu` opens the Quickshell menu: Desk, Sound, Connections, Comfort,
and System. Existing menu shortcuts and the bar launcher open the same drawer;
`fox-desktop-menu wifi` or `fox-desktop-menu sound` opens a section directly.
The top bar and drawers share one Quickshell process. On Paper, its modules hang
from the screen edge as little paper banners, with blush active-workspace ribbons.
It reads the existing rendered Waybar JSON for module order, groups, formats,
intervals, scripts, tooltips, and click/scroll commands. Telemetry helpers are shared
across outputs; secondary, portrait, and narrow primary monitors use the compact
configuration. Workspace icon previews shorten before text scales down, and long
workspace strips scroll to keep the current page visible. Workspace
window icons, power profiles, idle inhibition, and the application tray remain available.
`Alt+B` or `fox-bar toggle` hides/shows the bar; `fox-bar status` reports readiness.
`start_waybar.sh` retains its compatibility name and rendering/cursor logic: it
verifies Quickshell before stopping Waybar, and launches Waybar if the new bar fails
to become ready. Waybar stays installed as a fallback. Palette changes render
`templates/quickshell/foxml/Theme.qml` and reload both surfaces together.
The drawer tucks beneath its source bookmark, with a stronger contact shadow
and a faint second paper edge. The ribbon stays in front during the 160ms reveal.
Keyboard opens tuck beneath the launcher on the focused monitor; hiding the bar
leaves a standalone drawer. Closing releases keyboard input immediately. The
attached sheet shares the bar surface, with its input region restricted to the bar
and visible paper; the reserved desktop space stays at the normal bar height.
Fonts remain palette-controlled and unchanged. The drawer retains its Waybar
marker stylesheet for fallback compatibility.
Hover and press feedback changes only the paper shade or pencil outline; controls
keep their position and size. The pink active-workspace fill remains visible on hover.
Drawer surfaces use quiet paper shades, with a faint highlighter wash on focused
items. Bookmark ribbons, the focus edge and the charging heart follow the existing
workspace accent; battery numbers stay graphite. The active workspace keeps its
soft highlighter fill, and warning colors are retained. Control symbols share the existing font,
size and pencil weight; status glows and the repeating battery pulse are removed.
Group subtitles show live volume, active connection, notification state, open
window count and cached updates. They refresh every four seconds while the
panel is open, with no polling while it is closed.

The home panel shows pinned favorites. Use `f` or the heart button to return
to it, and Tab to switch between favorites and groups. Set `"favorites"` in
`menus.json` to an ordered list of existing `group/item` references, for example
`["desk/apps", "desk/clipboard-text", "comfort/dnd"]`. Up to eight are supported;
`[]` explicitly hides favorites. Existing custom configurations without this
field keep the group-only home view until favorites are added.

Desk → Project index cards lists immediate project folders under `~/code`,
recognizing Git repositories and common build manifests without running Git,
builds or project code. `/` filters cards, Enter opens the project in Cursor
(or Neovim in Kitty), and `t` opens a terminal in that folder. Configure scan
folders with `"project_roots": ["~/code", "~/school"]` and optionally choose an
editor with an argument array such as `"project_editor": ["kitty", "-e", "nvim"]`.
Hidden folders, symlink folders and unmarked directories are skipped; folders
are never scanned recursively. Press `b` or click the diamond on a project card
to pin or unpin it. Pinned cards wear a ribbon, sort first in the project list,
and appear on Home and Desk → Bookmarks. Up to sixteen ribbons are stored in
`$XDG_STATE_HOME/foxml/project-bookmarks.json` (default `~/.local/state/foxml/`),
separately from the menu configuration. Writes are locked and atomic, with the
previous state retained in `.json.bak`.

Desk → The little library shows removable USB/SD volumes as checkout cards,
including capacity, mount state and free space when mounted. Enter opens a
mounted volume, or mounts it through UDisks first. Press `e` or click eject to
confirm unmounting every volume on the same physical drive and powering it off.
Busy-volume failures stop ejection. Internal disks, system mounts, encrypted
containers and unsupported device stacks are excluded. The library uses
`lsblk`, `udisksctl` and `xdg-open`; `--deps` installs their packages. No drives
are mounted or ejected by opening the drawer, and no extra watcher is started.

Desk → Incoming paper tray lists the newest 64 regular files in your XDG
Downloads folder (falling back to `~/Downloads`), with type, size and modification
age on paper slips. Enter opens the file, `r` opens its containing folder, and
`/` filters the tray. Hidden files, symlinks, subfolders and common unfinished
download extensions are skipped. Set `"downloads_directory": "~/Incoming"` in
`menus.json` to override the folder. A disabled XDG Downloads folder stays empty.
Listing reads file metadata only; it never reads file contents or moves files.

The existing battery module adds a plug-and-heart
doodle while charging, keeping its capacity, watts, threshold and failure signals.
A filled heart marks a finished charge: `Full`, or holding at a charge limit.
The Hyprland menu shortcuts call the drawer directly, including Wi-Fi, Bluetooth,
audio outputs, clipboard, windows and agent notes. Agent notes jump directly
to their exact tmux target; a stale or unreachable note stays available for
review, and clearing all notes asks for confirmation. Paper's bar uses a pencil
launcher, notebook workspace tabs and a handwritten clock tab. Click the clock or
press `Alt+C` to toggle a calendar sheet beneath its banner on the focused monitor.
Past dates have light pencil X's; today has an uneven, open blush circle. A tiny cat
keeps the handwritten month company. Use `h/l`, Left/Right or Page Up/Down to change
months, `t` to return to today, and Escape to close. The date refreshes while open,
including across midnight.

`Alt+Ctrl+O` or Desk → Screenshot scrapbook opens the newest 64 saved screenshots
as taped photo prints with handwritten timestamps. Arrow keys or `h/j/k/l` choose
a picture; `c` copies it, Enter opens it, and Escape closes. The sheet also has
copy, open, folder and new-capture buttons. It reads `~/Pictures/Screenshots`, or
the optional `screenshots_directory` in `menus.json`, and skips symlinks and partial
files. Swappy uses the current palette's accent ink, configured font and thin
pencil strokes. Screenshot pixels are preserved unless you annotate them.
Paper's volume keys show a little speaker slip with a blush ruler, percentage and
mute state; brightness retains its existing indicator. Other palettes and an
unavailable drawer keep the notification fallback. New Neovim windows show a
notebook cover with the current directory, today's date, the existing editor
shortcuts and three recent pages. All of these ship through rendering and the
native installer; existing custom menu entries are preserved when adding the
scrapbook to Desk.

Unused rofi-calc and rofi-emoji add-ons are no longer in the default package list; installed
packages are not removed. The overlapping Rofi desktop menus are retired;
their old script names now delegate to Quickshell, preserving custom shortcuts.
A failed drawer reports an error instead of launching a second menu implementation.
Desktop launches include `~/.local/bin` in both Hyprland configuration formats;
the drawer launcher also discovers its co-located backend without relying on zsh.
The installer selects Lua for Hyprland 0.57+, while an already running session
keeps its existing compositor version until it is restarted.

Use `j/k` to move, `l` or Enter to open, and `h` to go back. Enter on a slider
starts adjustment with `h/l`; Escape finishes. `/` searches menu actions from a
group, or filters the current app/device/clipboard list. Escape goes back before
closing. Shutdown, restart, suspend and logout require confirmation.

The native `--drawer` installer module builds the backend, renders the palette,
backs up replaced files and deploys the configuration. `--deps` installs
Quickshell. Rendering and theme swaps include the drawer; `--no-drawer` skips it.
Install it alone with `./src/fox-install/fox-install FoxML_Paper --only drawer --yes`
after building the installer.

Edit `~/.config/quickshell/foxml/menus.json` to rearrange groups or items; the
installer preserves this file and refreshes `menus.default.json` separately.
The supported item kinds are `page`, `action`, `toggle`, and `slider`; action IDs
refer to the backend's built-in operations. Palette colors come from
`templates/quickshell/foxml/Theme.qml`. The old `FOXML_MENU_LEGACY` desktop-menu
override is retired. The command launcher, shortcut reference, sandbox picker,
existing local AI prompt and wallpaper rotation menu now share the
Quickshell picker too. `fox-picker --title TITLE` reads one label per input line;
`--index` returns its original zero-based index, and `--prompt` accepts free text.
Escape cancels without an action. These use the existing drawer service, with
private temporary request files and no additional daemon.

System → Passwords lists encrypted `pass` entry names only. Enter copies the
first line with `pass show --clip=1`; GPG handles unlocking and `pass` handles
clipboard expiry. A small wrapper adds Wayland’s sensitive-content hint so
clipboard history can skip passwords. Passwords are never previewed. Advanced password creation,
editing and typing remain available through the `pass` CLI. Rofi is no longer a
default dependency; installed packages and old theme assets are retained for
rollback. Wi-Fi credentials and privileged updates keep their normal
authentication interfaces.
Night light uses Hyprsunset: Enter toggles between a 3500K filter and normal
colors. Its switch reads the filter’s IPC state, and a failed start reports an
error. Both Hyprland formats start it with normal colors; `--deps` installs it.

Paper's workspace tabs include monochrome icons for open Hyprland windows; an
editor inside Kitty/tmux uses the terminal icon. Kitty leaves its own tab row
hidden, while tmux adds a pink dot to the existing window label on a bell.
Kitty's background is 97% opaque, with undimmed text so it stays readable on
lower-contrast displays. Paper windows keep their text at full opacity when focus
moves between monitors. Blush selections use a stronger dusty pink, with darker
comments and line numbers; functions, parameters, types and literals retain
distinct inks and emphasis.
The session switcher also marks sessions with a bell in a background window,
using the window flags already included in its normal session query.

In Neovim, named `a-z` / `A-Z` marks get pink bookmark ribbons in the existing
sign gutter, below diagnostic/git/breakpoint priority. `ma` sets mark `a`; `'a`
returns to it. Ribbons refresh on the existing idle/edit events, without a new
timer. Unsaved buffers use a graphite pencil marker, and Lualine keeps its data
on a quiet paper footer. `<leader>tc` toggles comment folds; folded notes show
the first line and line count, and `zo` opens one. These details skip symdeps
panels and leave its winbar, annotations and keys intact. No extra plugins are
required; rendering and the existing installer mappings deploy the changes.
Paper also uses pink matched-bracket underlines and the active tmux pane marker.
File labels use pencil text and keep their path and lettering when focus moves
between Neo-tree and the editor.
The active file tab uses blush behind its pencil name.
Inside tmux, a single Neovim pane uses only its editor footer. Splitting restores
tmux's lane labels, and leaving Neovim restores the previous footer setting.
Btop keeps pencil text with pink shortcut letters, selected process
text, and small process details. Paper's mouse pointer is a pink set the cursor module
builds from Catppuccin's XCursor assets using the palette's `CURSOR_RECOLOR` colours,
for both application and restored desktop shapes. Kitty shows it as an arrow
(`KITTY_POINTER_SHAPE`) rather than its default text beam. Its palette sets
`HYPR_CURSOR_ENABLED=false`; other palettes retain Hyprcursor. Session startup,
theme refreshes, D-Bus activation and tmux attachments propagate the chosen cursor.
Text insertion cursors are unchanged. Hyprland 0.57 loads the Lua configuration;
the `.conf` templates remain compatibility sources for older Hyprland releases.
Neovim puts pencil function definitions and numeric/boolean literals on soft blush
highlights. Darker typed code contrasts with warm gray handwritten comments.
TODO, NOTE, and IDEA labels also use pencil text on blush backgrounds.
Its current line number, fold arrow, active indent guide, and completion icons
use rose; copied text briefly flashes blush. Completion labels stay
pencil on a blush selected row. Markdown headings use pencil, with a blush underline
on the first real heading; checked markers use rose,
with completed task text softened to gray through the existing syntax highlighting.
Inline Markdown code uses pencil text on blush without tinting fenced code blocks.
C/C++ files use native clangd type and parameter hints in readable pencil text;
these skip special buffers and symdeps panels, with no additional plugin.
Fields use stronger pencil and parameters quieter upright gray. The existing
Illuminate provider follows a symbol with pencil underlines. Diagnostic messages
follow the current line; signs and underlines remain, and existing toggles retain
the quiet mode when switched back on. Trailing-space dots apply to code buffers
and restore the previous display when moving to prose. Focused native and Noice
documentation titles use blush with pencil text; inactive titles stay pencil.
Symdeps uses pencil body text, readable gray counts and shortcuts, and blush behind
the focused window's title; inactive titles stay pencil. This is theme-side styling;
the plugin's menu actions, help, and key bindings are unchanged.
Search matches use pencil underlines with blush on the current match. Git changes
use thin gutter marks, with quieter dotted marks for staged edits. Markdown quotes
use a blush opening mark and faint pencil rules; their source returns while typing.
Small Paper controls use the same pink for checkbox ticks, radio centers, slider
thumbs, short field-focus underlines, active-tab markers, and dragged scrollbars.
Text selections in GTK fields use blush with pencil text. The installer synchronizes
the desktop font override from the deployed GTK settings so apps share the configured font.
The drawer's volume ruler keeps its pencil ticks and a pink endpoint. Paper's
confirmation sheet has an attached folded corner and a faint bottom/right shadow;
cancel stays selected by default. Drawer groups and items sit on paper cards with
faint pencil edges and bottom/right shadows; focus adds blush and a little more depth.
The drawer sheet has the same faint outer shadow. Normal Paper windows use a small
graphite shadow offset toward the bottom/right. Native Hyprtoolkit permission
dialogs receive Paper colors, fonts, and rounding through the installer.
Pressing a card softens its shadow without shifting the row.
The selected sidebar group keeps the same blush as the selected item when focus moves inside.
The scrollbar has its own reserved gutter (`DRAWER_SCROLL_GUTTER`), leaving a gap
beside card shadows without changing card width when scrolling appears.
Screenshot selection uses a blush edge and a light
pencil veil. Btop's CPU, memory-use, and download strokes carry blush gradients,
while process text and window frames retain their existing colors. Thunar filename
selections use blush with soft pencil edges. Native Mako notes add a small RECEIVED
stamp, with room for the body; explicit saved/copied/ready categories give that stamp
useful words without repeating them in the title. A faint, broken pencil outline
frames those stamps in the native renderer; stock Mako keeps the blush text labels.
DND is applied after all app styles.
Volume OSDs retain their compact format; workspace notices use the banner and replace
the previous workspace notice. Yazi uses current theme sections
and palette-driven notebook tabs (`YAZI_TAB_ACTIVE_FG/BG`); Delta file labels use the
palette-selected `DELTA_LABEL_STYLE`. Post-install rebuilds the Bat/delta syntax cache
on render-only theme changes as well as full installs.
Paper's active signature parameter and selected search result use blush with pencil
text; other matches use underlines. The existing hlslens plugin owns one readable
`3 of 5` search tag, with the native/Noice duplicate counts hidden on Paper.
Substitution previews and matching brackets also use pencil on blush. `:s` previews
in place until Enter; Esc cancels it without edits. These styles use the existing
palette selection tokens and need no additional plugin. Spectre uses gray struck-out
search text and blush replacement text, and quickfix uses a blush selected row with
readable line numbers. DAP's paused line has a small rose arrow and a blush wash.
Diffview merge headers name current, incoming, base, and result within their existing
rows; other editor/plugin winbars are preserved. Completion names remain pencil,
with quieter type/signature details that shorten to fit narrow windows while insertion
text and full documentation remain intact. Native puts and bracketed pastes flash briefly
without changing their undo behavior. A quiet last-edit pencil stays below bookmark
and diagnostic priority, and hidden zero-width characters in code receive a visible
clue without editing the file. Read-only files keep a graphite lock in the footer.
Paper comments use a stronger warm gray with italic lettering, still lighter than code.
Function parameters use darker upright pencil (`NVIM_SYN_PARAM`) so signatures remain
clearly separate from comment prose in both Treesitter and LSP highlighting.
Server-tagged unnecessary code recedes to an upright gray via native diagnostic tags;
warnings, errors, source text, and formatting remain intact. The comment shade uses
`NVIM_SYN_COMMENT`, so it follows rendering and theme installation.
JSON keys are stronger pencil, Python documentation is quieter than code, and JSON
quotes remain visible. Conform formats Python on save with Ruff (or Black when the
project explicitly configures it); existing project settings and virtualenv tools win.
JSON/JSONC use available Prettier or the existing JSON language server. Invalid strict
JSON is left unformatted on save. `Space c f` also formats manually without requiring
an attached language server. The installer includes Ruff; no new editor plugin is needed.
Drawer confirmations name the action. Focused file cards reveal their full path in the
existing detail line, and tooltips give full labels and exact modification times.
Download ages appear once on their stamp. Unavailable controls retain readable reasons,
and a small pencil beside a slider value appears only during adjustment.
Flash jump labels also use pencil on blush. Markdown links have pencil labels with
blush underlines and quieter gray URLs. Native spelling marks use blush dots in
syntax-designated prose (including comments and Markdown); identifiers, code spans
and URLs keep their existing syntax. Dictionary/language preferences are preserved.
The editor filename uses a pencil for writable files and a lock for read-only or
non-modifiable files. A small blush `draft` tag marks unsaved changes and disappears
after saving. The file and tag keep their editor context when Neo-tree has focus.
Paper's `GTK_ICON_THEME` selects a small user-local icon overlay, inheriting
Papirus-Light and its existing blush folders. Empty/full Trash icons look like a
paper wastebasket and a crumpled note; notification and login icons retain their
base theme. Archives are tied paper parcels, while plain text and Markdown files
are folded notes. `templates/icons/icon-family.json` owns the glyphs, extensions,
language badges and MIME aliases shared by eza, Yazi and the Paper vector overlay.
The native renderer generates all three consumers, including source code, config,
images, tables, audio/video and quieter log/backup notes. The shell renderer calls
the same generator, so both render paths produce identical assets. Read-only file
emblems use a small pencil lock; links use a paperclip. GTK and Qt-native file
pickers inherit these same paper drawings, including at small sizes; they do not
use a separate pink icon set. The terminal uses the matching pencil glyphs from
the same definition. Blush stays on selections and small state accents.
Personal folders keep blush paper bodies and small pencil emblems for documents,
pictures, downloads, music, videos, projects, desktop, templates and public files.
The same icon-family definition supplies terminal directory glyphs and Neo-tree
folder states. Expanded Paper tree folders show an open flap with a small blush
backing; empty folders keep distinct outline icons, with pencil directory names. Symlinks retain
their paperclip, and files named like folders retain their file icons.
Clickable bar items, tray icons and drawer buttons gain a light blush hover wash;
active selections stay stronger and nothing shifts position. GTK buttons share the
wash. GTK progress bars and drawer rulers use a thin pencil line with a small blush
endpoint; slider rulers retain their tick marks. Firefox download meters share the
pencil rule, and pinned browser tabs keep their favicon with a small pencil clip.
The drawer's paper grain is drawn once per size/palette change, with no animation
or polling. Tooltips use a short blush edge stitch across Quickshell, GTK and Firefox.
Long drawers use a short blush page-edge marker in the outer gutter, retaining
the native scrollbar's dragging and track clicks. The Sound drawer's existing
play/pause row shows the current track and available media artwork, held by a small
translucent blush tape strip. Missing or failed artwork falls back to the music
glyph; playback actions retain their existing IDs. Metadata uses the existing
`playerctl` dependency and visible-page refresh, without a new daemon or package.
Media artwork has a narrow cream photo mat beneath the existing tape. Paused and
stopped media use pencil-on-blush state tags, matching Neovim's draft tag; the
detail line omits the repeated state. Tooltip backgrounds share
`TOOLTIP_BG_OPACITY` across Quickshell, GTK and Firefox (Paper: 0.94), while text
stays fully opaque.

Paper notifications share one continuous ribbon from the screen's top edge,
right-aligned behind the bar, with centered text and one shallow bookmark cut.
The existing layer animation slides the ribbon from the top. The bar stays on a
stable overlay layer above the ribbon; its actual per-output height sets
the notification content inset, including compact portrait bars. This uses two
change-only runtime files, not a polling service. `src/fox-mako` builds the
checksum-pinned Mako 1.11.0 source with an optional Cairo outline extension;
upstream Mako still handles actions, history, DND, stacking and progress. The
palette's `MAKO_PAPER_SHAPE` selects `bookmark`, `receipt` or `none`; compact OSDs
keep their ordinary outline. Namespaced configuration comments are ignored by
stock Mako, and `fox-notifications` falls back to the system binary. The drawer
installer backs up and deploys the native binary, launcher and user-service
drop-in. Its dependency list includes the native rendering/build libraries.
The umbrella `make install` defers this optional renderer to that module, so the
build happens after dependencies and cannot bypass the old binary's backup.
Palette-only refreshes reload Mako without clearing its queue; a changed renderer
binary restarts the service so newly installed banner code takes effect. Failed
builds preserve the installed notification files. No envelope pockets or punched-hole
margins are applied.
LSP symbol-renaming prompts use a correction slip: the old name in readable gray,
the editable name on blush, Enter to confirm and Escape to cancel. Other input
prompts keep their existing behavior; narrow terminals or missing NUI use the
normal prompt. Markdown footnote markers get pencil-on-blush accents while source,
code spans, and fenced examples stay intact. These details use palette tokens
and existing widgets, without another service or package.
Palette-only `--render` also refreshes Firefox's rendered stylesheets and find
colours in its existing profile, backing up replaced files without restarting
the browser. Firefox loads them on its next restart; Neovim loads its updated
configuration on its next launch.
PDF files use the same folded note with a pencil `PDF` label. File-manager links
carry a small blush paperclip emblem. Paper's `ls`/`ll`/`lt` use the rendered eza
theme: pencil filenames and glyphs, readable gray metadata, faint tree branches,
and pencil-on-blush Git modification marks. The native `fox-eza` helper supplies
icons for actual filenames and symlinks without parsing terminal output or following
directory links. Unknown options, custom non-JSON themes, and listings beyond its
bounded scan pass through to eza. Same-name links and real files across directories
retain their existing glyph rather than mislabeling the real file. No service or
additional package is needed. The editor and terminal fonts remain unchanged.
Ripgrep uses palette-rendered match backgrounds and readable gray line numbers;
its config changes colors only and preserves an existing custom
`RIPGREP_CONFIG_PATH`. `gpaper` shows Git history with blush ref labels, pencil
messages and gray hashes through the named `paper` pretty format. Existing Git
log layouts remain available. Yazi's copied/selected marks and count badges share
the blush palette; cut files retain their distinct warning ink. Paper footer mode
and position labels use pencil on blush, with gray size/percentage text on paper.
Yazi's rename selection, help rows, completion/pick menus and confirmation button
also use readable pencil-on-selection colors. A small palette-rendered init hook
keeps directory/link icons consistent even when a link has a code extension.
Qt dialogs use the GTK platform theme from `qt6-base`, sharing the GTK font,
palette, icons and native chooser. Shell and Hyprland use the same `gtk3` setting.
Its Qt color-map override is rendered into `~/.config/foxml/qt-palette.json`, so
Qt widgets inherit the exact palette instead of the bridge's stock fallback colors.
Native permission dialogs use the palette's `HYPRTOOLKIT_ACCENT` and
`HYPRTOOLKIT_LINK`, with blush fills and readable pencil links on Paper.
The installer deploys generated vectors and MIME aliases through the same atomic,
backup-first path as ordinary configs. Icon-cache refreshes also snapshot the old
cache before replacing it. New files have no older version to back up; rendered
output is rebuildable from the shared definition and the selected palette.
The lock screen writes the weekday and date in lowercase handwriting with a blush
underline, using the local date. The clock, password field and cat keep their spacing.
It shows a blush Caps Lock tag only while a readable keyboard LED is
on; its read-only helper runs only while locked. It sits above the password field,
clear of the note and sleeping cat; centered anchors preserve this spacing in
portrait layouts. Connection rows use linked paperclips
for connected devices and one open clip for disconnected devices. Unknown states
retain their standard icon. Drawer loading dots wait 220ms before appearing and
stop when idle; four-second background refreshes do not animate them.
The drawer's shared shortcut hints use blush-filled keycaps with pencil lettering on Paper, and empty
lists show a pencil with context-sensitive guidance. Tooltips reveal clipped text
or extra metadata instead of repeating short labels that already fit.
Paper drawers extend continuously from the screen's top edge and slide their
whole sheet down and back up behind the bar. The content inset follows the
actual bar height, preserving the menu layout on portrait outputs. A missing
bookmark on a compact bar keeps the drawer in that output's host; hiding the
bar leaves a screen-edge sheet. The close animation releases keyboard input
immediately. The drawer uses the same flat top, shallow V-cut and pencil shadow
as the bar ribbons. Its native host surface keeps a stable size during opening,
closing and hover tips; the input mask and reserved desktop space still follow
only the bar and visible sheet. A targeted `foxml-bar` no-animation layer rule
keeps compositor effects from moving the row while Quickshell animates content.
Paper's bar keeps a stable Overlay layer so notification ribbons stay behind it
throughout their closing animation. Fullscreen workspaces still hide the bar
unless a drawer or notification needs it; notification coverage ends after the
closing transition, without switching the bar between compositor layers.
Top-bar hover text, workspace hints and tray hints slide out as smaller ribbons
behind their bookmarks. These hints are click-through, delay their appearance,
wrap within the output width, and retract when a drawer opens. Workspace-switch
notifications (`focus-pulse`) inherit the hanging Mako ribbon; volume/brightness
OSDs retain their compact pencil rulers. The notification launcher explicitly
selects the rendered XDG config so an older `~/.mako/config` cannot shadow it.
Shell and tmux fzf matches share `FZF_MATCH_*`/`FZF_META_FG` palette tokens; Firefox
find colors use `FF_FIND_BG/FG`, merged into its preferences by the specials module
(`--render`, `--render-only` or full install). Firefox reads these preferences on its next launch.
Paper's sleeping-pencil-cat wallpaper has matching landscape and portrait
compositions in warm bone white. Tall outputs use the portrait companion so the
cat stays in the lower-right corner. The cursor installer also repairs desktop preferences and
fallback-theme inheritance when the cursor assets are already installed.
The wallpaper's cat, cut out with a rising zzz and faint blush cheeks, is
`shared/quickshell/foxml/paper-cat.png`. The drawer's line-drawn cat has matching cheeks.
It sits on empty drawer pages and under the lock screen note (`HYPRLOCK_CAT_Y`), and
replaces the logo and wordmark on Firefox's new tab, above “a fresh page.” That page
blocks `file:` images, so both render paths embed this same PNG in `userContent.css`.
Pages with their own empty-state line keep it;
the rest say "nothing here".
Firefox's new-tab shortcuts use cream paper labels with small folded corners,
graphite names and blush underlines on hover or keyboard focus.
Downloads, Bookmarks and Clipboard have their own pencil illustrations on empty
pages. Standard drawer groups, Applications, Passwords and Lock screen use matching
pencil icons; custom menu icons and application logos stay available. Project cards
have index-card rules, drive cards have checkout-stamp outlines, and download slips
have shallow torn edges. One still flourish marks each drawer heading: a blush
swash on Home, a circled count on Bookmarks, and a pencil-like underline elsewhere.
Clipboard image thumbnails sit in little cream photo prints with a deeper bottom
margin and one blush photo corner. Failed previews keep a readable image glyph.
Fastfetch puts a small ASCII cat on a machine library card beside labeled specs;
other palettes retain their existing logo and labels. The Paper wallpaper includes
the same soft cheeks, and supplies the matching lock and login backgrounds.
The `flower` option in `CURSOR_RECOLOR` swaps the busy
cursors for a turning flower in the pointer's colours. The pointer is size 30 on every
theme and display. `PAPIRUS_FOLDER_RECOLOR` builds the `foxml-blush` folders from
Catppuccin's pink to match it, and Zathura search highlights use `ZATHURA_HIGHLIGHT` and
`ZATHURA_HIGHLIGHT_ACTIVE`.
Drawer pages show their current name once in the heading; breadcrumbs show only
parents. Control details omit repeated labels/values, and keyboard instructions
live in one contextual footer, with separate messages for errors and action results.
Background drawer refreshes preserve the group being browsed; group scrolling
stops at the edges without overscroll.

Copied as-is regardless of theme:

| Path | Description |
|------|-------------|
| `shared/hyprland_modules/` | 12 Hyprland modules (keybinds, rules, monitors, scratchpads) |
| `shared/hyprland_scripts/` | 12 helper scripts (lock, startup, yazi, fingerprint) |
| `shared/launchers/` | Toggle scripts for btop, yazi |
| `shared/wallpapers/` | Wallpaper files |
| `shared/nvim_lazy-lock.json` | Neovim plugin lock file |
| `shared/nvim_ftplugin/` | Neovim filetype plugins |
| `shared/rofi_config.rasi` | Rofi layout config |
| `shared/waybar_config` | Waybar module/layout config |
| `shared/zsh_aliases.zsh` | Shell aliases |
| `shared/zsh_git.zsh` | Git workflow functions |
| `shared/zsh_paths.zsh` | PATH setup |
| `shared/zsh_conda.zsh` | Conda/mamba init |
| `shared/regreet.toml` | ReGreet greeter config |
| `shared/greetd_hyprland.conf` | Minimal Hyprland session for the greeter |

## Zsh

`templates/zsh/` includes:

| File | Description |
|------|-------------|
| `.zshrc` | Oh My Zsh, completions, fzf, tmux auto-attach |
| `caramel.zsh-theme` | Custom prompt — gradient path, git, conda/venv, elapsed time |
| `colors.zsh` | LS_COLORS and zsh-syntax-highlighting |
| `welcome.zsh` | Terminal splash with system info and todo list |

Requires Oh My Zsh, zsh-syntax-highlighting, zsh-autosuggestions, eza, bat.

Paper keeps the two-line prompt and its Git, environment, job, duration, and clock
details. The current folder sits on a blush tab; metadata and command history use
quiet pencil text. Commands are bold graphite, suggestions are faint handwriting,
and selections use the shared blush. Fzf and Tab completion share their pointer
and paperclip marker; Tab previews remain visible. Git uses Oh My Zsh's async
prompt hook so the branch stays available without adding a prompt framework.
Multiline commands use a quiet continuation arrow alongside Zsh's quote/loop context.

### Git workflow functions

`shared/zsh_git.zsh` adds shortcuts on top of the Oh My Zsh `git` plugin:

| Command | What it does |
|---------|--------------|
| `gpush` | Push current branch — sets upstream on first push |
| `gnew [name]` | Create + switch to new branch |
| `gsave <msg>` | Stage all + commit |
| `gquick` | WIP checkpoint commit with timestamp |
| `gundo` | Undo last commit, keep changes staged |
| `gamend` | Fold new changes into last commit |
| `gbr` | fzf branch switcher, sorted by most recent |
| `grecent` | List recent branches with relative timestamps |
| `gsync` | Fetch + rebase current branch onto latest main |
| `gclean` | Delete local branches already merged into main |
| `gstash [msg]` | Named stash (no args = list) |
| `gpop` | fzf picker for which stash to pop |
| `gtoday` | Your commits from today |
| `gds` | Diff staged changes |

## Neovim

See [`shared/nvim_NVIM-KEYBINDS.md`](shared/nvim_NVIM-KEYBINDS.md) for the full keybind reference.

AI integration:
- **copilot.lua** — inline ghost-text completions + copilot-cmp source (toggle `<Space>Ci`)
- **avante.nvim** — Cursor-style chat panel via Copilot (Claude Sonnet 4)
- **claudecode.nvim** — Claude Code terminal integration (`<Space>Ct`, `<Space>Cs`)

Stack: LSP via mason, DAP, cmake-tools, neotest, lazygit, telescope, harpoon, neo-tree, treesitter, zen-mode.

## Multi-monitor

`./install.sh` runs the `monitors` module near the end, which detects every output via `hyprctl monitors -j` and prompts for position (left / right / above / below the laptop) and orientation (landscape / portrait-left / portrait-right) per external monitor. The picker writes:

- `~/.config/hypr/modules/monitors.conf` — name-keyed Hyprland rules. Unplugged monitors are silently skipped, so undocking just works; plugging the same external back in restores the saved layout.
- `~/.config/foxml/monitor-layout.conf` — sidecar consumed by `start_waybar.sh` and `rotate_wallpaper.sh`.

The `personalize` module pre-renders a wallpaper variant per **unique** monitor resolution, named `${name}_${WxH}.${ext}` for each sidecar entry (for example, `eDP-1:1920x1080 DP-2:1440x2560`). Tall outputs prefer a matching `${name}_portrait` source when one is supplied; ordinary photos keep their centered crop. Authored orientation pairs preserve their drawing with Lanczos resizing, while ordinary upscaling crops can use Real-ESRGAN. Variants are published atomically at native dimensions. `rotate_wallpaper.sh` picks the matching variant per monitor; `fox-monitor reconcile` refreshes only the active wallpaper so a hotplug does not rebuild the whole collection.

External monitors get a stripped-down secondary waybar (workspaces + clock + fox/SysHub launcher) — main bar stays on the laptop. Single-monitor setups render the original full bar unchanged.

Under `-y`, externals default to right-of-laptop landscape with no prompts.

### Tmux: pop a pane to the portrait monitor

`templates/tmux/.tmux.conf` defines two binds for moving panes between sessions:

| Key | What it does |
|-----|--------------|
| `prefix + m` | Move current pane to a brand-new tmux session, auto-switch the client to it (same kitty window) |
| `prefix + M` | Pop current pane to its **own** new kitty window (drag onto the portrait monitor) |

`prefix + M` works by spawning `kitty --detach` with `env -u TMUX tmux attach`, so the new kitty actually attaches to the popped session instead of nesting back into the parent.

## Login screen (greetd + regreet)

regreet (a GTK4 greeter for greetd) runs inside a minimal Hyprland session — no cage, no TTY flash. `./install.sh --deps` installs `greetd` + `greetd-regreet` and the `greetd` module deploys the css/toml + wallpaper, writes `/etc/greetd/config.toml`, and enables the systemd unit. Idempotent — rerunning preserves a customized `config.toml`.

On first login, pick your Hyprland session from the dropdown — regreet remembers it.

## Requirements

- Arch Linux (the installer uses `pacman`)
- Hyprland
- `bash`, `git`, `sed`
- **At least 1GB of free space on the boot partition**
- The apps you want themed should already be installed, or pass `--deps` to install them.

Optional: `greetd` + `greetd-regreet` for the themed login screen.

## Creating a new theme

1. Copy a palette: `cp themes/FoxML_Classic/palette.sh themes/My_Theme/palette.sh`
2. Edit the colors.
3. Create `themes/My_Theme/theme.conf` with name/type/description.
4. Run `./install.sh My_Theme`.

The palette defines ~60 variables across:
- **Core** — BG, FG, PRIMARY, SECONDARY, ACCENT, SURFACE + variants
- **ANSI** — RED, GREEN, YELLOW, BLUE, CYAN + bright variants
- **ANSI 256** — terminal color indices for zsh prompts
- **Tmux** — `colour216`-style palette
- **App overrides** — per-app background tweaks (dunst, spicetify, vencord)
- **Font** — `FONT_FAMILY` (default `MonaspiceKr Nerd Font`)
- **Metadata** — NVIM_STYLE, KITTY_BG_OPACITY, POPUP_BG_OPACITY, VSCODE_UI_THEME
- **Aesthetic knobs** — ROUNDING, BLUR_SIZE, BLUR_PASSES, GAP_IN, GAP_OUT, BORDER_SIZE (live-tunable via `fox-theme-tweak`)

### Changing the font

Set `FONT_FAMILY` in `palette.sh` to any installed Nerd Font:

```bash
FONT_FAMILY="MonaspiceKr Nerd Font"    # default — Monaspace Krypton (also Ne / Ar / Xe / Rn)
FONT_FAMILY="Hack Nerd Font"           # blocky, sturdy
FONT_FAMILY="JetBrainsMono Nerd Font"  # clean, rounded
FONT_FAMILY="IBM Plex Mono Nerd Font"  # industrial, wide
```

This updates all templated configs. Shared configs (GTK settings, regreet.toml, hyprland general) reference the font directly — update those by hand if you switch.

See `themes/FoxML_Classic/palette.sh` for the full variable list.

## Post-install

1. `hyprctl reload`
2. Restart terminals/apps
3. Firefox: enable `toolkit.legacyUserProfileCustomizations.stylesheets` in `about:config`
4. Cursor: select "Fox ML" in the color theme picker

## License

Do whatever you want with it.
