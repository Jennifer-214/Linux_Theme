// modules/configure_opencode.cpp — generate OpenCode opencode.json + tui.json.
//
// Mirrors install.sh.legacy::configure_opencode:
//   * Discover installed Ollama models, filter out embedding-only ones.
//   * Pick a chat-preferred default (qwen2.5:7b → 14b → 3b → any non-coder
//     → first installed).
//   * Discover ~/code/*/claude-skills dirs that contain SKILL.md files.
//   * Write ~/.config/opencode/opencode.json with provider config + model
//     list + skill paths, plus ~/.config/opencode/tui.json with theme=foxml.
//   * Drop a project-local .opencode/opencode.json with the in-repo
//     claude-skills wired in via relative path.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include "../../fox-intel/json.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

bool starts_with(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}

// Returns true if the model is an embedding-only model we should skip.
bool is_embed_model(const std::string& m) {
    return starts_with(m, "nomic-embed-text") ||
           starts_with(m, "mxbai-embed-")     ||
           starts_with(m, "bge-");
}

// `ollama list` → vector of model:tag strings, embedding-only filtered out.
std::vector<std::string> installed_models() {
    std::vector<std::string> out;
    if (!have("ollama")) return out;
    std::string raw;
    sh::capture({"ollama", "list"}, raw);
    std::istringstream is(raw);
    std::string line;
    bool first = true;
    while (std::getline(is, line)) {
        if (first) { first = false; continue; }   // header row
        std::istringstream ls(line);
        std::string name;
        if (!(ls >> name)) continue;
        if (name.empty() || is_embed_model(name)) continue;
        out.push_back(name);
    }
    if (out.empty()) out.push_back("qwen2.5-coder:7b");
    return out;
}

std::string pick_default(const std::vector<std::string>& models) {
    static const std::vector<std::string> prefs = { "qwen2.5:7b", "qwen2.5:14b", "qwen2.5:3b" };
    for (auto& p : prefs) {
        if (std::find(models.begin(), models.end(), p) != models.end()) return p;
    }
    for (auto& m : models) {
        if (m.find("-coder") == std::string::npos) return m;
    }
    return models.front();
}

std::vector<fs::path> discover_skill_paths(const Context& ctx) {
    std::vector<fs::path> out;
    fs::path code = ctx.home / "code";
    std::error_code ec;
    if (!fs::is_directory(code, ec)) return out;
    for (auto& entry : fs::directory_iterator(code, ec)) {
        if (!entry.is_directory()) continue;
        fs::path candidate = entry.path() / "claude-skills";
        if (!fs::is_directory(candidate, ec)) continue;
        // Confirm at least one SKILL.md exists under it.
        for (auto& sub : fs::recursive_directory_iterator(candidate, ec)) {
            if (sub.is_regular_file() && sub.path().filename() == "SKILL.md") {
                out.push_back(candidate);
                break;
            }
        }
    }
    return out;
}

}  // namespace

void run_configure_opencode(Context& ctx) {
    ui::section("Configure OpenCode (theme + model picker + skill discovery)");

    fs::path conf_dir = ctx.config_home / "opencode";
    if (sh::dry_run()) {
        ui::substep("[dry-run] would discover installed Ollama models, write "
                    + (conf_dir / "opencode.json").string() + " + " +
                    (conf_dir / "tui.json").string() +
                    " + project-local .opencode/opencode.json");
        return;
    }

    std::vector<std::string> models = installed_models();
    std::string default_model = "ollama/" + pick_default(models);
    auto skill_paths = discover_skill_paths(ctx);

    json models_block = json::object();
    for (auto& m : models) {
        models_block[m] = json{{"name", m}};
    }
    json skill_arr = json::array();
    for (auto& p : skill_paths) skill_arr.push_back(p.string());

    json opencode_json = {
        {"$schema", "https://opencode.ai/config.json"},
        {"provider", {
            {"ollama", {
                {"npm",  "@ai-sdk/openai-compatible"},
                {"name", "Ollama (Local)"},
                {"options", {{"baseURL", "http://localhost:11434/v1"}}},
                {"models", models_block},
            }}
        }},
        {"model", default_model},
        {"skills", {{"paths", skill_arr}}},
    };

    json tui_json = {
        {"$schema", "https://opencode.ai/tui.json"},
        {"theme",   "foxml"},
    };

    std::string opencode_body = opencode_json.dump(2);
    std::string tui_body      = tui_json.dump(2);
    fs::path opencode_path = conf_dir / "opencode.json";
    fs::path tui_path      = conf_dir / "tui.json";

    bool user_configs_current =
        idem::up_to_date(opencode_path, opencode_body, ctx.force_reapply) &&
        idem::up_to_date(tui_path,      tui_body,      ctx.force_reapply);

    if (user_configs_current) {
        ui::skipped("opencode.json + tui.json already up to date");
    } else {
        fs::create_directories(conf_dir);
        { std::ofstream o(opencode_path); o << opencode_body; }
        { std::ofstream o(tui_path);      o << tui_body; }
        ui::ok("theme: foxml (palette-driven)");
        ui::ok("models exposed to picker: " + std::to_string(models.size()) +
               " (default: " + default_model + ")");
        ui::ok("skill workspaces wired: " + std::to_string(skill_paths.size()));
    }

    // Project-local override at .opencode/opencode.json — references the
    // in-repo claude-skills via a relative path. Safe to commit (no
    // username / path leaks).
    fs::path proj_dir  = ctx.script_dir / ".opencode";
    fs::path proj_path = proj_dir / "opencode.json";
    json proj = {
        {"$schema", "https://opencode.ai/config.json"},
        {"skills",  {{"paths", json::array({ "./claude-skills" })}}},
    };
    std::string proj_body = proj.dump(2);
    if (idem::up_to_date(proj_path, proj_body, ctx.force_reapply)) {
        ui::skipped("project-local .opencode/opencode.json already up to date");
    } else {
        fs::create_directories(proj_dir);
        std::ofstream o(proj_path);
        o << proj_body;
        ui::ok("project-local .opencode/opencode.json written");
    }
}

}  // namespace fox_install
