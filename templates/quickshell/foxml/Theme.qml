import QtQuick

QtObject {
    readonly property color background: "#{{BG}}"
    readonly property color surface: "#{{BG_DARK}}"
    readonly property color ink: "#{{FG}}"
    readonly property color muted: "#{{FG_DIM}}"
    readonly property color line: "#{{ROFI_BORDER}}"
    readonly property color selection: "#{{ROFI_SELECTED}}"
    readonly property real selectionOpacity: {{ROFI_SELECTED_ALPHA}}
    readonly property color accent: "#{{PRIMARY}}"
    readonly property color error: "#{{RED}}"
    readonly property color success: "#{{OK}}"
    readonly property string fontFamily: "{{FONT_FAMILY}}"
    readonly property string headingFont: "{{HYPRLOCK_CLOCK_FONT}}"
    readonly property int radius: {{ROUNDING}}
}
