#!/bin/bash
# Region screenshot → Edit with Swappy → save/copy.
# NOTE: `set -e` is intentionally NOT used. slurp on cancel exits non-zero
# but we want to handle that path explicitly, not abort with no message.
out_dir="$HOME/Pictures/Screenshots"
mkdir -p "$out_dir"
file="$out_dir/screenshot-$(date +%Y%m%d-%H%M%S).png"

# Region selection. -b = background (transparent), -c = selection border colour.
# slurp exits non-zero AND emits empty output when the user hits Escape;
# without an explicit guard the script previously fed grim an empty
# `-g ""` which is interpreted as "capture everything" — i.e. cancelling
# silently produced a full-screen capture, the opposite of what the user
# asked for.
geom=$(slurp -b 00000000 -c c4956eff 2>/dev/null)
slurp_rc=$?
if (( slurp_rc != 0 )) || [[ -z "$geom" ]]; then
    notify-send -t 2000 "Screenshot" "Cancelled"
    exit 0
fi

sleep 0.1
grim -g "$geom" - | swappy -f - -o "$file"

# Check if file was actually saved (user may have cancelled in swappy too).
if [[ -f "$file" ]]; then
    # The live Wayland clipboard has no size limit, but cliphist (the history
    # picker) silently drops entries over ~5MB — so large 4K/portrait screenshots
    # vanish from clipboard history. Keep the full-res PNG file; if it exceeds the
    # cap, put a compact high-quality JPEG on the clipboard instead so the shot
    # still lands in history (and pastes fine everywhere). Small shots stay PNG.
    if (( $(stat -c%s "$file") > 4500000 )) && command -v magick >/dev/null 2>&1; then
        magick "$file" -quality 92 jpg:- | wl-copy --type image/jpeg
    else
        wl-copy --type image/png < "$file"
    fi
    notify-send -i "$file" "Screenshot saved" "File: $(basename "$file")\nSaved to: ~/Pictures/Screenshots"
fi
