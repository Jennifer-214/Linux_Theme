import QtQuick

QtObject {
    readonly property bool paperDetails: "{{LITTLE_DETAILS}}" === "fox-little-details-on"
    readonly property real scrollGutter: {{DRAWER_SCROLL_GUTTER}}
    readonly property color background: "#{{BG}}"
    readonly property color surface: "#{{BG_DARK}}"
    readonly property color ink: "#{{FG}}"
    readonly property color muted: "#{{FG_DIM}}"
    readonly property color line: "#{{ROFI_BORDER}}"
    readonly property color selection: "#{{BG_HIGHLIGHT}}"
    readonly property color focusFill: Qt.alpha("#{{SELECTION}}", Math.min({{ROFI_SELECTED_ALPHA}}, .55))
    readonly property color detailAccent: "#{{WAYBAR_WS_ACTIVE}}"
    readonly property real selectionOpacity: {{ROFI_SELECTED_ALPHA}}
    readonly property color accent: "#{{PRIMARY}}"
    readonly property color error: "#{{RED}}"
    readonly property color success: "#{{OK}}"
    readonly property string fontFamily: "{{FONT_FAMILY}}"
    readonly property string headingFont: "{{HYPRLOCK_CLOCK_FONT}}"
    readonly property int radius: {{ROUNDING}}
}
