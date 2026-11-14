I didnt make these, I dont claim to have, I found it on google images and liked the pictures.

The `foxml_paper_soft.png`, `foxml_paper_tree.png`, and `foxml_paper_quiet.png`
companion set was generated with the built-in imagegen tool. The existing cat
wallpaper was used as an edit target/style reference; its original provenance
remains as stated above. Generation prompts are in
`shared/wallpapers/paper-prompts.json`. Untouched generated originals are archived
under `source/`; the monitor tools create separate resolution variants at install time.

Paper now defaults to `foxml_paper_botanical.png`, with the existing colored-pencil
tree on displays to the left and quiet paper on the right. This wallpaper and
`shared/quickshell/desk/paper-sprig.png` were generated with the built-in imagegen
tool using the tree as a style reference. Their prompts are saved in
`shared/wallpapers/botanical-prompts.json`. The older cat artwork remains available.
The tree's pencil pigment was strengthened in place so its branches and leaves
remain visible through a 70% opaque terminal; that edit's prompt is saved there too.

The subtle-color set uses `foxml_paper_botanical_color.png` on the primary
display, the existing tree on the left, and `foxml_paper_flower.png` on the right.
Muted sage leaves and dusty rose petals add color to the same warm paper.
Both variants were edited with the built-in imagegen tool; originals remain
available. Full prompts are in `paper-color-prompts.json`.

All deployable bases now have 4K pixel dimensions: 3840×2160 for landscape and
2160×3840 for portrait. Smaller originals are archived under `source/`.
The Paper variants use a local ImageMagick pencil pass that retains the original
hatching, adds fine paper tooth and subtle fibers, then resizes to exact 4K.
Small handwritten margin notes appear on the botanical studies. This is local
processing and upscaling, not a claim of native 4K generation. Processing methods,
dimensions and checksums are in `4k-processing.json`; reproduce the Paper pass
with `python3 scripts/upscale-wallpapers.py --paper-sketch --apply`.
