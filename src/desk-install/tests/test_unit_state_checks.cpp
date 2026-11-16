// The state checks that compare deployed unit bodies with today's (core/state_checks.cpp): an enabled unit can still
// run an old body (until 2026-11-15, an arch-audit service that errored every day without a word, and an etcwatch
// service whose start limit switched the watcher off), so the installer has to report Update and redeploy it.
//   - arch_audit: the timer enabled, the old service → Update; today's units → Noop;
//   - etckeeper: fox-etcwatch.path enabled, the old service → Update; today's units → Noop; today's units with the path
//     unit not watching (failed) → Update. The check looks for its commit-stamp hook at
//     /etc/etckeeper/commit.d/60foxml-stamp, so this half runs only where that file exists;
//   - a check only asks: a stand-in systemctl first on PATH says every user unit is enabled and active (inactive while a
//     marker file exists) and records any other call.

#include "../core/state_checks.hpp"
#include "../modules/arch_audit_units.hpp"
#include "../modules/etcwatch_units.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace desk_install;
using state::Status;

namespace {

int failed = 0;
void expect(const std::string& what, bool ok) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
}

std::string slurp(const fs::path& p) {
    std::ifstream f(p);
    std::stringstream b;
    b << f.rdbuf();
    return b.str();
}

std::string got(const state::Classification& c) {
    return std::string(", got ") + state::status_name(c.status) + " (" + c.reason + ")";
}

// The service bodies the installer deployed before 2026-11-15.
const char* OLD_ARCH_AUDIT_SERVICE =
    "[Unit]\n"
    "Description=FoxML — daily arch-audit check against Arch Linux security advisories\n"
    "After=network-online.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "# -uf : upgrades-only — only CVEs with a fix available.\n"
    "# %% is systemd unit escaping — a bare %s would expand to the user shell.\n"
    "ExecStart=/bin/sh -c 'out=$(arch-audit -uf 2>/dev/null); "
        "if [ -n \"$out\" ]; then "
        "count=$(printf \"%%s\" \"$out\" | wc -l); "
        "notify-send -u critical -t 30000 "
        "\"arch-audit: $count package(s) with available fixes\" "
        "\"$(printf \"%%s\" \"$out\" | head -10)\"; "
        "fi'\n";

const char* OLD_ETCWATCH_SERVICE =
    "[Unit]\n"
    "Description=fox-etcwatch — dispatch /etc change\n"
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
        "if [ \"$age\" -gt 30 ]; then "
        "desk-dispatch \"etc-change\" "
        "\"/etc modified outside an etckeeper commit (paths: ssh/sudoers.d/pam.d/ufw/fail2ban/audit/sysctl.d). "
        "Run: sudo etckeeper unclean\" 2>/dev/null || true; "
        "fi'\n";

}  // namespace

int main() {
    // In the build tree, not /tmp: the stand-in must be executable and /tmp may be noexec.
    const fs::path t = fs::path(BUILD_DIR) / ("unit_state_checks_" + std::to_string(::getpid()));
    fs::remove_all(t);
    fs::create_directories(t / "bin");
    const fs::path asked = t / "asked", other = t / "other", inactive = t / "inactive";
    std::ofstream(t / "bin/systemctl")
        << "#!/bin/sh\n"
           "if [ \"$1\" = --user ] && [ \"$2\" = is-enabled ] && [ $# -eq 3 ]; then\n"
           "    echo \"$3\" >> '" << asked.string() << "'; echo enabled; exit 0\n"
           "fi\n"
           "if [ \"$1\" = --user ] && [ \"$2\" = is-active ] && [ \"$3\" = --quiet ] && [ $# -eq 4 ]; then\n"
           "    echo \"$4\" >> '" << asked.string() << "'; [ -e '" << inactive.string() << "' ] && exit 3; exit 0\n"
           "fi\n"
           "echo \"$*\" >> '" << other.string() << "'\n"
           "exit 1\n";
    fs::permissions(t / "bin/systemctl", fs::perms::owner_all, fs::perm_options::add);
    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", ((t / "bin").string() + ":/usr/bin:/bin").c_str(), 1);

    Context ctx;
    ctx.config_home = t / "config";
    const fs::path units = ctx.config_home / "systemd/user";
    fs::create_directories(units);
    state::Manifest manifest;
    manifest.modules["arch_audit"] = {"test", "", "2026-11-15T00:00:00Z"};
    manifest.modules["etckeeper"] = {"test", "", "2026-11-15T00:00:00Z"};

    std::ofstream(units / "foxml-arch-audit.timer") << ARCH_AUDIT_TIMER;
    std::ofstream(units / "foxml-arch-audit.service") << OLD_ARCH_AUDIT_SERVICE;
    auto c = state::check_arch_audit(ctx, manifest);
    expect("arch_audit: the timer enabled, the old service: Update" + got(c), c.status == Status::Update);
    std::ofstream(units / "foxml-arch-audit.service") << ARCH_AUDIT_SERVICE;
    c = state::check_arch_audit(ctx, manifest);
    expect("arch_audit: today's units: Noop" + got(c), c.status == Status::Noop);

    bool etcwatch = fs::exists("/etc/etckeeper/commit.d/60foxml-stamp");
    if (etcwatch) {
        std::ofstream(units / "fox-etcwatch.path") << ETCWATCH_PATH_UNIT;
        std::ofstream(units / "fox-etcwatch.service") << OLD_ETCWATCH_SERVICE;
        c = state::check_etckeeper(ctx, manifest);
        expect("etckeeper: the path unit enabled, the old service: Update" + got(c), c.status == Status::Update);
        std::ofstream(units / "fox-etcwatch.service") << ETCWATCH_SERVICE_UNIT;
        c = state::check_etckeeper(ctx, manifest);
        expect("etckeeper: today's units: Noop" + got(c), c.status == Status::Noop);
        // Written, enabled, and still not watching (failed after a burst of /etc writes): a re-run starts it.
        std::ofstream(inactive) << "";
        c = state::check_etckeeper(ctx, manifest);
        expect("etckeeper: today's units, the path unit not watching: Update" + got(c), c.status == Status::Update);
        fs::remove(inactive);
    } else {
        std::printf("  skip the etckeeper half: no /etc/etckeeper/commit.d/60foxml-stamp on this machine\n");
    }

    expect("the checks asked systemctl nothing but --user is-enabled and is-active, got '" + slurp(other) + "'", !fs::exists(other));
    const std::string units_asked = slurp(asked);
    expect("the arch_audit check asked about foxml-arch-audit.timer",
           units_asked.find("foxml-arch-audit.timer\n") != std::string::npos);
    expect("the etckeeper check asked about fox-etcwatch.path",
           !etcwatch || units_asked.find("fox-etcwatch.path\n") != std::string::npos);

    ::setenv("PATH", saved.c_str(), 1);
    fs::remove_all(t);
    if (failed) { std::fprintf(stderr, "unit state check tests: %d FAILED\n", failed); return 1; }
    std::printf("unit state check tests: OK%s\n", etcwatch ? "" : " (etckeeper half skipped)");
    return 0;
}
