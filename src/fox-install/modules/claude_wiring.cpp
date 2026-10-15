// modules/claude_wiring.cpp — see claude_wiring.hpp. The theme_workspace step (run_theme_workspace) lives here too.

#include "claude_wiring.hpp"
#include "../core/backup.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <fstream>
#include <regex>
#include <sstream>
#include <string>
#include <system_error>
#include <vector>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace fox_install {

namespace {

constexpr const char* WORKSPACE_REPO = "linux-theme-workspace";
constexpr const char* HOOK_PREFIX = "$CLAUDE_PROJECT_DIR/.claude/hooks/";

// Does any group of this event already run `command`?
bool runs(const json& groups, const std::string& command) {
    for (const auto& g : groups) {
        if (!g.is_object() || !g.contains("hooks") || !g["hooks"].is_array()) continue;
        for (const auto& h : g["hooks"])
            if (h.is_object() && h.value("command", std::string()) == command) return true;
    }
    return false;
}

// The group with this matcher whose "hooks" is a list, or nullptr. A group with no matcher counts as "".
json* group_for(json& groups, const std::string& matcher) {
    for (auto& g : groups) {
        if (!g.is_object() || !g.contains("hooks") || !g["hooks"].is_array()) continue;
        if (g.value("matcher", std::string()) == matcher) return &g;
    }
    return nullptr;
}

bool read_text(const fs::path& p, std::string& out) {
    std::ifstream in(p, std::ios::binary);
    if (!in) return false;
    std::ostringstream s;
    s << in.rdbuf();
    out = s.str();
    return static_cast<bool>(in) || in.eof();
}

bool read_json(const fs::path& p, json& out) {
    std::string text;
    if (!read_text(p, text)) return false;
    try { out = json::parse(text); } catch (...) { return false; }
    return true;
}

// The hook scripts a wiring runs from .claude/hooks/, by plain file name, each once, in order.
std::vector<std::string> wired_scripts(const json& wiring) {
    static const std::regex plain("[A-Za-z0-9_.-]+");
    std::vector<std::string> out;
    if (!wiring.is_object() || !wiring.contains("hooks") || !wiring["hooks"].is_object()) return out;
    for (const auto& [event, groups] : wiring["hooks"].items()) {
        if (!groups.is_array()) continue;
        for (const auto& g : groups) {
            if (!g.is_object() || !g.contains("hooks") || !g["hooks"].is_array()) continue;
            for (const auto& h : g["hooks"]) {
                std::string c = h.is_object() ? h.value("command", std::string()) : std::string();
                if (c.rfind(HOOK_PREFIX, 0) != 0) continue;
                std::string name = c.substr(std::char_traits<char>::length(HOOK_PREFIX));
                if (!std::regex_match(name, plain) || name == "." || name == "..") continue;
                bool seen = false;
                for (const auto& n : out) seen = seen || n == name;
                if (!seen) out.push_back(name);
            }
        }
    }
    return out;
}

bool executable(const fs::path& p) {
    std::error_code ec;
    auto st = fs::status(p, ec);
    return !ec && (st.permissions() & fs::perms::owner_exec) != fs::perms::none;
}

}  // namespace

int merge_hook_entries(json& settings, const json& wanted) {
    if (!wanted.is_object() || !wanted.contains("hooks") || !wanted["hooks"].is_object()) return 0;
    if (!settings.is_object()) return -1;
    if (settings.contains("hooks") && !settings["hooks"].is_object()) return -1;
    int added = 0;
    for (const auto& [event, groups] : wanted["hooks"].items()) {
        if (!groups.is_array()) continue;
        for (const auto& g : groups) {
            if (!g.is_object() || !g.contains("hooks") || !g["hooks"].is_array()) continue;
            const std::string matcher = g.value("matcher", std::string());
            for (const auto& h : g["hooks"]) {
                const std::string command = h.is_object() ? h.value("command", std::string()) : std::string();
                if (command.empty()) continue;
                json& have = settings["hooks"][event];  // made only when something is added below
                if (have.is_null()) have = json::array();
                if (!have.is_array()) break;            // an event that is not a list: left exactly as it is
                if (runs(have, command)) continue;
                json* into = group_for(have, matcher);
                if (!into) {
                    have.push_back({{"matcher", matcher}, {"hooks", json::array()}});
                    into = &have.back();
                }
                (*into)["hooks"].push_back(h);
                ++added;
            }
        }
    }
    return added;  // an event's list is only ever created when a command is added to it
}

bool merge_user_settings(json& existing, const json& hooks) {
    if (!existing.is_object()) return false;
    const bool merged = merge_hook_entries(existing, hooks) >= 0;
    existing["theme"] = "dark-ansi";   // force-flip to dark-ansi on every run (unchanged)
    return merged;
}

