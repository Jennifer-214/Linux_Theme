// modules/fox_symdeps.cpp — the fox-symdeps.nvim C++ HUD, its foxtag core, and its
// pi agent wiring, restored from the owner's (private) GitHub repos.
//
// nvim already loads the plugin from the trader workspace's tools/plugins/ whenever
// that dir exists (templates/nvim/init.lua). On a fresh box nothing puts it there:
// the plugin is its own repo, gitignored inside the workspace; foxtag is a build
// product; the trader repo's links into the workspace that pi and Claude Code read
// (.pi, .claude/skills, …) are local-only, so a clone lacks them.
//
// Private repos → every step is best-effort: no gh login, no access, or no network
// warns and moves on. Repos are cloned only when absent and fast-forwarded only when
// clean and on their upstream — other sessions work in both, so local work is never
// touched. On a machine without access to these repos the module does nothing.

#include "../core/context.hpp"
#include "../core/git_clone_sh.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <initializer_list>
#include <fstream>
#include <string>
#include <system_error>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* WORKSPACE_REPO = "tick-trader-percore-workspace";
constexpr const char* PLUGIN_REPO    = "fox-symdeps.nvim";
constexpr const char* TRADER_REPO    = "FoxML_Trader_v2";

// Local-only links from the trader repo into the workspace (relative, as the
// workspace's README lays them out). `exclude` = hidden via .git/info/exclude
// rather than .gitignore, matching how they are hidden today.
struct Link { const char* at; const char* target; bool exclude; };
constexpr Link TRADER_LINKS[] = {
    { ".pi",            "../tick-trader-percore-workspace/pi",               true  },
    { "BLESS.md",       "../tick-trader-percore-workspace/BLESS.md",         true  },
    { ".claude/skills", "../../tick-trader-percore-workspace/claude-skills", false },
    { ".claude/agents", "../../tick-trader-percore-workspace/claude-agents", false },
};

std::string trim(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
    return s;
}

std::string gh_owner() {
    std::string out;
    if (!sh::have("gh") || !sh::capture({"gh", "api", "user", "--jq", ".login"}, out)) return {};
    return trim(out);
}

// GIT_TERMINAL_PROMPT=0: a private repo without stored credentials fails instead of
// stopping the install at a username prompt.
bool git_ok(const fs::path& repo, std::initializer_list<const char*> args, std::string* out = nullptr) {
    std::vector<std::string> argv = {"env", "GIT_TERMINAL_PROMPT=0", "git", "-C", repo.string()};
    for (const char* a : args) argv.emplace_back(a);
    std::string sink;
    return sh::capture(argv, out ? *out : sink);
}

// Clone when absent; fast-forward when clean and tracking an upstream; else leave it.
void clone_or_update(const std::string& owner, const std::string& repo, const fs::path& dir) {
    std::error_code ec;
    const auto runner = git_clone::sh_runner();
    if (!fs::exists(dir, ec) || git_clone::partial_clone(runner, dir)) {   // absent, or a clone that dropped part-way
        if (owner.empty()) {
            ui::warn(repo + ": not here and no `gh` login — skipped (gh auth login, then re-run)");
            return;
        }
        // Always HTTPS with gh's token: works where port 22 is blocked (guest Wi-Fi) and
        // whatever git_protocol gh login picked. gh auth login doesn't always wire git to
        // that token, so setup-git first (idempotent).
        sh::run({"gh", "auth", "setup-git"});
        const auto res = git_clone::ensure(runner, "https://github.com/" + owner + "/" + repo + ".git", dir);
        if (res.outcome == git_clone::Outcome::Cloned) {
            ui::ok(repo + " cloned → " + dir.string());
        } else if (res.outcome == git_clone::Outcome::Repaired) {
            ui::ok(repo + ": " + git_clone::describe(res.outcome) + " → " + dir.string() +
                   " (the broken one: " + res.moved_aside.string() + ")");
        } else {
            ui::warn(repo + ": clone failed after 3 tries (private repo — no access, or no network?) — skipped; re-run to retry");
        }
        return;
    }
    std::string status, upstream;
    if (!git_ok(dir, {"status", "--porcelain"}, &status)) {
        ui::warn(repo + ": " + dir.string() + " is not a git checkout — left as is");
        return;
    }
    if (!trim(status).empty()) {
        ui::skipped(repo + ": local changes — not pulled");
        return;
    }
    if (!git_ok(dir, {"rev-parse", "--abbrev-ref", "@{upstream}"}, &upstream)) {
        ui::skipped(repo + ": no upstream branch — not pulled");
        return;
    }
    if (git_ok(dir, {"pull", "--ff-only", "--quiet"})) {
        ui::ok(repo + " up to date with " + trim(upstream));
    } else {
        ui::warn(repo + ": pull failed (diverged, or no network) — left as is");
    }
}

