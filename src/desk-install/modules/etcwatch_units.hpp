// modules/etcwatch_units.hpp — the fox-etcwatch user units. In a header so the state check can tell a deployed copy is
// out of date, and tests/test_etcwatch can run the service's own command with stand-ins.
#pragma once

#include "../core/idempotency.hpp"

#include <filesystem>

namespace desk_install {

inline constexpr const char* ETCWATCH_PATH_UNIT =
    "[Unit]\n"
    "Description=fox-etcwatch — alert on changes to sensitive /etc subdirs\n"
    "\n"
    "[Path]\n"
    "PathChanged=/etc/ssh\n"
    "PathChanged=/etc/sudoers.d\n"
    "PathChanged=/etc/pam.d\n"
    "PathChanged=/etc/ufw\n"
    "PathChanged=/etc/fail2ban\n"
    "PathChanged=/etc/audit/rules.d\n"
    "PathChanged=/etc/sysctl.d\n"
    "\n"
    "[Install]\n"
    "WantedBy=default.target\n";

// The script has no backslash and no ${…}: systemd would rewrite those before sh sees them.
inline constexpr const char* ETCWATCH_SERVICE_UNIT =
    "[Unit]\n"
    "Description=fox-etcwatch — dispatch /etc change\n"
    "# A burst of /etc writes (an install, a pacman run) starts this service many times in a few seconds. Past\n"
    "# systemd's default start limit (5 in 10 s) the failure passes to fox-etcwatch.path, which then stops watching\n"
    "# until it is reset (2026-11-15). No limit here; the script sends at most one alert a minute instead, and the\n"
    "# alert's `etckeeper unclean` lists every change.\n"
    "StartLimitIntervalSec=0\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "# Suppress alerts that fire from etckeeper's own commits — the commit.d\n"
    "# stamp hook records every etckeeper commit; a stamp younger than 30s\n"
    "# means the change is etckeeper's, not an out-of-band edit. We can't\n"
    "# stat /etc/.git/HEAD here: it's root-only and this is a user unit.\n"
    "# %% below is systemd unit escaping for a literal % in the command.\n"
    "ExecStart=/bin/sh -c 'stamp=$(stat -c %%Y /var/lib/foxml/etc-last-commit 2>/dev/null || echo 0); "
        "now=$(date +%%s); age=$((now - stamp)); "
        "last=$(cat \"$XDG_RUNTIME_DIR/foxml-etcwatch.last\" 2>/dev/null); "
        "case \"$last\" in \"\"|*[!0-9]*) last=0 ;; esac; "
        "if [ \"$age\" -gt 30 ] && [ $((now - last)) -ge 60 ]; then "
        "echo \"$now\" > \"$XDG_RUNTIME_DIR/foxml-etcwatch.last\"; "
        "desk-dispatch \"etc-change\" "
        "\"/etc modified outside an etckeeper commit (paths: ssh/sudoers.d/pam.d/ufw/fail2ban/audit/sysctl.d). "
        "Run: sudo etckeeper unclean\" 2>/dev/null || true; "
        "fi'\n";

// Both units in `unit_dir` are today's bodies.
inline bool etcwatch_units_current(const std::filesystem::path& unit_dir) {
    return idem::up_to_date(unit_dir / "fox-etcwatch.path", ETCWATCH_PATH_UNIT, /*force_reapply=*/false) &&
           idem::up_to_date(unit_dir / "fox-etcwatch.service", ETCWATCH_SERVICE_UNIT, /*force_reapply=*/false);
}

}  // namespace desk_install
