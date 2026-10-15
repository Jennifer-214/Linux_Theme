// Unit test for modules/claude_wiring.cpp (S10 / S10b, 2026-10-15) and core/backup.cpp (snapshot_one, moved there
// from symlinks.cpp + specials.cpp). Runs the REAL functions against a throwaway fixture — a home, a git checkout
// whose .claude/ is ignored, a fake private workspace, a backup root — never her real checkout.
//
// merge_hook_entries: adds by command, keeps her own hooks, reuses a matcher's group, refuses a "hooks" that is not
// an object. restore_theme_wiring: a fresh restore; a second run changes nothing; a stale hook replaced with a backup;
// a link at a hook replaced by a file, its target untouched; settings.json merged, her entry kept, a backup taken;
// .plan-approved and settings.local.json untouched; a checkout whose .claude/ is not ignored refused; a missing
// workspace file refused; a wired hook missing from the workspace skipped while the others land.

#include "../modules/claude_wiring.hpp"
#include "../core/backup.hpp"
#include "../../fox-common/shell.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using json = nlohmann::json;
using namespace fox_install;

namespace {

int failed = 0, passed = 0;
void check(bool ok, const std::string& what) {
    if (ok) { ++passed; return; }
    ++failed;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
}

std::string slurp(const fs::path& p) {
    std::ifstream in(p, std::ios::binary);
    std::ostringstream s;
    s << in.rdbuf();
    return s.str();
}
void spit(const fs::path& p, const std::string& body) {
    fs::create_directories(p.parent_path());
    std::ofstream(p, std::ios::binary) << body;
}
bool exec_bit(const fs::path& p) {
    return (fs::status(p).permissions() & fs::perms::owner_exec) != fs::perms::none;
}
int git(const fs::path& repo, std::initializer_list<const char*> args) {
    std::vector<std::string> argv = {"env", "-u", "GIT_DIR", "-u", "GIT_INDEX_FILE", "-u", "GIT_WORK_TREE",
                                     "git", "-C", repo.string()};
    for (const char* a : args) argv.emplace_back(a);
    return sh::run(argv);
}

const char* WIRING = R"({
  "//": "the workspace's wiring",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Edit|Write|NotebookEdit",
        "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/plan-gate.sh" } ] },
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/no-installer.sh" },
                   { "type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/block_rg_r_typo.sh" } ] }
    ]
  }
}
)";

struct Fixture {
    fs::path root, home, repo, ws, backup;
    Context ctx;
    explicit Fixture(const char* tag) {
        root = fs::temp_directory_path() / ("test_claude_wiring_" + std::to_string(getpid()) + "_" + tag);
        fs::remove_all(root);
        home = root / "home";
        repo = home / "code/Linux_Theme";
        ws = home / "code/linux-theme-workspace";
        backup = root / "backup";
        fs::create_directories(repo);
        git(repo, {"init", "-q"});
        spit(repo / ".gitignore", ".claude/\n");
        spit(ws / "tools/hooks/settings.json", WIRING);
        spit(ws / "tools/hooks/plan-gate.sh", "#!/bin/sh\n# plan gate v2\n");
        spit(ws / "tools/hooks/no-installer.sh", "#!/bin/sh\n# installer guard v2\n");
        spit(ws / "tools/hooks/block_rg_r_typo.sh", "#!/bin/sh\n# rg typo guard\n");
        fs::create_directories(ws / "claude-skills/readiness");
        ctx.home = home;
        ctx.script_dir = repo;
        ctx.backup_dir = backup;
    }
    ~Fixture() { std::error_code ec; fs::remove_all(root, ec); }
    fs::path c(const char* rel) const { return repo / ".claude" / rel; }
};

void test_merge() {
    json wanted = json::parse(WIRING);
    json s = json::object();
    check(merge_hook_entries(s, wanted) == 3, "merge into empty settings adds all 3");
    check(merge_hook_entries(s, wanted) == 0, "a second merge adds nothing");
    check(s["hooks"]["PreToolUse"].size() == 2, "two matcher groups, not duplicated");

    // her own Stop hook is kept, and stays first
    json mine = json::parse(R"({"theme":"x","permissions":{"allow":["a"]},
        "hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"my-own.sh"}]}]}})");
    json installer = json::parse(R"({"hooks":{
        "Stop":[{"matcher":"","hooks":[{"type":"command","command":"notify stop"}]}],
        "Notification":[{"matcher":"","hooks":[{"type":"command","command":"notify n"}]}]}})");
    check(merge_hook_entries(mine, installer) == 2, "two installer hooks added beside hers");
    const json& stop = mine["hooks"]["Stop"];
    check(stop.size() == 1 && stop[0]["hooks"].size() == 2, "the installer's Stop hook joins her group (same matcher)");
    check(stop[0]["hooks"][0]["command"] == "my-own.sh", "her own Stop hook kept, first");
    check(stop[0]["hooks"][1]["command"] == "notify stop", "the installer's Stop hook added after it");
    check(mine["theme"] == "x" && mine["permissions"]["allow"][0] == "a", "keys other than hooks untouched");

    // a Bash group that already runs one of the two wanted commands gets only the other, in that group
    json part = json::parse(R"({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
        {"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/block_rg_r_typo.sh"}]}]}})");
    check(merge_hook_entries(part, wanted) == 2, "only the 2 missing commands added");
    check(part["hooks"]["PreToolUse"].size() == 2, "the Edit matcher got a new group, Bash reused its own");
    check(part["hooks"]["PreToolUse"][0]["hooks"].size() == 2, "the Bash group grew to 2");

    json bad = json::parse(R"({"hooks":["not","an","object"]})");
    json bad_before = bad;
    check(merge_hook_entries(bad, wanted) == -1 && bad == bad_before, "a \"hooks\" that is not an object: refused, untouched");
}

