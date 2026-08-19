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
#include <map>
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

// palette.sh as a KEY=value map (values are bare hex; tolerant of quoted/array
// lines we don't use). Lets the module resolve render tokens at runtime —
// welcome_banner runs post-render, so the hyprlock spans need literal hex.
std::map<std::string, std::string> read_palette(const fs::path& p) {
    std::map<std::string, std::string> m;
    std::ifstream in(p);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = line.substr(0, eq);
        std::string v = line.substr(eq + 1);
        while (!v.empty() && (v.back() == '\r' || v.back() == ' ' || v.back() == '\t'))
            v.pop_back();
        if (v.size() >= 2 && v.front() == '"' && v.back() == '"') v = v.substr(1, v.size() - 2);
        m[k] = v;
    }
    return m;
}

// Replace every {{KEY}} in s from the palette map; unknown tokens left intact.
std::string resolve_tokens(const std::string& s,
                           const std::map<std::string, std::string>& pal) {
    std::string out;
    for (std::size_t i = 0; i < s.size();) {
        if (s[i] == '{' && i + 1 < s.size() && s[i + 1] == '{') {
            auto end = s.find("}}", i + 2);
            if (end != std::string::npos) {
                std::string key = s.substr(i + 2, end - (i + 2));
                auto it = pal.find(key);
                out += (it != pal.end()) ? it->second : s.substr(i, end + 2 - i);
                i = end + 2;
                continue;
            }
        }
        out += s[i++];
    }
    return out;
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
        ui::substep("[dry-run] banner \"" + text +
                    "\" → welcome.zsh + hyprlock.conf + nvim/init.lua");
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

    // Same WELCOME_TEXT drives the lock screen + editor dashboard ([I-06]),
    // each colorised natively from the shared warm cycle. hyprlock embeds
    // palette hex in pango spans, so resolve the {{TOKEN}}s the colorizer emits
    // against the active palette (post-render: the deployed/rendered copies
    // need literal hex). nvim references highlight groups → no resolution.
    auto pal = read_palette(ctx.palette_path);
    std::string hypr = "    text = " + resolve_tokens(banner_to_hyprlock_text(text), pal);
    {
        const std::string b = "# foxml:hyprlock-brand-begin";
        const std::string e = "# foxml:hyprlock-brand-end";
        bool hok = splice_sentinel(ctx.config_home / "hypr/hyprlock.conf", b, e, hypr);
        splice_sentinel(ctx.rendered_dir / "hyprlock/hyprlock.conf", b, e, hypr);
        if (hok) ui::ok("hyprlock brand → \"" + text + "\"");
        else     ui::warn("hyprlock.conf missing sentinel — brand unchanged");
    }
    {
        std::string seg = banner_to_snacks_blocks(text);
        const std::string b = "-- foxml:nvim-banner-begin";
        const std::string e = "-- foxml:nvim-banner-end";
        bool nok = splice_sentinel(ctx.config_home / "nvim/init.lua", b, e, seg);
        splice_sentinel(ctx.rendered_dir / "nvim/init.lua", b, e, seg);
        if (nok) ui::ok("nvim banner → \"" + text + "\"");
        else     ui::warn("init.lua missing sentinel — nvim banner unchanged");
    }
}

}  // namespace fox_install
