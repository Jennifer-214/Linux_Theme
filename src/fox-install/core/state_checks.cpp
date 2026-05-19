#include "state_checks.hpp"

#include "../../fox-common/shell.hpp"

#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install::state {

namespace {

bool pacman_installed(const std::string& pkg) {
    // pacman -Qi <pkg> exits 0 if the package is installed, 1 otherwise.
    // We swallow stdout/stderr via the wrapping shell because sh::run
    // inherits stdio and we don't want the test/output stream cluttered.
    return sh::run({"sh", "-c", "pacman -Qi " + pkg + " >/dev/null 2>&1"}) == 0;
}

// systemctl_is_enabled — returns one of {"enabled","disabled","masked",
// "static","not-found", ""}. Empty means the call itself failed.
std::string systemctl_is_enabled(const std::string& unit, bool user) {
    std::vector<std::string> argv = {"systemctl"};
    if (user) argv.push_back("--user");
    argv.push_back("is-enabled");
    argv.push_back(unit);
    std::string out;
    sh::capture(argv, out);  // exit code is intentionally ignored — masked/disabled both produce non-zero exits but useful stdout
    // Strip trailing newline.
    while (!out.empty() && (out.back() == '\n' || out.back() == '\r')) out.pop_back();
    return out;
}

}  // namespace

Classification check_deps(const Context& /*ctx*/, const Manifest& manifest) {
    const auto it = manifest.modules.find("deps");
    if (it == manifest.modules.end()) {
        return {Status::Fresh, "deps has not run yet"};
    }

    // Sentinel set: the packages every later module assumes are present.
    // If any of these is missing, deps' work has been undone (e.g.
    // pacman -R, a partial uninstall, an Arch downgrade) and we need to
    // re-run regardless of the stored hash.
    static const std::vector<std::string> sentinels = {
        "hyprland", "kitty", "neovim", "waybar", "firefox",
    };
    std::vector<std::string> missing;
    for (const auto& p : sentinels) {
        if (!pacman_installed(p)) missing.push_back(p);
    }
    if (!missing.empty()) {
        std::string reason = "missing sentinel packages:";
        for (const auto& m : missing) { reason += ' '; reason += m; }
        return {Status::Update, reason};
    }
    return {Status::Noop, "sentinel packages present"};
}

Classification check_render(const Context& ctx, const Manifest& manifest) {
    const auto it = manifest.modules.find("render");
    const bool tracked = (it != manifest.modules.end());

    // Sentinel: hyprland.conf is the canonical "render has deployed
    // something" marker — every theme produces one, and it's the
    // highest-blast-radius file in the deploy set.
    const fs::path deployed = ctx.config_home / "hypr" / "hyprland.conf";
    if (!fs::exists(deployed)) {
        if (!tracked) return {Status::Fresh, "no manifest entry, hyprland.conf absent"};
        return {Status::Conflict,
                "manifest says render ran, but " + deployed.string() + " is missing"};
    }

    if (!tracked) {
        // File exists but was deployed by something outside the manifest
        // (legacy install.sh run, manual copy, …). The classifier maps
        // (empty_stored, present_deployed) to Conflict — preserve that.
        return {Status::Conflict,
                deployed.string() + " exists but is not tracked in the manifest"};
    }

    std::string deployed_hash;
    try {
        deployed_hash = hash_file(deployed);
    } catch (const std::exception& e) {
        return {Status::Conflict, std::string("cannot hash deployed file: ") + e.what()};
    }

    // Two-hash compare: stored vs deployed. The full three-hash dance
    // (stored, deployed, source) lands in Step 7 once the prompt UI
    // exists. For Step 6 we only need to distinguish "deployment still
    // matches what we wrote last time" from "something changed".
    if (deployed_hash == it->second.source_hash) {
        return {Status::Noop, "hyprland.conf matches stored hash"};
    }
    return {Status::Update,
            "hyprland.conf hash diverged from stored manifest value"};
}

Classification check_etckeeper(const Context& /*ctx*/, const Manifest& manifest) {
    // Masked is a sticky failure state — even after the file gets
    // written and the unit installed, it'll refuse to start. Surface
    // this before anything else so the install plan doesn't promise
    // work it can't deliver. R5/R6 from the master plan.
    const std::string state = systemctl_is_enabled("fox-etcwatch.path", /*user=*/true);
    if (state == "masked") {
        return {Status::Blocked,
                "fox-etcwatch.path is masked — `systemctl --user unmask fox-etcwatch.path` first"};
    }

    const auto it = manifest.modules.find("etckeeper");
    if (it == manifest.modules.end()) {
        return {Status::Fresh, "etckeeper has not run yet"};
    }

    if (state == "enabled") {
        return {Status::Noop, "fox-etcwatch.path enabled"};
    }
    // disabled, not-found, or any other state at this point means we
    // tracked a successful etckeeper run but the unit no longer
    // exists or has been disabled. Re-run will recreate it.
    return {Status::Update,
            "fox-etcwatch.path state is '" + (state.empty() ? "unknown" : state) + "', re-run needed"};
}

}  // namespace fox_install::state