void test_user_settings() {  // S10b: do_claude_hooks' merge, through the function it calls
    json installer = json::parse(R"({"hooks":{
        "Stop":[{"matcher":"","hooks":[{"type":"command","command":"~/.config/hypr/scripts/agent_notify.sh claude stop"}]}],
        "SubagentStop":[{"matcher":"","hooks":[{"type":"command","command":"~/.config/hypr/scripts/agent_notify.sh claude subagent"}]}],
        "Notification":[{"matcher":"","hooks":[{"type":"command","command":"~/.config/hypr/scripts/agent_notify.sh claude notification"}]}]}})");
    json hers = json::parse(R"({"theme":"light","model":"x","hooks":{"Stop":[{"matcher":"","hooks":[
        {"type":"command","command":"~/bin/my-stop-hook.sh"}]}]}})");
    check(merge_user_settings(hers, installer), "user settings merged");
    const json& stop = hers["hooks"]["Stop"][0]["hooks"];
    check(stop.size() == 2 && stop[0]["command"] == "~/bin/my-stop-hook.sh", "her own Stop hook survives the install");
    check(hers["hooks"].contains("SubagentStop") && hers["hooks"].contains("Notification"), "the installer's other two hooks added");
    check(hers["theme"] == "dark-ansi" && hers["model"] == "x", "the theme flipped as before; other keys kept");
    json again = hers;
    check(merge_user_settings(again, installer) && again == hers, "a second install changes nothing");
    json bad = json::parse(R"({"hooks":"nope","theme":"light"})");
    check(!merge_user_settings(bad, installer) && bad["hooks"] == "nope" && bad["theme"] == "dark-ansi",
          "a broken hooks entry: left as it is, said, the theme still set");
    // the call site: do_claude_hooks must use merge_user_settings, never a merge-patch of the hooks
    std::ifstream sp("modules/specials.cpp");
    std::ostringstream ss; ss << sp.rdbuf();
    const std::string src = ss.str();
    check(!src.empty(), "modules/specials.cpp readable (the test runs from src/fox-install)");
    check(src.find("merge_user_settings(existing, hooks)") != std::string::npos, "do_claude_hooks calls merge_user_settings");
    check(src.find(".merge_patch(hooks)") == std::string::npos, "no merge-patch of the hooks left in specials.cpp");
}

void test_fresh_and_again() {
    Fixture f("fresh");
    WiringReport r = restore_theme_wiring(f.ctx, f.repo, f.ws);
    check(r.refused.empty(), "fresh restore not refused: " + r.refused);
    check(fs::is_symlink(f.c("skills")) && fs::is_directory(f.c("skills") / "readiness"), "skills link made and resolves");
    check(fs::read_symlink(f.c("skills")).is_relative(), "skills link is relative");
    for (const char* h : {"hooks/plan-gate.sh", "hooks/no-installer.sh", "hooks/block_rg_r_typo.sh"}) {
        check(fs::is_regular_file(f.c(h)) && !fs::is_symlink(f.c(h)), std::string(h) + " is a copy, not a link");
        check(slurp(f.c(h)) == slurp(f.ws / "tools" / h), std::string(h) + " equals its source");
        check(exec_bit(f.c(h)), std::string(h) + " is executable");
    }
    check(slurp(f.c("settings.json")) == WIRING, "settings.json is the workspace's file, byte for byte");

    WiringReport again = restore_theme_wiring(f.ctx, f.repo, f.ws);
    check(again.refused.empty() && again.done.empty(), "a second run changes nothing");
    check(!fs::exists(f.backup), "a second run backs nothing up");
}

