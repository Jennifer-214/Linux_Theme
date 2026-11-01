-- ─── Scratchpads ─────────────────────────────
-- Hyprland 0.54+ block syntax. Each rule = one window class.


hl.window_rule({
    name = "yazi-scratchpad",
    match = { class = "^(yazi)$" },
    float = true,
    size = "1500 900",
    center = true,
    border_size = 0,
    workspace = "special:yazi silent",
})


hl.window_rule({
    name = "ncspot-scratchpad",
    match = { class = "^(ncspot)$" },
    float = true,
    size = "1500 900",
    center = true,
    workspace = "special:music silent",
})


hl.window_rule({
    name = "btop-scratchpad",
    match = { class = "^(btopterm)$" },
    float = true,
    size = "1400 1000",
    workspace = "special:btopterm silent",
})


hl.window_rule({
    name = "waifu-scratchpad",
    match = { class = "^(waifu)$" },
    float = true,
    size = "2000 1400",
    center = true,
    workspace = "special silent",
})
