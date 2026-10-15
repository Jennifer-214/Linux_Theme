// modules/foxml_health_boot_script.hpp — the per-boot health script run_foxml_health_boot installs. In a header so
// tests/test_health_boot can run it with stand-ins for fox-sec-health, loginctl, sudo and fox-dispatch.
#pragma once

namespace fox_install {

// Helper script invoked by the unit. Bash, not C++ — it just needs to
// log + exec + always exit 0. Lives in /usr/local/lib/foxml/ alongside
// boot_sync's esp-sync helper.
inline constexpr const char* BOOT_HEALTH_SCRIPT =
    "#!/bin/bash\n"
    "# foxml-managed — per-boot health probe.\n"
    "# Runs the A-category (boot path) checks once at boot, logs to\n"
    "# both journal AND /var/log/foxml/last-boot-health.txt so the\n"
    "# user can read it even when journald is unhappy. Always exits 0\n"
    "# so a critical fail doesn't break boot — the LOG is the signal.\n"
    "set -u\n"
    "LOG_DIR=/var/log/foxml\n"
    "LOG_FILE=\"$LOG_DIR/last-boot-health.txt\"\n"
    "install -d -m 0755 \"$LOG_DIR\"\n"
    "rc=0\n"
    "{\n"
    "    echo \"foxml-health-boot at $(date -Iseconds)\"\n"
    "    echo \"running kernel: $(uname -r)\"\n"
    "    echo \"---\"\n"
    "    /usr/local/bin/fox-sec-health --only A --no-slow --verbose 2>&1\n"
    "    rc=$?\n"
    "    echo \"---\"\n"
    "    echo \"exit code: $rc (0=ok 1=warn 2=critical 3=high)\"\n"
    "    echo \"finished at $(date -Iseconds)\"\n"
    "} > \"$LOG_FILE\"\n"
    "# Not `{ ... } | tee`: bash runs each part of a pipeline in a subshell, so rc stayed 0 out here and the alert below\n"
    "# never fired. The block writes the log in this shell; the journal gets it now.\n"
    "cat \"$LOG_FILE\"\n"
    "# Phase 6: phone-alert escalation on Critical.\n"
    "# fox-dispatch is per-user; the service runs as root, so we drop\n"
    "# back to the local users with active sessions and let them fire\n"
    "# the dispatch in their own context (token files live in $HOME).\n"
    "# Anything ≥ exit-code 2 = critical OR high.\n"
    "if [ \"$rc\" -ge 2 ]; then\n"
    "    summary=$(grep -E '^(fail|warn) ' \"$LOG_FILE\" | head -3 | tr '\\n' '; ')\n"
    "    for user in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do\n"
    "        if command -v fox-dispatch >/dev/null 2>&1; then\n"
    "            sudo -n -u \"$user\" fox-dispatch 'foxml-health-boot' \\\n"
    "                \"critical boot-path health fail on $(uname -n): $summary\" \\\n"
    "                2>/dev/null || true\n"
    "        fi\n"
    "    done\n"
    "fi\n"
    "exit 0\n";

}  // namespace fox_install
