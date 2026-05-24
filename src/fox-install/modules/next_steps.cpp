// modules/next_steps.cpp — end-of-install reminders + optional fox-arm chain.
//
// Mirrors the tail of install.sh.legacy:
//   * "Next steps" reminder lines (OpenCode ready, GitHub workspace,
//     NVIDIA reboot needed) shown only when the relevant module ran.
//   * Final fingerprint-reader detection box pointing at fox-fingerprint
//     for biometric auto-setup.
//   * `fox-arm` chain when the user passes --arm or --arm-heavy (walks
//     them through every opt-in defense interactively).
//
// Runs LAST in the registry so it fires after summary.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdlib>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <string>
#include <system_error>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) { return sh::have(bin); }

bool tty_in() { return ::isatty(STDIN_FILENO); }

}  // namespace

void run_next_steps(Context& ctx) {
    // Don't print this block in dry-run — it's user-facing copy that
    // would clutter the plan output.
    if (sh::dry_run()) return;

    std::printf("\n");
    ui::section("Next steps");

    if (have("opencode")) {
        ui::ok("OpenCode is ready — run `opencode` to start local AI development");
        ui::substep("AI notifications wired via mako/dunst on turn complete + "
                    "subagent done + input needed (ALT+SHIFT+E for triage)");
        ui::substep("restart any in-flight agent sessions to load the new hooks");
    }

    if (fs::is_directory(ctx.home / "code")) {
        std::error_code ec;
        std::size_t repos = 0;
        for (auto& e : fs::directory_iterator(ctx.home / "code", ec)) {
            if (e.is_directory() && fs::exists(e.path() / ".git")) ++repos;
        }
        if (repos > 0) {
            ui::ok("GitHub workspace ready — " + std::to_string(repos) +
                   " repo(s) in ~/code");
        }
    }

    if (ctx.has_nvidia) {
        ui::ok("NVIDIA: reboot to load the nvidia kernel module + apply "
               "mkinitcpio MODULES + nvidia_drm.modeset=1");
    }

    // Fingerprint setup hint — only show if the reader is present AND
    // the user doesn't have any fingerprints enrolled yet. Suppressing
    // it once enrolled means re-runs don't keep nagging about
    // fox-fingerprint when there's nothing to set up.
    if (ctx.has_fprint && have("fprintd-list")) {
        std::string out;
        sh::capture({"sh", "-c",
                     "fprintd-list \"$USER\" 2>/dev/null"}, out);
        bool enrolled = out.find("#") != std::string::npos &&
                        out.find("No fingerprints enrolled") == std::string::npos;
        if (!enrolled) {
            std::cout << "\n"
                "  ╭──────────────────────────────────────────────────────────────────╮\n"
                "  │  Hardware Detected: Fingerprint Reader (no enrollment yet)       │\n"
                "  ├──────────────────────────────────────────────────────────────────┤\n"
                "  │  To enroll a finger + wire it into the login screen + sudo:      │\n"
                "  │    Run: fox-fingerprint                                          │\n"
                "  ╰──────────────────────────────────────────────────────────────────╯\n";
        }
    }

    // fox-arm interactive defense walkthrough. Only fires when:
    //   * the user passed --arm (off by default — opt-in for the
    //     "walk me through every defense" experience),
    //   * we have a TTY,
    //   * we're not under --yes (the wizard is interactive by design).
    // FOXML_ARM=1 / FOXML_ARM_HEAVY=1 from env also trigger it (lets
    // fox install --arm propagate when bash wrappers re-exec).
    bool want_arm = std::getenv("FOXML_ARM") != nullptr;
    bool want_arm_heavy = std::getenv("FOXML_ARM_HEAVY") != nullptr;
    if ((want_arm || want_arm_heavy) && tty_in() && !ctx.assume_yes) {
        std::printf("\n");
        ui::section("fox-arm — walk through every opt-in defense");
        if (have("fox-arm")) {
            if (want_arm_heavy) sh::run({"fox-arm", "--heavy"});
            else                sh::run({"fox-arm"});
        } else {
            ui::warn("fox-arm not on PATH — install seems incomplete");
        }
    }

    std::printf("\n");
}

}  // namespace fox_install
