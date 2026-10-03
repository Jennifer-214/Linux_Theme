# Linux_Theme

Opinionated Arch Linux + Hyprland workstation provisioner. Native C++ install orchestrator, integrated local-AI tooling, hardened security baseline, multi-theme rendering for ~25 apps.

Not just dotfiles. `install.sh` is a 90-line wrapper around `fox-install` — a 51-module native C++ orchestrator. Adding an install step is one `.cpp` and one line in `core/modules.def`; the args parser, `--help`, dry-run plan, dispatcher, and registry test all derive from it.

## Screenshots

![Terminal](shared/screenshots/terminal.png?v=2)

![Neovim](shared/screenshots/nvim.png?v=2)

![Neovim + Avante](shared/screenshots/nvim_avante.png?v=2)

## Install

**Fresh machine, no clone needed:**
```bash
curl -fsSL https://raw.githubusercontent.com/Jennyfirrr/Linux_Theme/main/bootstrap.sh | bash
```
Caches sudo, installs git+curl, clones to `~/code/Linux_Theme`, runs the full setup (theme + deps + AI stack + GitHub workspace clone). One `gh auth login` prompt mid-flow, otherwise hands-off.

**Already cloned:**
```bash
./setup            # full kitchen sink — theme + deps + AI + GitHub clone
./setup-minimal    # theme + system deps only (no AI, no GitHub clone)
./install.sh       # interactive, prompts at each step
```

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
| --ai | Install Ollama + OpenCode + aider + mxbai-embed-large (see [AI layer](#ai-layer-optional)) |
| --models | Pull tier-appropriate Qwen chat/coder stack (1.5B → 32B based on RAM+VRAM) |
| --github | Clone all your repos into ~/code |
| --secure | UFW + Fail2ban + Auditd + SSH hardening wizard |
| --perf | Chrony for high-precision time sync |
| --privacy | DNS-over-HTTPS |
| `--vault` | GPG-encrypted `pass` manager + Git signing |
| `--nvidia` | nvidia-open-dkms + Hyprland on dGPU (Optimus laptops) |
| `--render` | Re-render templates + redeploy + restart waybar/mako/dunst |
| `--dry-run` | Print every step without executing |

`--nvidia` requires `systemd-boot`; other bootloaders print manual instructions. Reboot afterwards.

`./install.sh --help` lists all 51 module flags.

### Archinstall profile

Boot the Arch ISO and load FoxML directly:

```bash
archinstall --config https://raw.githubusercontent.com/Jennyfirrr/Linux_Theme/main/shared/foxml-profile.json
```

Installs `linux-zen`, NVIDIA drivers, and runs the bootstrap on first boot.

## Architecture

`install.sh` is a 90-line wrapper that self-updates, warms sudo, builds the native orchestrator, and `exec`s it. The 2400-line bash predecessor is gone; every install step now lives as a C++ module.

Native C++ tools under `src/`:

| Tool | Role |
|---|---|
| `fox-install` | Module-registry-driven install orchestrator (51 modules) |
| `fox-intel` | `libfox-intel.a` — Ollama client + embedding API; linked into every AI tool |
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

Installed via `--ai`. Three local-model surfaces (terminal agent, in-editor, one-shot Q&A) all backed by Ollama. `--ai` installs Ollama, `mxbai-embed-large` embedder, OpenCode (terminal agent), and aider (git-native pair programmer). `--models` pulls the chat/coder stack sized to your RAM+VRAM.

### Agents

- **OpenCode** — Claude-Code-style terminal agent. Multi-provider; in this install pointed at local Ollama. Theme + skill paths + model picker generated from `ollama list` and `~/code/*/claude-skills/`. Auto-wakes the daemon on launch.
- **aider** — git-native pair programmer. Commits its own edits per change. Useful for surgical "make this change" workflows where OpenCode's multi-turn agent loop is overkill.

### RAG (`fask` / `findex`)

`findex` builds a chunked semantic index of the current directory using `mxbai-embed-large`. Files are split into 100-line chunks with 10-line overlap so functions spanning chunk boundaries still appear whole somewhere. The model name is persisted in the index — re-running with a different embedder triggers a clean rebuild instead of mixing incompatible vectors. `fask` cosine-ranks chunks against your question, opens each top-K match at its exact line range, and streams a model answer.

| Command | What it does |
|---------|--------------|
| `findex [opts]` | Build semantic index (tunable via `--size`, `--model`, etc.) |
| `fask "<q>"` | RAG Q&A over the current project's `.foxml_index.json` |
| `fox ask "<question>"` | One-shot terminal Q&A — no index needed; uses the OpenCode-configured model |
| `fox-ai-commit` | AI-drafted commit message from staged diff |
| `fox-ai-explain <file>` | Plain-English explanation of code/logs/errors |
| `fox-ai-swap [tag]` | Switch the default model + free VRAM via `ollama stop` |
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
| Kitty | `templates/kitty/kitty.conf` | `~/.config/kitty/kitty.conf` |
| Waybar | `templates/waybar/style.css` | `~/.config/waybar/style.css` |
| Tmux | `templates/tmux/.tmux.conf` | `~/.tmux.conf` |
| Zsh | `templates/zsh/` (7 files) | `~/.zshrc` + `~/.config/zsh/` |
| Rofi | `templates/rofi/glass.rasi` | `~/.config/rofi/glass.rasi` |
| Dunst | `templates/dunst/dunstrc` | `~/.config/dunst/dunstrc` |
| Mako | `templates/mako/config` | `~/.config/mako/config` |
| Fastfetch | `templates/fastfetch/config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| GTK 3 | `templates/gtk-3.0/gtk.css` | `~/.config/gtk-3.0/gtk.css` |
| GTK 4 | `templates/gtk-4.0/gtk.css` | `~/.config/gtk-4.0/gtk.css` |
| btop | `templates/btop/foxml.theme` | `~/.config/btop/themes/foxml.theme` |
| Yazi | `templates/yazi/theme.toml` | `~/.config/yazi/theme.toml` |
| Zathura | `templates/zathura/zathurarc` | `~/.config/zathura/zathurarc` |
| Firefox | `templates/firefox/` (2 files) | `<profile>/chrome/userChrome.css` |
| Cursor / VS Code | `templates/cursor/` | `~/.cursor/extensions/foxml-theme/` |
| Bat | `templates/bat/foxml.tmTheme` | `~/.config/bat/themes/Fox ML.tmTheme` |
| Lazygit | `templates/lazygit/config.yml` | `~/.config/lazygit/config.yml` |
| Git delta | `templates/git/delta.gitconfig` | `~/.config/git/delta-foxml.gitconfig` |
| Gemini CLI | `templates/gemini/settings.json` | `~/.gemini/settings.json` (merged) |
| OpenCode | `templates/opencode/foxml.json` | `~/.config/opencode/themes/foxml.json` |
| ReGreet (login) | `templates/regreet/regreet.css` | `/etc/greetd/regreet.css` (sudo) |

## Shared (non-color) files

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

The `personalize` module pre-renders a wallpaper variant per **unique** monitor resolution: `magick <src> -resize ${WxH}^ -gravity center -extent ${WxH}` writes `${name}_${WxH}.${ext}` for each entry in the sidecar's `MONITOR_RESOLUTIONS` list (e.g. `eDP-1:1920x1080 DP-2:1440x2560`). Each variant is scaled-to-cover at the monitor's native resolution then center-cropped — pixel-perfect, no runtime scaling. `rotate_wallpaper.sh` picks the matching variant per monitor from `hyprctl monitors`, falling back to the source if a variant is missing. Source wallpapers smaller than your monitor will upscale (and look soft); the shipped FoxML wallpapers are large enough that 4K monitors don't see this.

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
