#pragma once

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <fstream>
#include <string>

namespace fox_install {

inline void sync_gtk_font(const Context& ctx) {
    if (sh::dry_run() || !sh::have("gsettings")) return;
    std::ifstream settings(ctx.config_home / "gtk-3.0/settings.ini");
    std::string line, font;
    bool in_settings = false;
    while (std::getline(settings, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty() && line.front() == '[') in_settings = line == "[Settings]";
        if (in_settings && line.rfind("gtk-font-name=", 0) == 0)
            font = line.substr(14);
    }
    if (font.empty()) return;
    const std::string schema = "org.gnome.desktop.interface";
    std::string previous;
    if (!sh::capture({"gsettings", "get", schema, "font-name"}, previous)) return;
    if (previous == "'" + font + "'\n") return;
    // Desktop settings override settings.ini through the settings portal.
    // Preserve the old GVariant value before synchronizing that override.
    const auto backup = ctx.backup_dir / "gsettings/org.gnome.desktop.interface.font-name";
    std::error_code ec;
    if (!std::filesystem::exists(backup, ec) && !idem::write_atomic(backup, previous)) {
        ui::warn("GTK font left unchanged: desktop preference backup failed");
        return;
    }
    if (sh::run({"gsettings", "set", schema, "font-name", font}) == 0)
        ui::ok("GTK desktop font synchronized with settings.ini");
    else
        ui::warn("GTK desktop font could not be synchronized");
}

}  // namespace fox_install
