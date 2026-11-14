# Theming and application reference

[← Back to the README](../README.md)

Choose a palette, preserve configuration edits, find application templates or create a theme.

[Themes](#choose-a-theme) · [Editing configs](#editing-configs) · [Apps](#themed-apps) · [New themes](#creating-a-new-theme)

## Choose a theme

### [FoxML Classic](../themes/Classic/) (dark)

Earthy, muted: warm peach, dusty rose, sage, wheat on a deep plum background.

| Role | Color | |
|------|-------|-|
| Background | `#1a1214` | Warm dark |
| Foreground | `#d5c4b0` | Warm cream |
| Primary | `#c4956e` | Peach |
| Secondary | `#b8967a` | Dusty rose |
| Accent | `#8a9a7a` | Sage |
| Surface | `#3a414b` | Slate |

### Other palettes

[Paper](../themes/Paper/) provides the light paper desktop shown in
the README. Rose, Bubblegum, Cave Data Center and Amsterdam Orange supply
alternative palettes. See [theme status](../themes/README.md) for completion and
switching notes, and the [desktop guide](desktop.md#paper-appearance) for Paper details.

### Switching themes

```bash
./swap.sh
```
Interactive picker with color previews. Check [theme status](../themes/README.md) for known limits before switching.

## Editing configs

Edit the templates in `templates/`, not your live configs. Templates use `{{TOKEN}}` placeholders; `install.sh --render` renders them with the active theme's colors and restarts the bar and notifications so the new look applies live.

If you've already edited a live config and want to keep the changes:

```bash
./update.sh
```
Reverse-renders your live configs back into templates, replacing rendered colors with `{{PLACEHOLDER}}` tokens so the edits survive theme swaps.

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
| Mako | `templates/mako/config` | `~/.config/mako/config` |
| Fastfetch | `templates/fastfetch/config.jsonc` | `~/.config/fastfetch/config.jsonc` |
| GTK 3 | `templates/gtk-3.0/gtk.css` | `~/.config/gtk-3.0/gtk.css` |
| GTK 4 | `templates/gtk-4.0/gtk.css` | `~/.config/gtk-4.0/gtk.css` |
| btop | `templates/btop/foxml.theme` | `~/.config/btop/themes/foxml.theme` |
| Yazi | `templates/yazi/theme.toml` | `~/.config/yazi/theme.toml` |
| Zathura | `templates/zathura/zathurarc` | `~/.config/zathura/zathurarc` |
| Firefox | `templates/firefox/` (CSS + find-color preferences) | `<profile>/chrome/`, managed block in `user.js` |
| Cursor / VS Code | `templates/cursor/` | `~/.cursor/extensions/desk-theme/` |
| Bat | `templates/bat/foxml.tmTheme` | `~/.config/bat/themes/Fox ML.tmTheme` |
| Lazygit | `templates/lazygit/config.yml` | `~/.config/lazygit/config.yml` |
| Git delta | `templates/git/delta.gitconfig` | `~/.config/git/delta-foxml.gitconfig` |
| OpenCode | `templates/opencode/foxml.json` | `~/.config/opencode/themes/foxml.json` |
| Codex CLI | `templates/codex/foxml.tmTheme` | `~/.codex/themes/foxml.tmTheme` |
| Claude Code | `templates/claude/foxml-theme.json`, `templates/claude/statusline.sh`, `shared/claude/mods/desk-notebook/` | `~/.claude/themes/foxml.json`, `~/.claude/statusline.sh`, `~/.claude/mods/desk-notebook/` |
| ReGreet (login) | `templates/regreet/regreet.css` | `/etc/greetd/regreet.css` (sudo) |

### Codex CLI

For Codex CLI, select `foxml` once with `/theme` (or set `theme = "foxml"`
under `[tui]` in `~/.codex/config.toml`). Code blocks use the active palette;
the surrounding interface inherits the terminal's colors. Restart Codex after
a theme swap. With a custom `CODEX_HOME`, copy the rendered theme into
`$CODEX_HOME/themes/foxml.tmTheme`. Edit `templates/codex/foxml.tmTheme` directly;
the legacy `update.sh` capture list does not include Codex.

### Claude Code

Claude Code uses `custom:foxml`, which the installer selects in
`~/.claude/settings.json` once the theme file is deployed. It is `dark-ansi` with
the palette's colors for the box behind your sent messages and for diffs (Paper
uses a light pink box with sage and coral diffs). The installer also sets
`CLAUDE_CODE_TMUX_TRUECOLOR=1`; without it Claude rounds every color to the
256-color palette inside tmux. Restart Claude after a theme swap.

Session tracking and the notebook are covered in [Agent workflows](agent-workflows.md).

### Firefox and Vimium

Firefox's `userContent.css` also themes Vimium: link hints become small paper tags
in the selection color with the typed letters faded, find mode uses the same
selection, and the Vomnibar and its status bar become paper cards in the drawer's
font. They follow a theme swap after a Firefox restart. The installer adds Vimium
through Firefox's own policy file, `/etc/firefox/policies/policies.json` (merged
with anything already there, the previous file kept as `.foxml-bak`), so it
installs from addons.mozilla.org on Firefox's next start; it can be switched off
in Firefox but not removed while that entry is there.