void ensure_excluded(const fs::path& repo, const std::string& entry) {
    fs::path exclude = repo / ".git/info/exclude";
    std::ifstream in(exclude);
    std::string line;
    while (std::getline(in, line)) if (line == "/" + entry) return;
    std::ofstream out(exclude, std::ios::app);
    out << "/" << entry << "\n";
}

void link_trader(const fs::path& trader) {
    std::error_code ec;
    if (!fs::is_directory(trader / ".git", ec)) return;
    int made = 0;
    for (const auto& l : TRADER_LINKS) {
        fs::path at = trader / l.at;
        if (fs::exists(fs::symlink_status(at, ec))) continue;            // never replace anything
        if (!fs::exists(at.parent_path() / l.target, ec)) continue;      // target not here (yet)
        fs::create_directories(at.parent_path(), ec);
        fs::create_symlink(l.target, at, ec);
        if (ec) { ui::warn("could not link " + at.string() + ": " + ec.message()); continue; }
        if (l.exclude) ensure_excluded(trader, l.at);
        ++made;
    }
    if (made) ui::ok(std::to_string(made) + " trader → workspace link(s) restored (.pi, .claude/…)");
    else      ui::skipped("trader → workspace links already in place");
}

}  // namespace

void run_fox_symdeps(Context& ctx) {
    ui::section("fox-symdeps.nvim + foxtag + pi wiring (private repos, best-effort)");

    fs::path code      = ctx.home / "code";
    fs::path workspace = code / WORKSPACE_REPO;
    fs::path plugin    = workspace / "tools/plugins" / PLUGIN_REPO;
    fs::path foxtag    = workspace / "tools/foxtag";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would clone-or-fast-forward " + workspace.string() + " and " + plugin.string() +
                    " (gh login), build " + (foxtag / "foxtag").string() + " if missing, restore the trader's "
                    ".pi / .claude links, and `pi install " + (plugin / "pi").string() + "` if not installed");
        return;
    }

    std::string owner = gh_owner();
    std::error_code ec;
    if (owner.empty() && !fs::exists(workspace, ec)) {
        ui::skipped("no gh login and no " + std::string(WORKSPACE_REPO) + " here — nothing to do");
        return;
    }

    clone_or_update(owner, WORKSPACE_REPO, workspace);
    if (!fs::is_directory(workspace, ec)) return;
    clone_or_update(owner, PLUGIN_REPO, plugin);

    // foxtag: build only when missing — the plugin's own line owns rebuilds.
    if (fs::exists(foxtag / "foxtag", ec)) {
        ui::skipped("foxtag already built");
    } else if (fs::exists(foxtag / "build.sh", ec)) {
        if (sh::run({"bash", (foxtag / "build.sh").string()}) == 0) ui::ok("foxtag built");
        else ui::warn("foxtag build failed — the plugin's tag layer degrades until `tools/foxtag/build.sh` succeeds");
    }

    link_trader(code / TRADER_REPO);

    // pi package: the plugin's symdeps tools + fox-project (a project's brief/rules as data).
    if (!sh::have("pi")) {
        ui::skipped("pi not installed — skipping its fox-symdeps package");
    } else if (fs::is_directory(plugin / "pi", ec)) {
        std::string listed;
        sh::capture({"pi", "list"}, listed);
        if (listed.find((plugin / "pi").string()) != std::string::npos) {
            ui::skipped("pi package fox-symdeps already installed");
        } else if (sh::run({"pi", "install", (plugin / "pi").string()}) == 0) {
            ui::ok("pi package fox-symdeps installed (symdeps_* tools, fox-project)");
        } else {
            ui::warn("`pi install " + (plugin / "pi").string() + "` failed — run it by hand");
        }
    } else if (fs::is_directory(plugin, ec)) {
        ui::skipped("fox-symdeps.nvim has no pi/ package here (not pushed to GitHub yet?)");
    }
}

}  // namespace fox_install
