#include "health.hpp"

#include "checks.hpp"

#include <exception>

namespace fox_health {

const char* severity_name(Severity s) {
    switch (s) {
        case Severity::Critical: return "critical";
        case Severity::High:     return "high";
        case Severity::Medium:   return "medium";
        case Severity::Low:      return "low";
    }
    return "?";
}

const char* status_name(Status s) {
    switch (s) {
        case Status::Pass: return "pass";
        case Status::Warn: return "warn";
        case Status::Fail: return "fail";
        case Status::Skip: return "skip";
    }
    return "?";
}

// Phase-1 registry. Per plans/health-checks.md §A and §B.
// Order is also the order results are emitted in default output.
const std::vector<CheckEntry>& all_checks() {
    static const std::vector<CheckEntry> table = {
        // ── A. Boot path (won't reach login) ──────────────────────
        { "A1", "running kernel module tree present",
          Severity::Critical, /*runtime*/ false, /*slow*/ false, &checks::a1_kernel_modules_dep },
        { "A2", "linux/linux-lts files match package",
          Severity::Critical, /*runtime*/ false, /*slow*/ true,  &checks::a2_pacman_qkk_linux },
        { "A3", "/boot vmlinuz matches kernel package version",
          Severity::Critical, /*runtime*/ false, /*slow*/ false, &checks::a3_vmlinuz_matches_kver },
        { "A4", "ESP vmlinuz matches /boot vmlinuz",
          Severity::Critical, /*runtime*/ false, /*slow*/ false, &checks::a4_esp_matches_boot },
        { "A7", "systemd-boot entry has no duplicated kernel args",
          Severity::Critical, /*runtime*/ false, /*slow*/ false, &checks::a7_arch_conf_no_dupes },

        // ── B. Auth stack (can't get past login) ──────────────────
        { "B1", "/etc/pam.d/sudo PAM-header position correct",
          Severity::Critical, /*runtime*/ false, /*slow*/ false, &checks::b1_sudo_header_first },
        { "B2", "pam_fprintd placement won't lock account",
          Severity::Critical, /*runtime*/ false, /*slow*/ false, &checks::b2_fprintd_safe_placement },
        { "B3", "faillock counter below threshold",
          Severity::High,     /*runtime*/ false, /*slow*/ false, &checks::b3_faillock_clear },
    };
    return table;
}

namespace {

bool id_matches_any_prefix(const std::string& id,
                           const std::vector<std::string>& prefixes) {
    if (prefixes.empty()) return false;
    for (auto& p : prefixes) {
        if (id.rfind(p, 0) == 0) return true;
    }
    return false;
}

CheckResult skipped(const CheckEntry& e, const char* why) {
    CheckResult r;
    r.id        = e.id;
    r.title     = e.title;
    r.severity  = e.severity;
    r.status    = Status::Skip;
    r.detail    = why;
    return r;
}

CheckResult failed_with_exception(const CheckEntry& e, const std::exception& ex) {
    CheckResult r;
    r.id        = e.id;
    r.title     = e.title;
    r.severity  = e.severity;
    r.status    = Status::Fail;
    r.detail    = std::string("check threw: ") + ex.what();
    return r;
}

}  // namespace

std::vector<CheckResult> run_all(const CheckOptions& opts) {
    std::vector<CheckResult> out;
    const auto& checks = all_checks();
    out.reserve(checks.size());

    for (const auto& e : checks) {
        std::string id = e.id;

        if (!opts.only.empty() && !id_matches_any_prefix(id, opts.only)) {
            out.push_back(skipped(e, "filtered out by --only"));
            continue;
        }
        if (id_matches_any_prefix(id, opts.exclude)) {
            out.push_back(skipped(e, "filtered out by --exclude"));
            continue;
        }
        if (e.runtime && !opts.include_runtime) {
            out.push_back(skipped(e, "runtime check disabled"));
            continue;
        }
        if (e.slow && !opts.include_slow) {
            out.push_back(skipped(e, "slow check disabled"));
            continue;
        }

        try {
            out.push_back(e.fn());
            // The check fn is allowed to omit id/title/severity; backfill.
            auto& r = out.back();
            if (r.id.empty())    r.id        = e.id;
            if (r.title.empty()) r.title     = e.title;
            // Severity is enum, so use the registered one as the source of
            // truth — checks can't override.
            r.severity = e.severity;
        } catch (const std::exception& ex) {
            out.push_back(failed_with_exception(e, ex));
        } catch (...) {
            CheckResult r;
            r.id = e.id; r.title = e.title; r.severity = e.severity;
            r.status = Status::Fail;
            r.detail = "check threw an unknown exception";
            out.push_back(r);
        }
    }
    return out;
}

int worst_exit(const std::vector<CheckResult>& results) {
    bool any_critical = false, any_high = false, any_other = false;
    for (const auto& r : results) {
        if (r.status != Status::Fail && r.status != Status::Warn) continue;
        switch (r.severity) {
            case Severity::Critical: any_critical = true; break;
            case Severity::High:     any_high     = true; break;
            case Severity::Medium:   any_other    = true; break;
            case Severity::Low:      any_other    = true; break;
        }
    }
    if (any_critical) return 2;
    if (any_high)     return 3;
    if (any_other)    return 1;
    return 0;
}

}  // namespace fox_health
