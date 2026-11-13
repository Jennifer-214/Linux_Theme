#include "../modules/workflow_update.hpp"
#include <iostream>

namespace fs = std::filesystem;
namespace work = desk_install::workflow;
int main() {
    auto repo = fs::current_path();
    while (repo != repo.parent_path() && !fs::is_directory(repo / "shared/nvim_lua")) repo = repo.parent_path();
    const auto base = fs::temp_directory_path() / ("workflow-update-test-" + std::to_string(::getpid()));
    fs::create_directories(base / "home");
    ::setenv("XDG_STATE_HOME", (base / "state").c_str(), 1);
    desk_install::Context ctx;
    ctx.home = base / "home"; ctx.config_home = base / "external-config"; ctx.script_dir = repo;
    ctx.shared_dir = repo / "shared"; ctx.templates_dir = repo / "templates";
    ctx.palette_path = repo / "themes/FoxML_Paper/palette.sh";
    const auto target = ctx.config_home / "nvim/lua/foxml/work.lua";
    work::write(target.parent_path() / "mine.lua", "-- my existing module\n");
    fs::create_symlink("mine.lua", target);
    work::write(ctx.home / ".local/bin/fox-work", "old work tool");
    fs::create_symlink("/a/user/owned/command", ctx.home / ".local/bin/fox-drawer");
    auto menu = work::load(repo / "shared/quickshell/foxml/menus.json");
    menu["project_roots"] = work::Json::array({"~/my-projects"});
    work::write(ctx.config_home / "quickshell/foxml/menus.json", menu.dump());
    int failures = 0;
    const auto check = [&](bool ok, const char* message) { if (!ok) { ++failures; std::cerr << "FAIL: " << message << '\n'; } };
    std::string error;
    work::Stage first;
    check(work::prepare(ctx, first, error), error.c_str());
    check(fs::is_symlink(target) && work::bytes(target) == "-- my existing module\n", "preview does not deploy anything");
    work::Stage identical;
    check(work::prepare(ctx, identical, error), error.c_str());
    check(first.plan["plan"] == identical.plan["plan"], "preview token is deterministic");
    const auto previous_umask = ::umask(0077);
    work::Stage restricted;
    check(work::prepare(ctx, restricted, error), error.c_str());
    ::umask(previous_umask);
    check(first.plan["plan"] == restricted.plan["plan"], "generated file permissions and preview tokens do not depend on the caller's umask");
    work::write(target.parent_path() / "mine.lua", "-- changed after preview\n");
    // A symlink target's contents are not overwritten by deployment: its link itself is the target.
    fs::remove(target); work::write(target, "-- edited target after preview\n");
    check(!work::apply(ctx, first, first.plan.value("plan", "")).value("ok", false), "a moved target refuses the entire update");
    check(!fs::exists(ctx.home / ".claude/mods/foxml-paper/hooks/register.tsx"), "refusal does not partially deploy other assets");
    fs::remove(target); fs::create_symlink("mine.lua", target);
    work::Stage second;
    check(work::prepare(ctx, second, error), error.c_str());
    const auto applied = work::apply(ctx, second, second.plan.value("plan", ""));
    check(applied.value("ok", false), applied.dump().c_str());
    check(!fs::is_symlink(target) && work::bytes(target) == work::bytes(repo / "shared/nvim_lua/foxml/work.lua"), "the runtime dependency was installed");
    check(fs::is_symlink(ctx.home / ".local/bin/fox-work") && fs::read_symlink(ctx.home / ".local/bin/fox-work") == "desk-work", "legacy work commands use the same canonical dispatcher");
    check(fs::read_symlink(ctx.home / ".local/bin/fox-drawer") == "/a/user/owned/command", "custom command aliases are preserved");
    check(work::bytes(ctx.home / ".claude/mods/foxml-paper/hooks/build.ts").find(second.clients.value("notebook", "missing")) != std::string::npos,
        "the notebook loaded stamp names the installed bundle");
    check(work::bytes(ctx.home / ".pi/agent/extensions/foxml/build.ts").find(second.clients.value("pi", "missing")) != std::string::npos,
        "pi's stamp is a dependency, not a top-level auto-loaded extension");
    check(work::load(ctx.config_home / "quickshell/foxml/menus.json")["project_roots"] == menu["project_roots"], "menu customization survives deployment");
    const auto current = work::load(work::state_home(ctx) / "current.json");
    check(current.value("bundle", "") == second.plan.value("bundle", ""), "installed versions are recorded after verification");
    const auto installed = work::bytes(target);
    const auto installed_mode = fs::status(target).permissions();
    fs::permissions(target, fs::perms::owner_read | fs::perms::owner_write);
    check(!work::rollback(ctx, applied.value("transaction", "")).value("ok", false), "rollback preserves later permission changes");
    fs::permissions(target, installed_mode);
    work::write(target, "-- a user edit after installation\n");
    check(!work::rollback(ctx, applied.value("transaction", "")).value("ok", false), "rollback refuses to replace later user edits");
    check(work::bytes(target) == "-- a user edit after installation\n", "refused rollback preserves the edit");
    work::write(target, installed);
    const auto restored = work::rollback(ctx, applied.value("transaction", ""));
    check(restored.value("ok", false), restored.dump().c_str());
    check(fs::is_symlink(target) && fs::read_symlink(target) == "mine.lua", "rollback restores the original relative symlink");
    check(work::bytes(target) == "-- changed after preview\n", "the symlink's target was never changed");
    check(!fs::exists(ctx.home / ".claude/mods/foxml-paper/hooks/register.tsx"), "rollback removes files first created by the update");
    check(!fs::is_symlink(ctx.home / ".local/bin/fox-work") && work::bytes(ctx.home / ".local/bin/fox-work") == "old work tool", "rollback restores an old command copy rather than keeping a second dispatcher");
    work::Stage third;
    check(work::prepare(ctx, third, error), error.c_str());
    fs::remove(third.files.back().source);
    check(!work::apply(ctx, third, third.plan.value("plan", "")).value("ok", false), "a missing staged dependency refuses deployment before writes");
    check(fs::is_symlink(target), "dependency refusal leaves the installed tree alone");
    fs::remove_all(base);
    std::cout << "workflow update: " << failures << " failures\n";
    return failures ? 1 : 0;
}
