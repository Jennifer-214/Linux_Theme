#include "../modules/firefox_appearance.hpp"
#include <fstream>
#include <iostream>
#include <unistd.h>

namespace fs = std::filesystem;
namespace fox_install::state {
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
    fox_install::Context ctx;
    ctx.home = root / "home";
    ctx.config_home = ctx.home / "custom-config";
    ctx.backup_dir = root / "backup";
    ctx.rendered_dir = root / "rendered";
    ctx.render_ran = ctx.render_ok = true;
    const auto legacy = ctx.home / ".mozilla/firefox/old.default-release";
    const auto xdg = ctx.config_home / "mozilla/firefox/new.default-release";
    fs::create_directories(legacy);
    bool ok = fox_install::firefox_appearance::profile(ctx) == legacy;
    fs::create_directories(xdg);
    ok &= fox_install::firefox_appearance::profile(ctx) == xdg;
    const auto source = ctx.rendered_dir / "firefox/userChrome.css";
    const auto target = xdg / "chrome/userChrome.css";
    const auto snapshot = ctx.backup_dir / "custom-config/mozilla/firefox/new.default-release/chrome/userChrome.css";
    put(target, "old css"); put(source, "new css");
    put(ctx.rendered_dir / "firefox/userContent.css", "new content css");
    put(xdg / "user.js", "keep preferences");
    put(xdg / "sessionstore.jsonlz4", "keep session");
    ok &= fox_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "new css" && read(snapshot) == "old css";
    ok &= read(xdg / "chrome/userContent.css") == "new content css";
    put(source, "newer css");
    ok &= fox_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "newer css" && read(snapshot) == "old css";
    ok &= read(xdg / "user.js") == "keep preferences";
    ok &= read(xdg / "sessionstore.jsonlz4") == "keep session";
    ctx.backup_dir = root / "blocked"; put(ctx.backup_dir, "not a directory");
    put(source, "blocked css");
    ok &= !fox_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "newer css";
    fox_install::sh::set_dry_run(true);
    ok &= fox_install::firefox_appearance::sync_styles(ctx);
    fox_install::sh::set_dry_run(false);
    ok &= read(target) == "newer css";
    ctx.render_ran = ctx.render_ok = false;
    ok &= !fox_install::firefox_appearance::sync_styles(ctx);
    ok &= read(target) == "newer css";
    ctx.render_ran = ctx.render_ok = true;
    ctx.home = root / "no-profile"; ctx.config_home = ctx.home / ".config";
    ok &= fox_install::firefox_appearance::sync_styles(ctx);
    ok &= !fs::exists(ctx.home);
    fs::remove_all(root);
    std::cout << (ok ? "Firefox appearance backup deployment: OK\n" : "Firefox appearance backup deployment: FAILED\n");
    return ok ? 0 : 1;
}
