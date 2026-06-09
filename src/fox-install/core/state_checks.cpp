#include "state_checks.hpp"

#include "../../fox-common/shell.hpp"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install::state {

namespace {

bool pacman_installed(const std::string& pkg) {
    // pacman -Qi <pkg> exits 0 if installed, 1 otherwise. We need to
    // suppress both stdout AND stderr (pacman writes "error: package
    // not found" on the negative case — normal for state probes, but
    // pollutes the install log). Use a shell for the redirection but
    // pass pkg as a positional argument ($1) so it stays out of shell
    // parsing — pkg comes from the on-disk manifest which a user could
    // craft if they edited it by hand.
    return sh::run({"sh", "-c",
                    "pacman -Qi \"$1\" >/dev/null 2>&1",
                    "sh",          // $0
                    pkg}) == 0;   // $1 — safe positional substitution
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

Classification check_etckeeper(const Context& ctx, const Manifest& manifest) {
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
        // Enabled isn't the whole story: the module also owns the
        // commit-stamp hook and the service-unit BODY (the %-escaping
        // repair changed it) — report Update so a re-run converges them.
        if (!fs::exists("/etc/etckeeper/commit.d/60foxml-stamp")) {
            return {Status::Update,
                    "commit-stamp hook missing — re-run installs /etc/etckeeper/commit.d/60foxml-stamp"};
        }
        std::ifstream svc(ctx.config_home / "systemd/user/fox-etcwatch.service");
        std::ostringstream body;
        body << svc.rdbuf();
        if (body.str().find("/var/lib/foxml/etc-last-commit") == std::string::npos) {
            return {Status::Update,
                    "fox-etcwatch.service predates stamp-based suppression — re-run redeploys it"};
        }
        return {Status::Noop, "fox-etcwatch.path enabled + stamp hook present"};
    }
    // disabled, not-found, or any other state at this point means we
    // tracked a successful etckeeper run but the unit no longer
    // exists or has been disabled. Re-run will recreate it.
    return {Status::Update,
            "fox-etcwatch.path state is '" + (state.empty() ? "unknown" : state) + "', re-run needed"};
}

namespace {

// Shared shape for any systemd-unit module: masked → Blocked;
// untracked → Fresh; enabled → Noop; anything else with manifest entry
// → Update. The user flag picks between --user and system scope; the
// rest of the wording is uniform.
Classification unit_check(
    const Manifest& manifest,
    const std::string& slug,
    const std::string& unit,
    bool user
) {
    const std::string state = systemctl_is_enabled(unit, user);
    const char* scope = user ? " --user" : "";
    if (state == "masked") {
        return {Status::Blocked,
                unit + " is masked — `systemctl" + scope + " unmask " + unit + "` first"};
    }
    const auto it = manifest.modules.find(slug);
    if (it == manifest.modules.end()) {
        return {Status::Fresh, slug + " has not run yet"};
    }
    if (state == "enabled") {
        return {Status::Noop, unit + " enabled"};
    }
    return {Status::Update,
            unit + " state is '" + (state.empty() ? "unknown" : state) + "', re-run needed"};
}

// Pacman-package existence check. Used by modules whose entire "did
// it run?" question reduces to "is package X installed?".
Classification package_check(
    const Manifest& manifest,
    const std::string& slug,
    const std::string& pkg
) {
    const bool present = pacman_installed(pkg);
    const auto it = manifest.modules.find(slug);
    const bool tracked = (it != manifest.modules.end());
    if (!tracked) {
        if (present) return {Status::Noop, pkg + " already installed (untracked, treated as already-done)"};
        return {Status::Fresh, slug + " has not run yet"};
    }
    if (present) return {Status::Noop, pkg + " installed"};
    return {Status::Update, pkg + " missing, re-run needed"};
}

}  // namespace

Classification check_arch_audit(const Context& /*ctx*/, const Manifest& manifest) {
    return unit_check(manifest, "arch_audit", "foxml-arch-audit.timer", /*user=*/true);
}

Classification check_vault(const Context& /*ctx*/, const Manifest& manifest) {
    return unit_check(manifest, "vault", "fox-vault.service", /*user=*/true);
}

Classification check_ufw(const Context& /*ctx*/, const Manifest& manifest) {
    return unit_check(manifest, "ufw", "ufw.service", /*user=*/false);
}

Classification check_endlessh(const Context& /*ctx*/, const Manifest& manifest) {
    // endlessh installs as either endlessh.service (C build) or
    // endlessh-go.service (Go AUR build). Probe the canonical name;
    // if it's not enabled but endlessh-go.service is, classify Noop
    // anyway so we don't insist on re-running just to swap units.
    Classification primary = unit_check(manifest, "endlessh", "endlessh.service", /*user=*/false);
    if (primary.status == Status::Noop || primary.status == Status::Blocked) return primary;
    const auto it = manifest.modules.find("endlessh");
    if (it != manifest.modules.end()
        && systemctl_is_enabled("endlessh-go.service", /*user=*/false) == "enabled") {
        return {Status::Noop, "endlessh-go.service enabled (AUR build)"};
    }
    return primary;
}

Classification check_greetd(const Context& /*ctx*/, const Manifest& manifest) {
    return unit_check(manifest, "greetd", "greetd.service", /*user=*/false);
}

Classification check_papirus_icons(const Context& /*ctx*/, const Manifest& manifest) {
    return package_check(manifest, "papirus_icons", "papirus-icon-theme");
}

Classification check_catppuccin_cursor(const Context& ctx, const Manifest& manifest) {
    const fs::path theme_dir = ctx.home / ".icons"
        / "catppuccin-mocha-peach-cursors" / "cursors";
    const bool present = fs::is_directory(theme_dir);
    const auto it = manifest.modules.find("catppuccin_cursor");
    const bool tracked = (it != manifest.modules.end());
    if (!tracked) {
        if (present) return {Status::Noop, theme_dir.string() + " already present (untracked)"};
        return {Status::Fresh, "catppuccin_cursor has not run yet"};
    }
    if (present) return {Status::Noop, "cursor theme directory present"};
    return {Status::Update, theme_dir.string() + " missing, re-run needed"};
}

Classification check_gpg_agent_cache(const Context& ctx, const Manifest& manifest) {
    const fs::path conf = ctx.home / ".gnupg" / "gpg-agent.conf";
    const bool present = fs::exists(conf);
    const auto it = manifest.modules.find("gpg_agent_cache");
    const bool tracked = (it != manifest.modules.end());
    if (!tracked) {
        if (present) return {Status::Noop, conf.string() + " already present (untracked)"};
        return {Status::Fresh, "gpg_agent_cache has not run yet"};
    }
    if (present) return {Status::Noop, conf.string() + " present"};
    return {Status::Update, conf.string() + " missing, re-run needed"};
}

Classification check_keyring_full(const Context& /*ctx*/, const Manifest& manifest) {
    // The install masks four units; we probe the canonical one
    // (gnome-keyring-daemon.service). If it's masked, the install
    // ran successfully. Probing all four would be more thorough but
    // also more expensive — one sentinel is enough.
    const std::string state = systemctl_is_enabled(
        "gnome-keyring-daemon.service", /*user=*/true);
    const auto it = manifest.modules.find("keyring_full");
    const bool tracked = (it != manifest.modules.end());
    if (!tracked) {
        return {Status::Fresh, "keyring_full has not run yet"};
    }
    if (state == "masked") return {Status::Noop, "gnome-keyring-daemon.service masked"};
    return {Status::Update,
            "gnome-keyring-daemon.service state is '"
            + (state.empty() ? "unknown" : state)
            + "', re-run needed to re-mask"};
}

Classification check_noexec_tmp(const Context& /*ctx*/, const Manifest& manifest) {
    // The install edits /etc/fstab to add noexec,nosuid,nodev to the
    // /tmp tmpfs line. A non-tmpfs /tmp (e.g., a separate disk
    // mount) means the user has a non-stock setup and the install
    // module would skip — classify Noop in that case too.
    const auto it = manifest.modules.find("noexec_tmp");
    const bool tracked = (it != manifest.modules.end());
    std::string fstab_contents;
    try {
        std::ifstream f("/etc/fstab");
        std::stringstream ss; ss << f.rdbuf();
        fstab_contents = ss.str();
    } catch (...) {
        // unreadable /etc/fstab → can't classify, default to Fresh
        // so the install attempts again if tracked-but-unverifiable.
        if (tracked) return {Status::Update, "/etc/fstab unreadable, re-run to be safe"};
        return {Status::Fresh, "/etc/fstab unreadable"};
    }

    const bool locked_down =
        fstab_contents.find("noexec") != std::string::npos &&
        fstab_contents.find("/tmp") != std::string::npos;
    if (!tracked) {
        if (locked_down) return {Status::Noop, "/tmp already has lockdown options (untracked)"};
        return {Status::Fresh, "noexec_tmp has not run yet"};
    }
    if (locked_down) return {Status::Noop, "/tmp fstab line has noexec/nosuid/nodev"};
    return {Status::Update, "/tmp fstab line missing lockdown options, re-run needed"};
}

Classification check_mac_random(const Context& /*ctx*/, const Manifest& manifest) {
    // System-file module (not a unit). Hash the deployed conf against
    // the manifest's stored hash — the same pattern check_render uses.
    const fs::path deployed = "/etc/NetworkManager/conf.d/00-foxml-mac-random.conf";
    const auto it = manifest.modules.find("mac_random");
    const bool tracked = (it != manifest.modules.end());

    if (!fs::exists(deployed)) {
        if (!tracked) return {Status::Fresh, "no manifest entry, conf absent"};
        return {Status::Conflict,
                "manifest says mac_random ran, but " + deployed.string() + " is missing"};
    }
    if (!tracked) {
        return {Status::Conflict,
                deployed.string() + " exists but is not tracked in the manifest"};
    }

    std::string deployed_hash;
    try {
        deployed_hash = hash_file(deployed);
    } catch (const std::exception& e) {
        // Permission-denied is common here — the conf lives under
        // /etc and is root-owned 0644 so we expect to be able to
        // read it, but a non-standard chmod could trip us up. Treat
        // as a soft Conflict rather than crashing.
        return {Status::Conflict, std::string("cannot hash deployed file: ") + e.what()};
    }

    if (deployed_hash == it->second.source_hash) {
        return {Status::Noop, "macrand conf matches stored hash"};
    }
    return {Status::Update, "macrand conf diverged from stored manifest value"};
}

}  // namespace fox_install::state