WiringReport restore_theme_wiring(const Context& ctx, const fs::path& repo, const fs::path& workspace) {
    WiringReport r;
    std::error_code ec;
    const fs::path source = workspace / "tools/hooks/settings.json";
    if (!fs::is_regular_file(source, ec)) {
        r.refused = source.string() + " is not here — pull " + WORKSPACE_REPO + ", then re-run --theme-workspace";
        return r;
    }
    json wanted;
    if (!read_json(source, wanted) || !wanted.is_object()) {
        r.refused = source.string() + " does not parse — nothing restored";
        return r;
    }
    // Private wiring never enters a public repo: in a git checkout, .claude/ must be ignored.
    if (fs::exists(repo / ".git", ec)) {
        int rc = sh::run({"env", "-u", "GIT_DIR", "-u", "GIT_INDEX_FILE", "-u", "GIT_WORK_TREE", "git", "-C",
                          repo.string(), "check-ignore", "-q", ".claude/settings.json"});
        if (rc != 0) {
            r.refused = repo.string() + "/.claude is not git-ignored (git check-ignore rc " + std::to_string(rc) +
                        ") — refusing to put private wiring where a commit could take it";
            return r;
        }
    }
    const fs::path claude = repo / ".claude";

    // 1. the skills link — only when nothing is there
    const fs::path skills = claude / "skills", skills_target = workspace / "claude-skills";
    if (fs::exists(fs::symlink_status(skills, ec))) {
        r.skipped.push_back(".claude/skills already there");
    } else if (!fs::is_directory(skills_target, ec)) {
        r.skipped.push_back(skills_target.string() + " not here — no skills link");
    } else {
        fs::create_directories(claude, ec);
        fs::path link = fs::relative(skills_target, claude, ec);
        if (ec || link.empty()) { ec.clear(); link = skills_target; }
        fs::create_symlink(link, skills, ec);
        if (ec) r.skipped.push_back("could not link .claude/skills: " + ec.message());
        else    r.done.push_back(".claude/skills → " + link.string());
    }

    // 2. each wired hook, as a copy
    for (const std::string& name : wired_scripts(wanted)) {
        const fs::path from = workspace / "tools/hooks" / name, to = claude / "hooks" / name;
        std::string body, now;
        if (!read_text(from, body)) {
            r.skipped.push_back("tools/hooks/" + name + " not in the workspace — .claude/hooks/" + name + " not restored");
            continue;
        }
        const bool is_link = fs::is_symlink(fs::symlink_status(to, ec));
        if (!is_link && read_text(to, now) && now == body && executable(to)) {
            r.skipped.push_back(".claude/hooks/" + name + " unchanged");
            continue;
        }
        if (fs::exists(fs::symlink_status(to, ec)) && !snapshot_one(ctx, to)) {
            r.skipped.push_back(".claude/hooks/" + name + ": its backup failed — left as it was");
            continue;
        }
        // write_atomic renames over the path: a link there is replaced by the file, its target never written
        if (!idem::write_atomic(to, body)) {
            r.skipped.push_back(".claude/hooks/" + name + ": the write failed — left as it was");
            continue;
        }
        fs::permissions(to, fs::perms::owner_all | fs::perms::group_read | fs::perms::group_exec |
                            fs::perms::others_read | fs::perms::others_exec, fs::perm_options::replace, ec);
        r.done.push_back(".claude/hooks/" + name + (now.empty() && !is_link ? " restored" : " updated (old one backed up)"));
    }

    // 3. settings.json — the workspace's file when absent, else merged by command
    const fs::path settings = claude / "settings.json";
    if (!fs::exists(fs::symlink_status(settings, ec))) {
        std::string body;
        if (read_text(source, body) && idem::write_atomic(settings, body))
            r.done.push_back(".claude/settings.json written");
        else
            r.skipped.push_back(".claude/settings.json: the write failed");
    } else {
        json have;
        if (!read_json(settings, have) || !have.is_object()) {
            r.skipped.push_back(".claude/settings.json does not parse — left as it was");
        } else {
            int n = merge_hook_entries(have, wanted);
            if (n < 0) {
                r.skipped.push_back(".claude/settings.json: its \"hooks\" is not an object — left as it was");
            } else if (n == 0) {
                r.skipped.push_back(".claude/settings.json already wires every hook");
            } else if (!snapshot_one(ctx, settings)) {
                r.skipped.push_back(".claude/settings.json: its backup failed — left as it was");
            } else if (!idem::write_atomic(settings, have.dump(2) + "\n")) {
                r.skipped.push_back(".claude/settings.json: the write failed — left as it was");
            } else {
                r.done.push_back(".claude/settings.json: " + std::to_string(n) + " hook(s) added (old one backed up)");
            }
        }
    }
    return r;
}

void run_theme_workspace(Context& ctx) {
    ui::section("Linux_Theme's Claude wiring — plan gate, installer guard, skills (private workspace, best-effort)");
    const fs::path workspace = ctx.home / "code" / WORKSPACE_REPO;
    if (sh::dry_run()) {
        ui::substep("[dry-run] would restore " + (ctx.script_dir / ".claude").string() + " from " +
                    workspace.string() + ": the skills link, each wired hook as a copy (backed up first when it "
                    "differs), settings.json merged by command");
        return;
    }
    std::error_code ec;
    if (!fs::is_directory(workspace, ec)) {
        ui::skipped(std::string(WORKSPACE_REPO) + " is not at " + workspace.string() +
                    " — clone it (or run --github), then --theme-workspace");
        return;
    }
    WiringReport r = restore_theme_wiring(ctx, ctx.script_dir, workspace);
    if (!r.refused.empty()) { ui::warn(r.refused); return; }
    for (const auto& d : r.done) ui::ok(d);
    for (const auto& s : r.skipped) ui::skipped(s);
}

}  // namespace fox_install
