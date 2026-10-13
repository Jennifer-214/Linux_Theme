// modules/configure_opencode.cpp — OpenCode + pi agent configs, merge-not-clobber.
//
//   * ~/.config/opencode/opencode.json and ~/.pi/agent/{settings,models}.json are
//     owned by `fox-llm-update --sync` — the same code the daily timer runs. It
//     only ADDS (installed models, missing defaults: permission gate, title model,
//     no self-update, no session sharing, 32k limits) and never changes a key the
//     user set, so re-running the installer can't wipe a tuned config [I-05].
//     One writer, one merge rule: the installer and the timer can't drift apart.
//   * ~/.config/opencode/tui.json → theme=foxml.
//   * Project-local .opencode/opencode.json wires the in-repo claude-skills.
//     (No global skill list: opencode finds <repo>/.claude/skills on its own.)

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include "../../fox-common/json.hpp"

#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;
using json   = nlohmann::json;

namespace fox_install {

namespace {

void write_if_changed(const Context& ctx, const fs::path& dst, const json& j, const std::string& label) {
    std::string body = j.dump(2);
    if (idem::up_to_date(dst, body, ctx.force_reapply)) {
        ui::skipped(label + " already up to date");
    } else if (idem::write_atomic(dst, body)) {
        ui::ok(label + " written");
    } else {
        ui::warn("could not write " + dst.string());
    }
}

}  // namespace

void run_configure_opencode(Context& ctx) {
    ui::section("Configure OpenCode + pi (models, permission gate, theme)");

    fs::path conf_dir = ctx.config_home / "opencode";
    // The deployed copy (symlinks module, phase 2) — fall back to the repo copy.
    fs::path sync_bin = ctx.home / ".local/bin/fox-llm-update";
    if (!fs::exists(sync_bin)) sync_bin = ctx.shared_dir / "bin/fox-llm-update";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would run `" + sync_bin.string() + " --sync` (merge, never clobber) "
                    "and write " + (conf_dir / "tui.json").string() +
                    " + project-local .opencode/opencode.json");
        return;
    }

    if (sh::run({"bash", sync_bin.string(), "--sync"}) == 0) {
        ui::ok("opencode.json + ~/.pi/agent merged (existing settings kept)");
    } else {
        ui::warn("fox-llm-update --sync failed — opencode/pi configs left as they were");
    }

    write_if_changed(ctx, conf_dir / "tui.json",
                     json{{"$schema", "https://opencode.ai/tui.json"}, {"theme", "foxml"}},
                     "tui.json (theme: foxml)");

    // Safe to commit (no username / path leaks).
    write_if_changed(ctx, ctx.script_dir / ".opencode/opencode.json",
                     json{{"$schema", "https://opencode.ai/config.json"},
                          {"skills", {{"paths", json::array({"./claude-skills"})}}}},
                     "project-local .opencode/opencode.json");
}

}  // namespace fox_install
