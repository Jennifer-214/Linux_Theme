# Soft Paper preview

Open `index.html` in a browser. Everything is local and the controls change only
the mockups. No desktop settings or installed app configurations are changed.

- Paper: compare 70%, 75%, and 80% terminal background opacity; switch artwork,
  hide the terminal, or turn off light blur.
- Find anything: search the example actions and use arrow keys and Enter.
- Useful notices: click a result to preview its destination.
- Shapes (`shapes.html`): compare wide-banner outlines and three drawer silhouettes.
- The optional pencil-corner checkbox compares a small wallpaper corner mark.

The tree is the left Acer composition, the cat is the laptop composition, and
the right Dell uses quiet warm paper. The monitor strip is illustrative.
Browser compositing approximates opacity; it does not reproduce Hyprland blur
exactly. Text opacity remains 100%. Example projects, jobs, and results are
demonstration data, not reports of current work.

The three `shared/wallpapers/foxml_paper_{soft,tree,quiet}.png` assets were created with the built-in image_gen
tool, using the existing sleeping-cat wallpaper as a style reference and edit
target respectively. The full generation prompts are saved in `shared/wallpapers/paper-prompts.json`.
The preview references those production assets directly and uses locally installed Monaspice fonts.
