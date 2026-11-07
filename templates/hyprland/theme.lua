-- ╭──────────────────────────────────────────────────────────────────╮
-- │                     Fox ML Theme                                 │
-- ╰──────────────────────────────────────────────────────────────────╯
--
--   ┌─────────────────────────────────────┐
--   │           Color Palette             │
--   ├──────────────┬──────────────────────┤
--   │  bg          │  #{{BG}}             │
--   │  fg          │  #{{FG}}             │
--   │  slate       │  #{{SURFACE}}             │
--   │  peach       │  #{{PRIMARY}}             │
--   │  sage        │  #{{ACCENT}}             │
--   └──────────────┴──────────────────────┘

hl.config({
    -- ─────────────────────────────────────────
    -- General
    -- ─────────────────────────────────────────
    general = {
        gaps_in = {{GAP_IN}},
        gaps_out = {{GAP_OUT}},
        border_size = {{HYPR_BORDER_SIZE}},
        layout = "dwindle",
        col = {
            active_border = { colors = { "rgba({{BLUSH}}ff)", "rgba({{PRIMARY}}ff)" }, angle = 45 }, -- blush → peach (only visible if border_size > 0)
            inactive_border = "rgba({{HYPR_BORDER_INACTIVE}})", -- slate (dimmed)
        },
    },

    -- A new window opens below (or right of) the one in focus, wherever the pointer is
    dwindle = {
        force_split = 2,
    },

    -- ─────────────────────────────────────────
    -- Groups (Tabs)
    -- ─────────────────────────────────────────
    group = {
        insert_after_current = {{SHOW_WELCOME}},
        col = {
            border_active = { colors = { "rgba({{BLUSH}}ff)", "rgba({{PRIMARY}}ff)" }, angle = 45 },
            border_inactive = "rgba({{SURFACE}}66)",
            border_locked_active = "rgba({{RED}}ff)",
            border_locked_inactive = "rgba({{SURFACE}}66)",
        },
        groupbar = {
            enabled = {{SHOW_WELCOME}},
            font_family = "{{FONT_FAMILY}}",
            font_size = 10,
            gradients = {{SHOW_WELCOME}},
            height = 16,
            priority = 3,
            render_titles = {{SHOW_WELCOME}},
            scrolling = {{SHOW_WELCOME}},
            text_color = "rgba({{FG}}ff)",
            col = {
                active = "rgba({{PRIMARY}}bb)",
                inactive = "rgba({{SURFACE}}88)",
                locked_active = "rgba({{RED}}bb)",
                locked_inactive = "rgba({{SURFACE}}88)",
            },
        },
    },

    -- ─────────────────────────────────────────
    -- Decoration
    -- ─────────────────────────────────────────
    decoration = {
        rounding = {{ROUNDING}},
        active_opacity = 1.0,
        inactive_opacity = {{HYPR_INACTIVE_OPACITY}},
        blur = {
            enabled = {{SHOW_WELCOME}},
            size = {{BLUR_SIZE}},
            passes = {{BLUR_PASSES}},
            noise = 0.02,
            contrast = 1.0,
            brightness = 0.97,
            new_optimizations = {{SHOW_WELCOME}},
            xray = false,
        },
        shadow = {
            enabled = {{SHOW_WELCOME}},
            range = {{SHADOW_RANGE}},
            render_power = 3,
            offset = { {{HYPR_SHADOW_OFFSET_X}}, {{HYPR_SHADOW_OFFSET_Y}} },
            color = "rgba({{HYPR_SHADOW_RGB_R}},{{HYPR_SHADOW_RGB_G}},{{HYPR_SHADOW_RGB_B}},{{SHADOW_ALPHA}})",
            color_inactive = "rgba({{HYPR_SHADOW_RGB_R}},{{HYPR_SHADOW_RGB_G}},{{HYPR_SHADOW_RGB_B}},{{HYPR_SHADOW_ALPHA_INACTIVE}})",
        },
        dim_inactive = {{SHOW_WELCOME}},
        dim_strength = {{HYPR_DIM_STRENGTH}},
    },

    animations = {
        enabled = true,
    },

    -- Paper uses the same XCursor assets for clients and restored desktop shapes.
    cursor = { enable_hyprcursor = {{HYPR_CURSOR_ENABLED}} },

    -- ─────────────────────────────────────────
    -- Misc
    -- ─────────────────────────────────────────
    misc = {
        disable_hyprland_logo = {{SHOW_WELCOME}},
    },
})

-- ─────────────────────────────────────────
-- Animations
-- ─────────────────────────────────────────
hl.curve("foxEase",   { type = "bezier", points = { { 0.16, 1.0 }, { 0.3, 1.0 } } })
hl.curve("foxSnap",   { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.0 } } })
hl.curve("foxBounce", { type = "bezier", points = { { {{KITTY_BG_OPACITY}}8, -0.3 }, { 0.265, 1.35 } } })
hl.curve("foxSlow",   { type = "bezier", points = { { 0.0, {{KITTY_BG_OPACITY}} }, { 0.4, 1.0 } } })

hl.curve("foxSettle", { type = "bezier", points = { { 0.22, 1.0 }, { 0.36, 1.05 } } })  -- a soft landing, like paper laid down
hl.animation({ leaf = "windows",     enabled = true, speed = 5,  bezier = "foxSnap", style = "popin 92%" })
hl.animation({ leaf = "windowsIn",   enabled = true, speed = 5,  bezier = "{{HYPR_WIN_CURVE}}", style = "popin 92%" })
hl.animation({ leaf = "windowsOut",  enabled = true, speed = 4,  bezier = "foxEase", style = "popin 80%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 4,  bezier = "foxSnap" })
hl.animation({ leaf = "border",      enabled = true, speed = 12, bezier = "foxSlow" })
-- off: the angle animation kept Hyprland repainting every frame (~11% of a core, measured
-- 2026-10-15), and drew nothing at border_size 0. Borders that are on stay a static gradient.
hl.animation({ leaf = "borderangle", enabled = false })
hl.animation({ leaf = "fade",        enabled = true, speed = 5,  bezier = "foxEase" })
hl.animation({ leaf = "fadeIn",      enabled = true, speed = 4,  bezier = "foxEase" })
hl.animation({ leaf = "fadeOut",     enabled = true, speed = 4,  bezier = "foxEase" })
hl.animation({ leaf = "workspaces",  enabled = true, speed = 5,  bezier = "foxSnap", style = "{{HYPR_WS_ANIM}}" })
hl.animation({ leaf = "layersIn",    enabled = true, speed = 4,  bezier = "foxSnap", style = "slide top" })
hl.animation({ leaf = "layersOut",   enabled = true, speed = 4,  bezier = "foxEase", style = "slide top" })
-- The shared bar surface stays still; its drawers animate inside Quickshell.
hl.layer_rule({ match = { namespace = "^(foxml-bar)$" }, no_anim = true })

-- Cursor theme follows the palette (environment.lua sets the search path + size)
hl.env("XCURSOR_THEME", "{{CURSOR_THEME}}")
hl.env("HYPRCURSOR_THEME", "{{CURSOR_THEME}}")
