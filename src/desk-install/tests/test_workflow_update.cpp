#include "../modules/workflow_update.hpp"
#include <iostream>

namespace fs = std::filesystem;
namespace work = desk_install::workflow;
int main() {
    auto repo = fs::current_path();
    while (repo != repo.parent_path() && !fs::is_directory(repo / "shared/nvim_lua")) repo = repo.parent_path();
    const auto pattern = (fs::temp_directory_path() / "workflow-update-test-XXXXXX").string();
    std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
    const auto made = ::mkdtemp(name.data()); if (!made) return 1;
    const fs::path base = made;
    fs::create_directories(base / "home");
    ::setenv("XDG_STATE_HOME", (base / "state").c_str(), 1);
    desk_install::Context ctx;
    ctx.home = base / "home"; ctx.config_home = base / "external-config"; ctx.script_dir = repo;
    ctx.shared_dir = repo / "shared"; ctx.templates_dir = repo / "templates";
    ctx.palette_path = repo / "themes/Paper/palette.sh";
    const auto target = ctx.config_home / "nvim/lua/foxml/work.lua";
    work::write(target.parent_path() / "mine.lua", "-- my existing module\n");
    fs::create_symlink("mine.lua", target);
    work::write(ctx.home / ".local/bin/fox-work", "old work tool");
    fs::create_symlink("/a/user/owned/command", ctx.home / ".local/bin/fox-drawer");
    auto menu = work::load(repo / "shared/quickshell/foxml/menus.json");
    menu["project_roots"] = work::Json::array({"~/my-projects"});
    work::write(ctx.config_home / "quickshell/foxml/menus.json", menu.dump());
    int failures = 0;
    const auto check = [&](bool ok, const std::string& message) { if (!ok) { ++failures; std::cerr << "FAIL: " << message << '\n'; } };
    std::string error;
    const auto prepared = [&](work::Stage& stage) {
        const bool ok = work::prepare(ctx, stage, error); check(ok, error);
        if (!ok) fs::remove_all(base);
        return ok;
    };
    work::Stage first;
    if (!prepared(first)) return 1;
    check(fs::is_symlink(target) && work::bytes(target) == "-- my existing module\n", "preview does not deploy anything");
    work::Stage identical;
    if (!prepared(identical)) return 1;
    check(first.plan["plan"] == identical.plan["plan"], "preview token is deterministic");
    const auto previous_umask = ::umask(0077);
    work::Stage restricted;
    if (!prepared(restricted)) { ::umask(previous_umask); return 1; }
    ::umask(previous_umask);
    check(first.plan["plan"] == restricted.plan["plan"], "generated file permissions and preview tokens do not depend on the caller's umask");
    work::write(target.parent_path() / "mine.lua", "-- changed after preview\n");
    // A symlink target's contents are not overwritten by deployment: its link itself is the target.
    fs::remove(target); work::write(target, "-- edited target after preview\n");
    check(!work::apply(ctx, first, first.plan.value("plan", "")).value("ok", false), "a moved target refuses the entire update");
    check(!fs::exists(ctx.home / ".claude/mods/foxml-paper/hooks/register.tsx"), "refusal does not partially deploy other assets");
    fs::remove(target); fs::create_symlink("mine.lua", target);
    work::Stage second;
    if (!prepared(second)) return 1;
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
    if (!prepared(third)) return 1;
    fs::remove(third.files.back().source);
    check(!work::apply(ctx, third, third.plan.value("plan", "")).value("ok", false), "a missing staged dependency refuses deployment before writes");
    check(fs::is_symlink(target), "dependency refusal leaves the installed tree alone");

    // Recreate the durable state left by a terminated updater, using the same deployment and backup helpers.
    work::Stage interrupted;
    if (!prepared(interrupted)) return 1;
    const auto state = work::state_home(ctx), crash_folder = state / "transactions/100-1";
    auto crash = interrupted.plan;
    crash.update(work::Json{{"transaction", "100-1"}, {"phase", "applying"}, {"home", ctx.home.string()}, {"config", ctx.config_home.string()},
        {"pid", 0}, {"process", "dead"}, {"createdAt", std::time(nullptr)}, {"hadPrevious", true}});
    work::write(crash_folder / "previous-current.json", work::bytes(state / "current.json"));
    desk_install::Context partial = ctx; partial.backup_dir = crash_folder / "before";
    for (const auto& row : crash["files"]) if (row.value("changed", false)) check(desk_install::snapshot_one(partial, row.value("destination", "")), "interrupted update backup is complete");
    work::write(crash_folder / "manifest.json", crash.dump());
    for (const auto& asset : interrupted.files) if (asset.destination == target) check(desk_install::deploy_file_atomic(partial, asset.source, target), "one interrupted replacement reached disk");
    const auto pending = desk_install::work_updates::inventory(state)["pending"];
    check(pending.size() == 1 && pending[0].value("interrupted", false), "a stopped writer is shown as interrupted");
    check(!work::apply(ctx, interrupted, interrupted.plan.value("plan", "")).value("ok", false), "a second update cannot hide an interrupted update");
    const auto deployed = work::bytes(target);
    work::write(target, "-- later user edit\n");
    check(!work::rollback(ctx, "100-1", true).value("ok", false), "recovery preserves later edits");
    work::write(target, deployed);
    check(work::rollback(ctx, "100-1", true).value("ok", false), "recovery restores replaced and untouched files together");
    check(fs::is_symlink(target) && fs::read_symlink(target) == "mine.lua", "recovery restores the original link");
    check(work::load(crash_folder / "manifest.json").value("phase", "") == "rolled-back", "recovery completion is durable");

    // Identical content with different modes must match either complete version during rollback.
    const auto mode_target = ctx.home / "mode-only";
    work::write(mode_target, "same"); fs::permissions(mode_target, fs::perms::owner_read | fs::perms::owner_write);
    const auto mode_folder = state / "transactions/110-1";
    partial.backup_dir = mode_folder / "before"; desk_install::snapshot_one(partial, mode_target);
    fs::permissions(mode_folder / "before/mode-only", fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read | fs::perms::others_read);
    const auto mode_row = work::Json{{"destination", mode_target.string()}, {"changed", true}, {"before", work::node_hash(mode_target)}, {"after", work::node_hash(mode_target)},
        {"beforeLink", ""}, {"afterLink", ""}, {"beforeMode", 0644}, {"mode", 0600}};
    auto mode_manifest = crash; mode_manifest["transaction"] = "110-1"; mode_manifest["phase"] = "verified"; mode_manifest["files"] = work::Json::array({mode_row});
    work::write(mode_folder / "manifest.json", mode_manifest.dump()); work::write(mode_folder / "previous-current.json", work::bytes(state / "current.json")); work::write(state / "current.json", mode_manifest.dump());
    check(work::rollback(ctx, "110-1").value("ok", false), "permission-only updates can roll back");
    check((static_cast<unsigned>(fs::status(mode_target).permissions()) & 0777) == 0644, "rollback restores the earlier mode");

    const auto old = std::time(nullptr) - 60 * 86400;
    const auto transaction = [&](const std::string& id, const std::string& phase, long long at) {
        auto item = crash; item["transaction"] = id; item["phase"] = phase; item["createdAt"] = at; item["hadPrevious"] = false; item["files"] = work::Json::array();
        work::write(state / "transactions" / id / "manifest.json", item.dump());
        work::write(state / "transactions" / id / "before/old.bin", "old backup");
        return item;
    };
    transaction("201-1", "verified", old);
    transaction("202-1", "verified", old);
    transaction("203-1", "unknown", old);
    auto head = transaction("301-1", "verified", std::time(nullptr)); head["hadPrevious"] = true;
    work::write(state / "transactions/301-1/manifest.json", head.dump());
    work::write(state / "transactions/301-1/previous-current.json", work::load(state / "transactions/201-1/manifest.json").dump());
    work::write(state / "current.json", head.dump());
    transaction("401-1", "applying", std::time(nullptr));
    work::write(state / "transactions/401-1/previous-current.json", head.dump());
    auto active = transaction("501-1", "applying", std::time(nullptr)); active["pid"] = ::getpid(); active["process"] = desk_install::work_updates::process_stamp(::getpid());
    work::write(state / "transactions/501-1/manifest.json", active.dump());
    check(!work::rollback(ctx, "501-1", true).value("ok", false), "recovery never interrupts a live writer");
    auto foreign = transaction("601-1", "verified", old); foreign["home"] = (base / "another-home").string();
    work::write(state / "transactions/601-1/manifest.json", foreign.dump());
    fs::create_directories(base / "outside"); work::write(base / "outside/keep", "outside backup inventory");
    fs::create_directory_symlink(base / "outside", state / "transactions/999-1");
    auto clean = work::cleanup_plan(ctx, 1, 30);
    check(clean["selected"] == work::Json::array({"202-1"}), "cleanup retains the current rollback chain, pending recovery, live writers and unknown records");
    const auto parent_record = work::bytes(state / "transactions/301-1/previous-current.json");
    fs::remove(state / "transactions/301-1/previous-current.json");
    check(work::cleanup_plan(ctx, 1, 30)["selected"].empty(), "a broken rollback chain protects every backup");
    work::write(state / "transactions/301-1/previous-current.json", "{}");
    check(work::cleanup_plan(ctx, 1, 30)["selected"].empty(), "a malformed parent record protects every backup");
    work::write(state / "transactions/301-1/previous-current.json", parent_record);
    const auto head_record = work::bytes(state / "current.json");
    work::write(state / "current.json", "not valid JSON");
    check(work::cleanup_plan(ctx, 1, 30)["selected"].empty(), "a damaged installed-version record protects every backup");
    work::write(state / "current.json", head_record);
    work::write(state / "transactions/202-1/before/old.bin", "changed backup");
    check(!work::cleanup(ctx, clean.value("plan", ""), 1, 30).value("ok", false), "cleanup refuses an inventory changed after preview");
    clean = work::cleanup_plan(ctx, 1, 30);
    const auto current_before_cleanup = work::bytes(state / "current.json");
    check(work::cleanup(ctx, clean.value("plan", ""), 1, 30).value("ok", false), "the reviewed cleanup removes eligible backups");
    check(!fs::exists(state / "transactions/202-1") && fs::exists(state / "transactions/201-1/before/old.bin"), "required rollback backups survive cleanup");
    check(fs::exists(base / "outside/keep") && work::bytes(state / "current.json") == current_before_cleanup && fs::is_symlink(target), "cleanup never follows outside links or changes installed files");
    fs::remove_all(base);
    std::cout << "workflow update: " << failures << " failures\n";
    return failures ? 1 : 0;
}
