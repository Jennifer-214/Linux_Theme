// modules/throttling.cpp — interactive CPU throttling / power wizard.
//
// Mirrors mappings.sh::install_throttling. Four opt-in sub-steps:
//   1. Intel turbo disable (persisted via /etc/tmpfiles.d/disable-turbo.conf)
//   2. cpupower max-frequency cap (persisted via /etc/default/cpupower)
//   3. CPU governor selection (validated against the available list)
//   4. ThinkPad-only: AUR-install `throttled` (MSR undervolt + thermal-cap)
//
// Skipped under no-TTY since every step needs a hardware-specific
// answer that has no sensible auto-default.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cctype>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool tty_in() { return ::isatty(STDIN_FILENO); }
bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}
bool pacman_has(const std::string& pkg) {
    return sh::run({"sh", "-c", "pacman -Qi " + pkg + " &>/dev/null"}) == 0;
}

std::string strip(std::string s) {
    auto a = s.find_first_not_of(" \t\r\n");
    auto b = s.find_last_not_of(" \t\r\n");
    if (a == std::string::npos) return {};
    return s.substr(a, b - a + 1);
}

std::string read_text(const fs::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return strip(ss.str());
}

// y/n prompts go through ui::ask_yn now — see callsites below.

std::string prompt_line(const std::string& msg) {
    std::cout << "    " << msg << std::flush;
    std::string line;
    if (!std::getline(std::cin, line)) return {};
    return strip(line);
}

bool is_intel_cpu() {
    return read_text("/proc/cpuinfo").find("GenuineIntel") != std::string::npos;
}

bool is_thinkpad() {
    for (const char* p : { "/sys/class/dmi/id/product_family",
                            "/sys/class/dmi/id/product_version" }) {
        std::string s = read_text(p);
        std::string lower;
        for (char c : s) lower.push_back(std::tolower(static_cast<unsigned char>(c)));
        if (lower.find("thinkpad") != std::string::npos) return true;
    }
    return false;
}

std::string aur_helper() {
    if (have("yay"))  return "yay";
    if (have("paru")) return "paru";
    return {};
}

// Idempotent KEY=VALUE writer for /etc/default/cpupower. Replaces an
// existing key in place, else appends.
void persist_cpupower(const std::string& key, const std::string& val) {
    sh::run({"sudo", "install", "-d", "/etc/default"});
    sh::run({"sh", "-c", "[ -f /etc/default/cpupower ] || "
                          "echo \"\" | sudo tee /etc/default/cpupower >/dev/null"});
    if (sh::run({"sh", "-c",
                 "sudo grep -qE \"^" + key + "=\" /etc/default/cpupower"}) == 0) {
        sh::run({"sudo", "sed", "-i", "-E",
                 "s|^" + key + "=.*|" + key + "=" + val + "|",
                 "/etc/default/cpupower"});
    } else {
        sh::run({"sh", "-c",
                 "echo \"" + key + "=" + val + "\" | sudo tee -a /etc/default/cpupower >/dev/null"});
    }
}

}  // namespace

