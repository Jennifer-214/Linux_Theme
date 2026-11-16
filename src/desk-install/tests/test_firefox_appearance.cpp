#include "../modules/firefox_appearance.hpp"
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <unistd.h>

namespace fs = std::filesystem;
namespace desk_install::state {
bool rendered_is_current(const Context&) { return false; }
}
static void put(const fs::path& p, const std::string& value) {
    fs::create_directories(p.parent_path()); std::ofstream(p) << value;
}
static std::string read(const fs::path& p) {
    std::ifstream f(p); return {std::istreambuf_iterator<char>(f), {}};
}
int main() {
    char pattern[] = "/tmp/fox-firefox-appearance-XXXXXX";
    const char* created = ::mkdtemp(pattern);
    if (!created) return 1;
    const fs::path root(created);
    desk_install::Context ctx;
    ctx.home = root / "home";
    ctx.config_home = ctx.home / "custom-config";
    ctx.backup_dir = root / "backup";
    ctx.rendered_dir = root / "rendered";
    ctx.render_ran = ctx.render_ok = true;
    const auto legacy = ctx.home / ".mozilla/firefox/old.default-release";
    const auto xdg = ctx.config_home / "mozilla/firefox/new.default-release";
    fs::create_directories(legacy);
    bool ok = desk_install::firefox_appearance::profile(ctx) == legacy;
    fs::create_directories(xdg);
    ok &= desk_install::firefox_appearance::profile(ctx) == xdg;
    const auto source = ctx.rendered_dir / "firefox/userChrome.css";
    const auto target = xdg / "chrome/userChrome.css";
    const auto snapshot = ctx.backup_dir / "custom-config/mozilla/firefox/new.default-release/chrome/userChrome.css";
    put(target, "old css"); put(source, "new css");
    put(ctx.rendered_dir / "firefox/userContent.css", "new content css");
    put(xdg / "user.js", "keep preferences");
    put(xdg / "sessionstore.jsonlz4", "keep session");
    ok &= desk_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "new css" && read(snapshot) == "old css";
    ok &= read(xdg / "chrome/userContent.css") == "new content css";
    put(source, "newer css");
    ok &= desk_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "newer css" && read(snapshot) == "old css";
    ok &= read(xdg / "user.js") == "keep preferences";
    ok &= read(xdg / "sessionstore.jsonlz4") == "keep session";
    ctx.backup_dir = root / "blocked"; put(ctx.backup_dir, "not a directory");
    put(source, "blocked css");
    ok &= !desk_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "newer css";
    desk_install::sh::set_dry_run(true);
    ok &= desk_install::firefox_appearance::sync_styles(ctx);
    desk_install::sh::set_dry_run(false);
    ok &= read(target) == "newer css";
    ctx.render_ran = ctx.render_ok = false;
    ok &= !desk_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "newer css";
    ctx.render_ran = ctx.render_ok = true;
    ctx.home = root / "no-profile"; ctx.config_home = ctx.home / ".config";
    ok &= desk_install::firefox_appearance::sync_styles(ctx);
    ok &= !fs::exists(ctx.home);

    // Firefox's own index names the profile it opens; an older Default=1 profile and folder names lose to it.
    ctx.home = root / "listed"; ctx.config_home = ctx.home / ".config";
    const auto base = ctx.config_home / "mozilla/firefox";
    const auto opened = base / "a1b2c3d4.custom", older = base / "k9x8w7v6.default", named = base / "zz.default-release";
    fs::create_directories(opened); fs::create_directories(older); fs::create_directories(named);
    put(base / "profiles.ini",
        "[Install0123456789ABCDEF]\r\nDefault=a1b2c3d4.custom\r\nLocked=1\r\n\r\n"
        "[Profile1]\r\nName=default\r\nIsRelative=1\r\nPath=k9x8w7v6.default\r\nDefault=1\r\n\r\n"
        "[Profile0]\r\nName=default-release\r\nIsRelative=1\r\nPath=zz.default-release\r\n");
    ok &= desk_install::firefox_appearance::profile(ctx) == opened;
    put(base / "profiles.ini",
        "[Profile0]\nName=default-release\nIsRelative=1\nPath=zz.default-release\n\n"
        "[Profile1]\nName=default\nIsRelative=1\nPath=k9x8w7v6.default\nDefault=1\n");
    ok &= desk_install::firefox_appearance::profile(ctx) == older;
    const auto elsewhere = root / "elsewhere.profile"; fs::create_directories(elsewhere);
    put(base / "profiles.ini", "[Profile0]\nIsRelative=0\nPath=" + elsewhere.string() + "\nDefault=1\n");
    ok &= desk_install::firefox_appearance::profile(ctx) == elsewhere;
    put(base / "profiles.ini", "[Install1]\nDefault=gone.default-release\n");
    ok &= desk_install::firefox_appearance::profile(ctx) == named;

    // The website appearance rides in the theme's block: only a theme that names one writes it, and a theme after it
    // hands Firefox its default back for one run (user.js cannot unset a pref), then writes its block as before.
    using desk_install::firefox_appearance::theme_block;
    const std::string colors = "// >>> FoxML find colors\nuser_pref(\"ui.textHighlightBackground\", \"#ffb000\");\n"
                               "// <<< FoxML find colors\n";
    const std::string pref = "user_pref(\"layout.css.prefers-color-scheme.content-override\", ";
    const auto with = [&](const char* value) {
        return std::string(colors).insert(colors.rfind("// <<<"), pref + value + ");\n");
    };
    ok &= theme_block(colors, "", "") == colors;
    ok &= theme_block(colors, "", colors) == colors;
    ok &= theme_block(colors, "dark", "") == with("0");
    ok &= theme_block(colors, "dark", with("0")) == with("0");
    ok &= theme_block(colors, "light", "") == with("1") && theme_block(colors, "auto", "") == with("2");
    ok &= theme_block(colors, "sepia", "") == colors;
    ok &= theme_block(colors, "", with("0")) == with("2");
    ok &= theme_block(colors, "", with("2")) == colors;

    // A Firefox that never ran has no profile: the one its first start opens is made, once, where it reads profiles,
    // listed as the default and holding the compatibility.ini Firefox's first run needs to claim it.
    std::string bin_pattern = (fs::current_path() / ".fox-firefox-bin-XXXXXX").string();  // /tmp is noexec here
    const char* bin_made = ::mkdtemp(bin_pattern.data());
    if (!bin_made) return 1;
    const fs::path bin(bin_made);
    put(bin / "firefox", "#!/bin/sh\nexit 1\n");  // found on PATH, never run
    fs::permissions(bin / "firefox", fs::perms::owner_all);
    const std::string saved_path = std::getenv("PATH") ? std::getenv("PATH") : "";
    ::setenv("PATH", bin.c_str(), 1);
    using desk_install::firefox_appearance::ensure_profile;
    std::string why;
    ctx.home = root / "fresh"; ctx.config_home = ctx.home / ".config";
    const auto made = ensure_profile(ctx, why);
    const auto made_base = ctx.config_home / "mozilla/firefox";
    const auto name = made.filename().string();
    ok &= !made.empty() && made.parent_path() == made_base && fs::is_directory(made);
    ok &= name.size() == 24 && name.compare(8, std::string::npos, ".default-release") == 0;
    ok &= read(made_base / "profiles.ini") == "[Profile0]\nName=default-release\nIsRelative=1\nPath=" + name +
                                              "\nDefault=1\n\n[General]\nStartWithLastProfile=1\nVersion=2\n";
    ok &= read(made / "compatibility.ini") == "[Compatibility]\n";
    ok &= (fs::status(made).permissions() & (fs::perms::group_all | fs::perms::others_all)) == fs::perms::none;
    ok &= desk_install::firefox_appearance::profile(ctx) == made;
    ok &= ensure_profile(ctx, why) == made;
    int profiles = 0;
    for (const auto& entry : fs::directory_iterator(made_base)) profiles += entry.is_directory();
    ok &= profiles == 1;
    // The old folder when it is there: Firefox reads it before the XDG one.
    ctx.home = root / "legacy-home"; ctx.config_home = ctx.home / ".config";
    fs::create_directories(ctx.home / ".mozilla/firefox");
    ok &= ensure_profile(ctx, why).parent_path() == ctx.home / ".mozilla/firefox";
    ok &= !fs::exists(ctx.config_home / "mozilla");
    // An index Firefox wrote is left as it is, and the reason is given.
    ctx.home = root / "stale"; ctx.config_home = ctx.home / ".config";
    const std::string stale = "[Profile0]\nName=default-release\nIsRelative=1\nPath=gone.default-release\nDefault=1\n";
    put(ctx.config_home / "mozilla/firefox/profiles.ini", stale);
    why.clear();
    ok &= ensure_profile(ctx, why).empty() && why.find("profiles.ini") != std::string::npos;
    ok &= read(ctx.config_home / "mozilla/firefox/profiles.ini") == stale;
    // A dry run makes nothing, and neither does a machine without Firefox.
    ctx.home = root / "dry"; ctx.config_home = ctx.home / ".config";
    desk_install::sh::set_dry_run(true);
    ok &= ensure_profile(ctx, why).empty() && !fs::exists(ctx.home);
    desk_install::sh::set_dry_run(false);
    ::setenv("PATH", (root / "no-such-bin").c_str(), 1);
    ctx.home = root / "no-firefox"; ctx.config_home = ctx.home / ".config";
    why.clear();
    ok &= ensure_profile(ctx, why).empty() && !why.empty() && !fs::exists(ctx.home);
    ::setenv("PATH", saved_path.c_str(), 1);
    fs::remove_all(bin);
    fs::remove_all(root);
    std::cout << (ok ? "Firefox appearance backup deployment: OK\n" : "Firefox appearance backup deployment: FAILED\n");
    return ok ? 0 : 1;
}
