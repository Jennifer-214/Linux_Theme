# wallpapers/source/

Untouched originals (or the best available base if true originals were
processed before this directory existed). Treat as read-only — every
wallpaper-editing operation (watermark strip, variant generation,
re-upscaling with a newer model) reads from here and writes a copy
into the parent directory.

`fox-wallpaper --add <path>` copies the input here untouched and then
processes a separate copy. Regenerate everything from these via:

    fox-wallpaper --regenerate-variants