## Shared files

Copied as-is regardless of theme:

| Path | Description |
|------|-------------|
| `shared/hyprland_modules/` | 12 Hyprland modules (keybinds, rules, monitors, scratchpads) |
| `shared/hyprland_scripts/` | 12 helper scripts (lock, startup, yazi, fingerprint) |
| `shared/launchers/` | Toggle scripts for btop, yazi |
| `shared/wallpapers/` | Wallpaper files |
| `shared/nvim_lazy-lock.json` | Neovim plugin lock file |
| `shared/nvim_ftplugin/` | Neovim filetype plugins |
| `shared/waybar_config` | Waybar module/layout config |
| `shared/zsh_aliases.zsh` | Shell aliases |
| `shared/zsh_git.zsh` | Git workflow functions |
| `shared/zsh_paths.zsh` | PATH setup |
| `shared/zsh_conda.zsh` | Conda/mamba init |
| `shared/regreet.toml` | ReGreet greeter config |
| `shared/greetd_hyprland.conf` | Minimal Hyprland session for the greeter |

## Creating a new theme

1. Create a theme directory and copy the defaults:

   ```bash
   mkdir -p themes/My_Theme
   cp themes/Classic/{palette.sh,theme.conf} themes/My_Theme/
   ```

2. Edit the colors in `palette.sh` and the name, type and description in `theme.conf`.
3. Apply it with `./install.sh My_Theme --render`.

The palette defines variables across:
- **Core** — BG, FG, PRIMARY, SECONDARY, ACCENT, SURFACE + variants
- **ANSI** — RED, GREEN, YELLOW, BLUE, CYAN + bright variants
- **ANSI 256** — terminal color indices for zsh prompts
- **Tmux** — `colour216`-style palette
- **App overrides** — per-app background tweaks (dunst, spicetify, vencord)
- **Font** — `FONT_FAMILY` (default `MonaspiceKr Nerd Font`)
- **Metadata** — NVIM_STYLE, KITTY_BG_OPACITY, POPUP_BG_OPACITY, VSCODE_UI_THEME
- **Aesthetic knobs** — ROUNDING, BLUR_SIZE, BLUR_PASSES, GAP_IN, GAP_OUT, BORDER_SIZE (live-tunable via `theme-tweak`)

### Changing the font

Set `FONT_FAMILY` in `palette.sh` to any installed Nerd Font:

```bash
FONT_FAMILY="MonaspiceKr Nerd Font"    # default — Monaspace Krypton (also Ne / Ar / Xe / Rn)
FONT_FAMILY="Hack Nerd Font"           # blocky, sturdy
FONT_FAMILY="JetBrainsMono Nerd Font"  # clean, rounded
FONT_FAMILY="IBM Plex Mono Nerd Font"  # industrial, wide
```

This updates all templated configs. Some shared configs reference fonts directly. Check GTK settings, `regreet.toml` and Hyprland settings as well when changing fonts.

See `themes/Classic/palette.sh` for the full variable list.
