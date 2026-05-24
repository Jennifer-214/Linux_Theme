// modules/privacy.cpp — DNS-over-HTTPS + DNSSEC strictness via systemd-resolved.
//
// Mirrors install_privacy() + install_resolved_dnssec() in mappings.sh:
//   * foxml-doh.conf  — DNS servers + DoH (NO DNSSEC line; lives in the
//                       separate drop-in below so a sibling-strip pass
//                       doesn't have to touch this file).
//   * 00-foxml-dnssec.conf — DNSSEC level. Defaults to allow-downgrade
//                       (laptop-safe). Interactive 0/1/2 picker prompts
//                       when running on a TTY; --yes / no-TTY accepts
//                       the default.
//   * comment out any explicit DNSSEC= in /etc/systemd/resolved.conf
//     (main config wins against drop-ins in some load orders).
//   * strip DNSSEC= from any sibling drop-ins so the lexically-first
//     foxml-dnssec.conf is the sole source of truth.
//   * clear NetworkManager per-connection DNSSEC overrides — NM pushes
//     per-link DNSSEC settings to resolved that beat the global one;
//     a connection with connection.dnssec=yes will keep failing even
//     after the drop-in lands.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* DOH_BODY =
    "[Resolve]\n"
    "DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com "
    "8.8.8.8#dns.google 8.8.4.4#dns.google\n"
    "DNSOverHTTPS=yes\n"
    "FallbackDNS=1.1.1.1 8.8.8.8\n";

constexpr const char* DOH_PATH       = "/etc/systemd/resolved.conf.d/foxml-doh.conf";
constexpr const char* DNSSEC_PATH    = "/etc/systemd/resolved.conf.d/00-foxml-dnssec.conf";

// Map the bash picker's 0/1/2 to the literal resolved.conf value.
const char* dnssec_value(char choice) {
    switch (choice) {
        case '0': return "no";
        case '2': return "yes";
        default:  return "allow-downgrade";   // '1' or anything unexpected
    }
}

bool write_root_file(const fs::path& path, const std::string& body) {
    return sh::write_root_atomic(path, body);
}

}  // namespace

void run_privacy(Context& ctx) {
    ui::section("Configuring DNS-over-HTTPS + DNSSEC strictness");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write " + std::string(DOH_PATH) +
                    " and " + DNSSEC_PATH +
                    ", comment any explicit DNSSEC= in /etc/systemd/resolved.conf, "
                    "strip DNSSEC= from sibling drop-ins, enable systemd-resolved");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    if (idem::up_to_date(DOH_PATH, DOH_BODY, ctx.force_reapply)) {
        ui::skipped(std::string(DOH_PATH) + " already up to date");
    } else if (!write_root_file(DOH_PATH, DOH_BODY)) {
        ui::err("could not install " + std::string(DOH_PATH));
        return;
    } else {
        ui::ok("wrote " + std::string(DOH_PATH));
    }

    // DNSSEC strictness picker. Re-prompt only when the drop-in is
    // missing or --full was passed; the user's last choice is whatever
    // currently lives at DNSSEC_PATH, so preserve it across re-runs.
    if (fs::exists(DNSSEC_PATH) && !ctx.force_reapply) {
        ui::skipped(std::string(DNSSEC_PATH) + " already configured — keeping current DNSSEC choice");
    } else {
        std::printf("  DNSSEC strictness:\n"
                    "    [0] off — DoH only (no validation)\n"
                    "    [1] relaxed (allow-downgrade) [recommended]\n"
                    "    [2] strict (yes) — can wedge DNS on hotel/cafe wifi\n"
                    "  choose [1]: ");
        char picked = ui::ask_choice("", "012", '1', ctx.assume_yes);
        const char* val = dnssec_value(picked);
        std::string dnssec_body = std::string("[Resolve]\nDNSSEC=") + val + "\n";
        if (!write_root_file(DNSSEC_PATH, dnssec_body)) {
            ui::warn("could not install " + std::string(DNSSEC_PATH));
        } else {
            ui::ok("wrote " + std::string(DNSSEC_PATH) + " (DNSSEC=" + val + ")");
        }
    }

    // Comment any active DNSSEC= line in the main resolved.conf — leaving
    // it set there can override the drop-in in some systemd load orders
    // and cause the v2.4.7 chrony startup deadlock to re-appear.
    sh::run({"sudo", "sed", "-i",
             "s/^\\([[:space:]]*\\)DNSSEC=/\\1#DNSSEC=/",
             "/etc/systemd/resolved.conf"});

    // Strip DNSSEC= from sibling drop-ins so 00-foxml-dnssec.conf is the
    // single source of truth (foxml-doh.conf body above intentionally
    // does NOT include a DNSSEC= line for this reason).
    sh::run({"sh", "-c",
             "for f in /etc/systemd/resolved.conf.d/*.conf; do "
             "  case \"$f\" in *00-foxml-dnssec.conf) continue ;; esac; "
             "  if sudo grep -q '^DNSSEC=' \"$f\" 2>/dev/null; then "
             "    sudo sed -i '/^DNSSEC=/d' \"$f\"; "
             "  fi; "
             "done"});

    if (sh::systemctl_enable("systemd-resolved", /*user=*/false) != 0) {
        ui::warn("systemd-resolved enable failed — re-run after `sudo -v`");
        return;
    }

    if (!fs::is_symlink("/etc/resolv.conf")) {
        sh::run({"sudo", "ln", "-rsf",
                 "/run/systemd/resolve/stub-resolv.conf", "/etc/resolv.conf"});
        ui::ok("linked /etc/resolv.conf → stub-resolv.conf");
    }

    // Clear NetworkManager per-connection DNSSEC overrides — NM pushes
    // per-link DNSSEC settings to resolved that beat the global setting
    // outright. A connection with connection.dnssec=yes will keep
    // failing regardless of what 00-foxml-dnssec.conf says. Empty value
    // means "inherit from systemd-resolved global". Cheap + idempotent.
    if (sh::run({"sh", "-c",
                 "command -v nmcli >/dev/null 2>&1 && "
                 "systemctl is-active --quiet NetworkManager"}) == 0) {
        sh::run({"sh", "-c",
                 "_cleared=0; "
                 "while IFS= read -r uuid; do "
                 "  [ -z \"$uuid\" ] && continue; "
                 "  cur=$(nmcli -t -g connection.dnssec connection show \"$uuid\" 2>/dev/null); "
                 "  if [ -n \"$cur\" ] && [ \"$cur\" != \"--\" ] && [ \"$cur\" != \"default\" ]; then "
                 "    sudo nmcli connection modify \"$uuid\" connection.dnssec \"\" 2>/dev/null && "
                 "    _cleared=$((_cleared + 1)); "
                 "  fi; "
                 "done < <(nmcli -t -f UUID connection show 2>/dev/null); "
                 "[ \"$_cleared\" -gt 0 ] && echo \"  + cleared NM DNSSEC overrides on $_cleared connection(s)\" || true"});
    }

    ui::ok("DoH + DNSSEC active");
}

}  // namespace fox_install
