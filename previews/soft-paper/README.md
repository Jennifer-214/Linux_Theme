# Soft Paper preview

Open `index.html` in a browser. Everything is local and the controls change only
the mockups. No desktop settings or installed app configurations are changed.

- Paper: compare 70%, 75%, and 80% terminal background opacity; switch artwork,
  hide the terminal, or turn off light blur.
- Find anything: search the example actions and use arrow keys and Enter.
- Useful notices: click a result to preview its destination.
- Shapes (`shapes.html`): compare wide-banner outlines and three drawer silhouettes.
- The optional pencil-corner checkbox compares a small wallpaper corner mark.

The tree is the left Acer composition, the sprig is the laptop composition, and
the right Dell uses quiet warm paper. The monitor strip is illustrative.
Browser compositing approximates opacity; it does not reproduce Hyprland blur
exactly. Text opacity remains 100%. Example projects, jobs, and results are
demonstration data, not reports of current work.

The current `shared/wallpapers/foxml_paper_botanical.png` wallpaper and transparent
`shared/quickshell/foxml/paper-sprig.png` illustration were created with the built-in
imagegen tool using the existing colored-pencil tree as a style reference.
Their full prompts are in `shared/wallpapers/botanical-prompts.json`; the earlier
companion-set prompts remain in `shared/wallpapers/paper-prompts.json`.
The tree uses stronger pencil pigment to remain visible behind 70% opaque paper.
The preview references production assets directly and uses locally installed Monaspice fonts.

`native-bar.png` and `native-drawer.png` capture the actual QML components with
isolated example data. They show the selected rounded wide banners and turned
page corner. No private desktop contents are included.

`notification-stamp.png` renders the native notification stamp and its pencil
sprig using Cairo and Pango with example text.
