# Themes

`retro-amber` is the default. `Classic` and `Paper` are also maintained.

**The other themes are work-in-progress / unfinished.** They apply at the palette level (colors reach the templated apps), but they are not fully realized: the theming surfaces are fragmented — waybar, GTK/thunar, folder icons, the cursor, and the wallpaper daemon are each handled separately, with no unified pipeline. Treat them as experimental.

| Theme | Status |
| --- | --- |
| `retro-amber` | Finished — default; amber phosphor terminal, text-mode Quickshell, Firefox, lock screen, optional whole-screen CRT (`desk-crt on`) |
| `Classic` | Finished, maintained |
| `Paper` | WIP — graphite pencil on white paper; monochrome, signatures darkest, light ANSI tints for git / diagnostics |
| `Rose` | WIP / unfinished |
| `Cave_Data_Center` | WIP / unfinished |
| `Amsterdam_Orange` | WIP / unfinished — Optiver-inspired (scarlet on navy) |
| `Bubblegum` | WIP / unfinished — saturated bubblegum pink + orchid |

## Switching themes

```bash
./swap.sh <Theme>    # or ./swap.sh for a picker with colour previews
```

It re-renders the templates with the chosen theme's palette and redeploys them, then reloads Hyprland, the bar,
notifications and tmux. Restart Neovim and Claude sessions afterwards; open ones keep the old colours. If live
`~/.config` edits would be overwritten the swap stops; `./swap.sh --full <Theme>` overwrites them.