void run_throttling(Context& ctx) {
    ui::section("CPU throttling / power wizard");

    if (sh::dry_run()) {
        ui::substep("[dry-run] interactive: would offer Intel-turbo disable, "
                    "cpupower max-frequency cap, governor selection, "
                    "ThinkPad-only `throttled` AUR install");
        return;
    }
    if (!tty_in()) {
        ui::ok("no TTY for interactive wizard, skipping");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    std::cout <<
        "\n╭──────────────────────────────────────────────────────────────────╮\n"
        "│   CPU Throttling / Power Setup (optional)                        │\n"
        "├──────────────────────────────────────────────────────────────────┤\n"
        "│ Configure max-frequency cap, Intel turbo, governor, and (on     │\n"
        "│ ThinkPads) the 'throttled' MSR fix. Each step is opt-in.        │\n"
        "╰──────────────────────────────────────────────────────────────────╯\n";

    if (!ui::ask_yn("Configure CPU throttling now?", false, ctx.assume_yes)) return;

    bool is_intel = is_intel_cpu();
    bool thinkpad = is_thinkpad();
    std::string aur = aur_helper();

    // 1. Intel turbo disable.
    fs::path no_turbo = "/sys/devices/system/cpu/intel_pstate/no_turbo";
    if (is_intel && fs::exists(no_turbo)) {
        std::string state = read_text(no_turbo) == "1" ? "disabled" : "enabled";
        std::cout << "\n  Intel Turbo Boost is currently: " << state << "\n";
        if (ui::ask_yn("Disable Intel turbo on every boot?", false, ctx.assume_yes)) {
            sh::run({"sudo", "install", "-d", "/etc/tmpfiles.d"});
            sh::run({"sh", "-c",
                     "printf '%s\\n' '# Re-applied on every boot by systemd-tmpfiles' "
                     "'w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 1' "
                     "| sudo tee /etc/tmpfiles.d/disable-turbo.conf >/dev/null"});
            sh::run({"sh", "-c",
                     "sudo systemd-tmpfiles --create /etc/tmpfiles.d/disable-turbo.conf >/dev/null 2>&1 || true"});
            sh::run({"sh", "-c",
                     "echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null"});
            ui::ok("Intel Turbo disabled (now and on every boot)");
        }
    }

    // 2. cpupower max frequency.
    std::cout << "\n";
    if (ui::ask_yn("Cap CPU max frequency via cpupower?", false, ctx.assume_yes)) {
        if (!pacman_has("cpupower")) {
            std::cout << "    Installing cpupower...\n";
            sh::run({"sudo", "pacman", "-S", "--needed", "--noconfirm", "cpupower"});
        }
        std::string hw_max_khz = read_text("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq");
        if (!hw_max_khz.empty()) {
            try {
                long khz = std::stol(hw_max_khz);
                std::cout << "    Hardware max: " << (khz / 1000) << " MHz\n";
            } catch (...) {}
        }
        std::string max_mhz = prompt_line("Cap max frequency in MHz (e.g. 2400, blank to skip): ");
        if (!max_mhz.empty() && std::regex_match(max_mhz, std::regex(R"(\d+)"))) {
            long mhz = std::stol(max_mhz);
            if (mhz > 0) {
                if (sh::run({"sh", "-c",
                             "sudo cpupower frequency-set -u " + max_mhz + "MHz >/dev/null 2>&1"}) == 0) {
                    ui::ok("max set to " + max_mhz + " MHz (live)");
                } else {
                    ui::warn("live cap failed — still trying to persist");
                }
                persist_cpupower("max_freq", std::to_string(mhz * 1000));
                ui::ok("persisted via /etc/default/cpupower");
            }
        } else if (!max_mhz.empty()) {
            ui::warn("'" + max_mhz + "' is not a positive integer — skipping");
        }
    }

    // 3. Governor.
    if (have("cpupower")) {
        std::string avail = read_text("/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors");
        if (!avail.empty()) {
            std::cout << "\n  Available governors: " << avail << "\n";
            std::string gov = prompt_line("Set CPU governor (blank to skip): ");
            if (!gov.empty()) {
                if ((" " + avail + " ").find(" " + gov + " ") != std::string::npos) {
                    sh::run({"sh", "-c",
                             "sudo cpupower frequency-set -g " + gov + " >/dev/null 2>&1 || true"});
                    persist_cpupower("governor", "'" + gov + "'");
                    ui::ok("governor → " + gov + " (now and persistent)");
                } else {
                    ui::warn("'" + gov + "' not in available list — skipping");
                }
            }
        }
    }

    if (pacman_has("cpupower") && fs::exists("/etc/default/cpupower")) {
        if (sh::run({"systemctl", "is-enabled", "--quiet", "cpupower.service"}) != 0) {
            if (sh::run({"sh", "-c",
                         "sudo systemctl enable --now cpupower.service >/dev/null 2>&1"}) == 0) {
                ui::ok("cpupower.service enabled");
            }
        }
    }

    // 4. ThinkPad-only: `throttled`.
    if (thinkpad) {
        std::cout << "\n"
            "  ThinkPad detected — 'throttled' applies an MSR-based undervolt\n"
            "  + thermal-cap fix, configured via /etc/throttled.conf.\n";
        if (ui::ask_yn("Install throttled from AUR?", false, ctx.assume_yes)) {
            if (!pacman_has("throttled")) {
                if (!aur.empty()) {
                    sh::run({aur, "-S", "--needed", "throttled"});
                } else {
                    ui::warn("no AUR helper (yay/paru) — re-run with --deps first");
                }
            }
            if (pacman_has("throttled") &&
                sh::run({"systemctl", "is-active", "--quiet", "throttled.service"}) != 0) {
                if (sh::run({"sh", "-c",
                             "sudo systemctl enable --now throttled.service >/dev/null 2>&1"}) == 0) {
                    ui::ok("throttled enabled (edit /etc/throttled.conf to tune)");
                }
            }
        }
    }

    std::cout << "\n  Done. Verify with: cpupower frequency-info | head -20\n";
}

}  // namespace fox_install
