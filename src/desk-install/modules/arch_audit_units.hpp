// modules/arch_audit_units.hpp — the foxml-arch-audit user units. In a header so the state check can tell a deployed
// copy is out of date, and tests/test_arch_audit can run the service's own command with stand-ins.
#pragma once

#include "../core/idempotency.hpp"

#include <filesystem>

namespace desk_install {

// Until 2026-11-15 this ran `arch-audit -uf`. -f takes a FORMAT, so arch-audit stopped at a usage error, the error went
// to /dev/null and the daily notice never came. Now -f prints one "name → fixed version (severity)" line per package,
// only lines of that shape are counted (a stray one, such as a sandbox banner, is not a package), and a check that
// fails, offline say, fails the unit instead of passing quietly. %% is systemd unit escaping (a bare %n would expand
// to the unit name); the script has no backslash and no ${…}, which systemd would rewrite before sh sees them.
inline constexpr const char* ARCH_AUDIT_SERVICE =
    "[Unit]\n"
    "Description=FoxML — daily arch-audit check against Arch Linux security advisories\n"
    "After=network-online.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "# -u: only packages whose fix has shipped, one \"name → fixed version (severity)\" line each.\n"
    "ExecStart=/bin/sh -c 'out=$(arch-audit -u -C never -f \"%%n → %%v (%%s)\") || exit 1; "
        "fixes=$(printf \"%%s\" \"$out\" | grep -F \" → \"); [ -n \"$fixes\" ] || exit 0; "
        "count=$(printf \"%%s\" \"$fixes\" | grep -c .); "
        "notify-send --app-name=FoxML -u critical \"arch-audit: $count package(s) with available fixes\" "
        "\"$(printf \"%%s\" \"$fixes\" | head -n 10)\"'\n";

inline constexpr const char* ARCH_AUDIT_TIMER =
    "[Unit]\n"
    "Description=Run arch-audit daily\n"
    "\n"
    "[Timer]\n"
    "OnCalendar=daily\n"
    "Persistent=true\n"
    "RandomizedDelaySec=600\n"
    "\n"
    "[Install]\n"
    "WantedBy=timers.target\n";

// Both units in `unit_dir` are today's bodies.
inline bool arch_audit_units_current(const std::filesystem::path& unit_dir) {
    return idem::up_to_date(unit_dir / "foxml-arch-audit.service", ARCH_AUDIT_SERVICE, /*force_reapply=*/false) &&
           idem::up_to_date(unit_dir / "foxml-arch-audit.timer", ARCH_AUDIT_TIMER, /*force_reapply=*/false);
}

}  // namespace desk_install
