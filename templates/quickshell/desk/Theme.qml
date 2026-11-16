import QtQuick

QtObject {
    readonly property bool paperDetails: "{{LITTLE_DETAILS}}" === "fox-little-details-on"
    // paper | retro | plain: which drawn marks a theme uses (sprig or block cursor, leaf or block, …).
    readonly property string style: "{{DESK_STYLE}}"
    readonly property bool retro: style === "retro"
    // Retro draws on Big Blue Term's design grid: one character is 8×12 px at pixelSize 12, and the font is crisp
    // only at whole multiples of that cell (12, 24, 36), drawn without antialiasing, never synthesised bold or italic.
    readonly property int cell: 12
    readonly property int cellW: 8
    readonly property int textRender: retro ? Text.NativeRendering : Text.QtRendering
    function px(size) { return retro ? (size >= 30 ? 36 : size >= 18 ? 24 : 12) : size; }
    // The drawer hangs from the bar inside a bar window sized for it up front (no resize, no lag on open), and the
    // bar stays above notifications. Behaviour, not decoration: retro has it without Paper's little details.
    readonly property bool hangingDrawer: paperDetails || style === "retro"
    readonly property real scrollGutter: {{DRAWER_SCROLL_GUTTER}}
    // Inverse video: dark ink on the theme's ink colour (retro's bar is a solid amber strip with dark text).
    property bool inverted: false
    readonly property color background: inverted ? "#{{FG}}" : "#{{BG}}"
    readonly property color surface: "#{{BG_DARK}}"
    readonly property color ink: inverted ? "#{{BG}}" : "#{{FG}}"
    // Retro's dim step is too faint for words on the near-black, so its muted text is one step brighter.
    readonly property color muted: inverted ? Qt.alpha("#{{BG}}", .8) : retro ? "#{{SECONDARY}}" : "#{{FG_DIM}}"
    readonly property color line: inverted ? "#{{BG}}" : "#{{ROFI_BORDER}}"
    readonly property color selection: "#{{BG_HIGHLIGHT}}"
    readonly property color highlight: inverted ? Qt.alpha("#{{BG}}", .22) : "#{{SELECTION}}"
    readonly property color tooltipFill: Qt.alpha(background, {{TOOLTIP_BG_OPACITY}})
    readonly property color hoverFill: Qt.alpha(highlight, .6)
    readonly property color focusFill: Qt.alpha("#{{SELECTION}}", paperDetails ? {{ROFI_SELECTED_ALPHA}} : Math.min({{ROFI_SELECTED_ALPHA}}, .55))
    readonly property color detailAccent: inverted ? "#{{BG}}" : "#{{WAYBAR_WS_ACTIVE}}"
    // The commit garden's five shades, from an empty day to the busiest.
    // Inverse video draws every state in the dark ink (amber states on an amber bar would vanish).
    readonly property var gardenShades: inverted ? ["#{{BG}}", "#{{BG}}", "#{{BG}}", "#{{BG}}", "#{{BG}}"]
        : ["#{{GARDEN_0}}", "#{{GARDEN_1}}", "#{{GARDEN_2}}", "#{{GARDEN_3}}", "#{{GARDEN_4}}"]
    readonly property real selectionOpacity: {{ROFI_SELECTED_ALPHA}}
    readonly property color accent: inverted ? "#{{BG}}" : "#{{PRIMARY}}"
    readonly property color botanicalInk: inverted ? "#{{BG}}" : "#{{GREEN}}"
    readonly property color error: inverted ? "#{{BG}}" : "#{{RED}}"
    readonly property color warning: inverted ? "#{{BG}}" : "#{{WARN}}"
    readonly property color success: inverted ? "#{{BG}}" : "#{{OK}}"
    readonly property string fontFamily: "{{FONT_FAMILY}}"
    readonly property string headingFont: "{{HYPRLOCK_CLOCK_FONT}}"
    readonly property int radius: {{ROUNDING}}
}
