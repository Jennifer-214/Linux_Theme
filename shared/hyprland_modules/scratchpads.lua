-- ─── Scratchpads ─────────────────────────────
-- Hyprland 0.54+ block syntax. Each rule = one window class.
-- Float sizes follow the screen they open on: 80% of its width, and a height that blends
-- its height and width (about 880 px on a 1920x1080 laptop, 1150 on a 1440x2560 portrait).


hl.window_rule({
    name = "yazi-scratchpad",
    match = { class = "^(yazi)$" },
    float = true,
    size = { "monitor_w*0.8", "monitor_h*0.28+monitor_w*0.3" },
    center = true,
    workspace = "special:yazi silent",
})


hl.window_rule({
    name = "ncspot-scratchpad",
    match = { class = "^(ncspot)$" },
    float = true,
    size = { "monitor_w*0.8", "monitor_h*0.28+monitor_w*0.3" },
    center = true,
    workspace = "special:music silent",
})


hl.window_rule({
    name = "btop-scratchpad",
    match = { class = "^(btopterm)$" },
    float = true,
    size = { "monitor_w*0.8", "monitor_h*0.28+monitor_w*0.3" },
    center = true,
    workspace = "special:btopterm silent",
})
