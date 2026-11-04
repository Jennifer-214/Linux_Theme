#pragma once

#include "../core/context.hpp"
#include "../core/backup.hpp"
#include "../core/idempotency.hpp"
#include "../core/state_checks.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"
#include <filesystem>

namespace fox_install::firefox_appearance {

// Share profile discovery between full setup and palette-only deployment.
inline std::filesystem::path profile(const Context& ctx) {
    const auto config = ctx.config_home.empty() ? ctx.home / ".config" : ctx.config_home;
    for (const auto& base : {config / "mozilla/firefox", ctx.home / ".mozilla/firefox"}) {
        std::error_code ec;
        if (!std::filesystem::is_directory(base, ec)) continue;
        std::filesystem::directory_iterator it(base, ec), end;
        while (!ec && it != end) {
            if (it->is_directory(ec) && !ec &&
                it->path().filename().string().find("default-release") != std::string::npos)
                return it->path();
            it.increment(ec);
        }
    }
    return {};
}

// --render does not run Firefox setup. Refresh only its rendered stylesheets,
// without touching preferences, opening windows or restarting the browser.
inline bool sync_styles(const Context& ctx) {
    if (sh::dry_run()) return true;
    if (!((ctx.render_ran && ctx.render_ok) || state::rendered_is_current(ctx))) return false;
    const auto dest = profile(ctx);
    if (dest.empty()) return true;
    bool ok = true, changed = false;
    for (const char* name : {"userChrome.css", "userContent.css"}) {
        const auto source = ctx.rendered_dir / "firefox" / name;
        const auto target = dest / "chrome" / name;
        if (!std::filesystem::is_regular_file(source)) continue;
        if (std::filesystem::exists(target) && idem::read_file(source) == idem::read_file(target)) continue;
        if (!deploy_file_atomic(ctx, source, target)) {
            ui::warn(std::string("Firefox ") + name + " could not be deployed");
            ok = false;
        } else changed = true;
    }
    if (changed) ui::substep("Firefox styles updated; restart Firefox to load them");
    return ok;
}

}  // namespace fox_install::firefox_appearance
