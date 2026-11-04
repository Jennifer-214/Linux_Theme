#pragma once

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../core/backup.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <fstream>
#include <string>

namespace fox_install {

inline void sync_gtk_preference(const Context& ctx, const std::string& ini_key,
                                const std::string& preference, const std::string& label) {
    if (sh::dry_run() || !sh::have("gsettings")) return;
    std::ifstream settings(ctx.config_home / "gtk-3.0/settings.ini");
    std::string line, value;
    bool in_settings = false;
    while (std::getline(settings, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (!line.empty() && line.front() == '[') in_settings = line == "[Settings]";
        if (in_settings && line.rfind(ini_key + "=", 0) == 0)
            value = line.substr(ini_key.size() + 1);
    }
    if (value.empty()) return;
    const std::string schema = "org.gnome.desktop.interface";
    std::string previous;
    if (!sh::capture({"gsettings", "get", schema, preference}, previous)) return;
    if (previous == "'" + value + "'\n") return;
    // Desktop settings override settings.ini through the settings portal.
    // Preserve the old GVariant value before synchronizing that override.
    const auto backup = ctx.backup_dir / ("gsettings/org.gnome.desktop.interface." + preference);
    std::error_code ec;
    if (!std::filesystem::exists(backup, ec) && !idem::write_atomic(backup, previous)) {
        ui::warn("GTK " + label + " left unchanged: desktop preference backup failed");
        return;
    }
    if (sh::run({"gsettings", "set", schema, preference, value}) == 0)
        ui::ok("GTK desktop " + label + " synchronized with settings.ini");
    else
        ui::warn("GTK desktop " + label + " could not be synchronized");
}

inline void sync_gtk_font(const Context& ctx) {
    sync_gtk_preference(ctx, "gtk-font-name", "font-name", "font");
}

inline void sync_gtk_icon_theme(const Context& ctx) {
    sync_gtk_preference(ctx, "gtk-icon-theme-name", "icon-theme", "icons");
}

inline void refresh_gtk_icon_cache(const Context& ctx) {
    if (sh::dry_run() || !sh::have("gtk-update-icon-cache")) return;
    std::ifstream settings(ctx.config_home / "gtk-3.0/settings.ini");
    std::string line, name;
    while (std::getline(settings,line))
        if (line.rfind("gtk-icon-theme-name=",0)==0) name=line.substr(20);
    if (name.empty() || name.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")!=std::string::npos) return;
    const auto icons=ctx.home/".local/share/icons"/name;
    if (!std::filesystem::exists(icons/"index.theme")) return;
    if (!snapshot_one(ctx,icons/"icon-theme.cache")) {
        ui::warn("Icon cache left unchanged: its backup failed");return;
    }
    if (sh::run({"gtk-update-icon-cache","-f","-t",icons.string()})!=0)
        ui::warn("Icon cache could not be refreshed");
}

}  // namespace fox_install
