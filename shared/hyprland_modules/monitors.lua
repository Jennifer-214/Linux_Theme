-- ╭──────────────────────────────────────────────────────────────────╮
-- │                          Monitors                                │
-- ╰──────────────────────────────────────────────────────────────────╯
-- Default: auto-detect every monitor at its preferred mode and scale 1.
-- To override per-machine, uncomment one of the examples below.
--
-- Format: monitor = NAME, RESOLUTION@HZ, POSITION, SCALE
-- Find your monitor name with:  hyprctl monitors all

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

-- Examples:
-- monitor = eDP-1, 3840x2160@60, 0x0, 1.5         # 15" 4K laptop panel
-- monitor = eDP-1, 2736x1824@60, 0x0, 1.33        # Surface Pro panel
-- monitor = HDMI-A-1, 1920x1080@60, 1920x0, 1     # external 1080p to the right
