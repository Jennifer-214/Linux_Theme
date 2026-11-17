# Screenshot capture notes

The README gallery was refreshed on **2026-11-17** from commit `3b71d9a`, using
`themes/retro-amber/palette.sh`, the current application templates and shared
Neovim/Quickshell modules.

Captures run at 1920×1080 in a separate, nested Hyprland session. Application
configuration, Firefox's profile, work records and cache are staged in a
temporary directory. The installed desktop configuration is not redeployed.
The pointer uses `foxml-retro-cursors` at the configured 30-pixel size.

| Image | What is shown |
| --- | --- |
| `retro_desktop.png` | Current Quickshell bar and Workbench drawer, wallpaper and Neovim |
| `retro_terminal.png` | Rendered Kitty shaders, Zsh prompt and tmux footer, with `desk help` and a palette directory listing |
| `retro_firefox.png` | Rendered userChrome/userContent styles in a clean Firefox profile; weather, sponsored content and the empty bookmarks toolbar are hidden through browser preferences |
| `retro_lock.png` | Rendered Hyprlock configuration and boot/status helpers in the nested session; fingerprint authentication is disabled for the preview |
| `retro_nvim.png` | Rendered Neovim configuration, current desk modules and installed plugins, with Neo-tree and repository source |
| `retro_telescope.png` | Telescope searching `src/desk-common` with a source preview |
| `review.png` | Current review UI comparing working changes in a temporary sample queue project |
| `notebook.png` | Three sample pages emitted by the notebook's real drawing code, displayed side by side in Kitty |

Bar helper outputs use the `today` sample data from `tests/bar_preview.py`;
the bar's layout and drawing code are the current production QML. Sample counts
and the sample clock are illustrative. The lock screen's system summary reads
the capture machine. No private browser history or agent conversation is used.

The notebook text comes from:

```bash
python3 tests/notebook_preview.py --theme retro-amber --colour
```

The captured pages are **front page**, **project page · figures** and **files ·
only what needs review**. The helper reports that its appearance assertions are
written for Paper; drawing the retro scenes is not a passing run of those tests.

The unused `paper_desktop.png`, `paper_firefox.png` and `paper_lock.png` images
were removed. The former Paper review and notebook images were replaced with
retro captures. Development mockups under `previews/soft-paper/` remain separate
from this gallery.
