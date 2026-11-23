// modules/zram_conf.hpp — the zram step's config and its one decision: write ours, or leave the machine's own.
// Header-only so tests/test_zram.cpp drives the real decision.
#pragma once

#include <string>

namespace desk_install::zram {

inline constexpr const char* CONF_PATH = "/etc/systemd/zram-generator.conf";
inline constexpr const char* MARKER = "# foxml-managed";
inline constexpr const char* CONF_BODY =
    "# foxml-managed: compressed swap in RAM (zram-generator(8)), up to 8 GiB and never more than the RAM.\n"
    "[zram0]\n"
    "zram-size = min(ram, 8192)\n"
    "compression-algorithm = zstd\n";

enum class Action { Write, UpToDate, LeaveTheirs };

// conf_exists/conf_text: the file at CONF_PATH. zram_active: /proc/swaps lists a zram device.
inline Action decide(bool conf_exists, const std::string& conf_text, bool zram_active) {
    if (conf_exists && conf_text == CONF_BODY) return Action::UpToDate;
    if (conf_exists && conf_text.rfind(MARKER, 0) != 0) return Action::LeaveTheirs;  // someone's own config
    if (!conf_exists && zram_active) return Action::LeaveTheirs;                    // zram set up another way
    return Action::Write;
}

}  // namespace desk_install::zram