void test_updates_with_backups() {
    Fixture f("update");
    restore_theme_wiring(f.ctx, f.repo, f.ws);
    spit(f.c("hooks/no-installer.sh"), "#!/bin/sh\n# installer guard v1 (stale)\n");
    spit(f.c(".plan-approved"), "session-a 2026-10-15\n");
    spit(f.c("settings.local.json"), "{\"permissions\":{\"allow\":[\"Bash(ls)\"]}}\n");
    spit(f.c("settings.json"), R"({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
        {"type":"command","command":"my-own-guard.sh"}]}]}})");
    // a link at a hook: replaced by the file, its target never written
    fs::path outside = f.root / "elsewhere.sh";
    spit(outside, "outside\n");
    fs::remove(f.c("hooks/block_rg_r_typo.sh"));
    fs::create_symlink(outside, f.c("hooks/block_rg_r_typo.sh"));
    std::string approved = slurp(f.c(".plan-approved")), local = slurp(f.c("settings.local.json"));

    WiringReport r = restore_theme_wiring(f.ctx, f.repo, f.ws);
    check(r.refused.empty(), "update not refused: " + r.refused);
    check(slurp(f.c("hooks/no-installer.sh")) == slurp(f.ws / "tools/hooks/no-installer.sh"), "the stale hook replaced");
    fs::path bak = f.backup / "code/Linux_Theme/.claude/hooks/no-installer.sh";
    check(fs::exists(bak) && slurp(bak).find("v1 (stale)") != std::string::npos, "the stale hook backed up first");
    check(!fs::is_symlink(f.c("hooks/block_rg_r_typo.sh")) && slurp(f.c("hooks/block_rg_r_typo.sh")) ==
          slurp(f.ws / "tools/hooks/block_rg_r_typo.sh"), "a link at a hook replaced by the file");
    check(slurp(outside) == "outside\n", "the link's target never written");
    json s = json::parse(slurp(f.c("settings.json")));
    const json& bash = s["hooks"]["PreToolUse"];
    bool mine = false, guard = false, gate = false;
    for (const auto& g : bash) for (const auto& h : g["hooks"]) {
        mine  = mine  || h["command"] == "my-own-guard.sh";
        guard = guard || h["command"] == "$CLAUDE_PROJECT_DIR/.claude/hooks/no-installer.sh";
        gate  = gate  || h["command"] == "$CLAUDE_PROJECT_DIR/.claude/hooks/plan-gate.sh";
    }
    check(mine && guard && gate, "settings.json: her own hook kept, the wired ones added");
    check(fs::exists(f.backup / "code/Linux_Theme/.claude/settings.json"), "settings.json backed up before the merge");
    check(slurp(f.c(".plan-approved")) == approved, ".plan-approved untouched");
    check(slurp(f.c("settings.local.json")) == local, "settings.local.json untouched");
}

void test_refusals() {
    {
        Fixture f("noignore");
        fs::remove(f.repo / ".gitignore");
        WiringReport r = restore_theme_wiring(f.ctx, f.repo, f.ws);
        check(!r.refused.empty() && r.refused.find("not git-ignored") != std::string::npos, "not ignored: refused, named");
        check(!fs::exists(f.repo / ".claude"), "not ignored: nothing written");
    }
    {
        Fixture f("nowiring");
        fs::remove(f.ws / "tools/hooks/settings.json");
        WiringReport r = restore_theme_wiring(f.ctx, f.repo, f.ws);
        check(!r.refused.empty() && !fs::exists(f.repo / ".claude"), "no workspace wiring: refused, nothing written");
    }
    {
        Fixture f("missinghook");
        fs::remove(f.ws / "tools/hooks/block_rg_r_typo.sh");
        WiringReport r = restore_theme_wiring(f.ctx, f.repo, f.ws);
        bool said = false;
        for (const auto& s : r.skipped) said = said || s.find("block_rg_r_typo.sh not in the workspace") != std::string::npos;
        check(r.refused.empty() && said, "a wired hook missing from the workspace: skipped, said");
        check(fs::exists(f.c("hooks/plan-gate.sh")) && fs::exists(f.c("hooks/no-installer.sh")), "…the others still land");
    }
}

void test_snapshot_one() {
    Fixture f("snap");
    Context ctx = f.ctx;
    check(snapshot_one(ctx, f.home / "absent.txt"), "nothing to back up: true");
    spit(f.home / "a/b.txt", "inside\n");
    check(snapshot_one(ctx, f.home / "a/b.txt") && slurp(f.backup / "a/b.txt") == "inside\n", "a file under home: backed up by its home-relative path");
    spit(f.root / "out.txt", "outside\n");
    fs::path abs = f.backup / ("_abs" + (f.root / "out.txt").string());
    check(snapshot_one(ctx, f.root / "out.txt") && slurp(abs) == "outside\n", "a file outside home: backed up under _abs");
    fs::create_symlink(f.home / "a/b.txt", f.home / "link");
    check(snapshot_one(ctx, f.home / "link") && fs::is_symlink(f.backup / "link"), "a link is backed up as a link");
}

}  // namespace

int main() {
    test_merge();
    test_user_settings();
    test_fresh_and_again();
    test_updates_with_backups();
    test_refusals();
    test_snapshot_one();
    if (failed == 0) std::printf("test_claude_wiring: %d passed\n", passed);
    else std::fprintf(stderr, "test_claude_wiring: %d passed, %d FAILED\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
