// modules/welcome_banner.cpp — bake a custom name banner into welcome.zsh.
//
// The zsh splash draws a half-block banner (default "FOX OS") to the right of
// the cat. This module lets the user pick their own text once, at install:
// it constructs the three banner rows from banner_font's glyph table and
// splices them into the `# foxml:welcome-banner` block of the deployed +
// rendered welcome.zsh. The choice is stored in ~/.config/foxml/welcome.conf
// so reinstalls stay non-interactive. Every run re-splices (incl. the default),
// so the template's baked block is just the pre-install fallback.

#include "banner_font.hpp"
#include "../core/context.hpp"
#include "../core/splice.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <system_error>

namespace fs = std::filesystem;

namespace fox_install {
namespace {

// Parse WELCOME_TEXT="..." out of the sidecar. Empty if absent/unset.
std::string read_sidecar(const fs::path& p) {
    std::ifstream in(p);
    if (!in) return {};
    std::string line;
    const std::string key = "WELCOME_TEXT=";
    while (std::getline(in, line)) {
        auto pos = line.find(key);
        if (pos == std::string::npos) continue;
        std::string v = line.substr(pos + key.size());
        if (!v.empty() && v.front() == '"') v.erase(0, 1);
        if (!v.empty() && v.back()  == '"') v.pop_back();
        return v;
    }
    return {};
}

void write_sidecar(const fs::path& p, const std::string& text) {
    std::error_code ec;
    fs::create_directories(p.parent_path(), ec);
    fs::path tmp = p;
    tmp += ".tmp";
    {
        std::ofstream w(tmp);
        w << "WELCOME_TEXT=\"" << text << "\"\n";
    }
    fs::rename(tmp, p, ec);
    if (ec) fs::remove(tmp, ec);
}

}  // namespace

void run_welcome_banner(Context& ctx) {
    ui::section("Welcome banner");

    fs::path sidecar = ctx.config_home / "foxml/welcome.conf";
    std::string stored = read_sidecar(sidecar);

    std::string chosen;
    if (!stored.empty()) {
        chosen = stored;                          // reinstall: keep prior choice
    } else if (ui::tty() && !ctx.assume_yes && !sh::dry_run()) {
        std::cout << "  banner text (A-Z 0-9, blank = FOX OS): " << std::flush;
        std::string line;
        std::getline(std::cin, line);
        chosen = line.empty() ? std::string("FOX OS") : line;
    } else {
        chosen = "FOX OS";
    }

    std::string text = sanitize_banner_text(chosen);

    if (sh::dry_run()) {
        ui::substep("[dry-run] welcome banner would be \"" + text + "\"");
        return;
    }

    write_sidecar(sidecar, text);                 // persist for reinstalls

    BannerBlock b = build_banner(text);
    std::string content =
        "  local bw=" + std::to_string(b.width) + "\n" +
        "  local b1=\"" + b.r1 + "\"\n" +
        "  local b2=\"" + b.r2 + "\"\n" +
        "  local b3=\"" + b.r3 + "\"";

    const std::string begin = "# foxml:welcome-banner-begin";
    const std::string end   = "# foxml:welcome-banner-end";
    bool ok = splice_sentinel(ctx.config_home  / "zsh/welcome.zsh", begin, end, content);
    splice_sentinel(ctx.rendered_dir / "zsh/welcome.zsh", begin, end, content);

    if (ok) ui::ok("welcome banner → \"" + text + "\"");
    else    ui::warn("welcome.zsh missing sentinel — banner unchanged");
}

}  // namespace fox_install
