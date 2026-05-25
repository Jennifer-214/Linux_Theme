#ifndef FOX_HEALTH_HPP
#define FOX_HEALTH_HPP

// foxml-health — the check library driving `fox sec health`, the
// fox-install preflight integration, the per-transaction pacman
// hook, and the per-boot systemd service. One source of truth for
// every check; four entry points pick subsets via CheckOptions.

#include <string>
#include <vector>

namespace fox_health {

enum class Severity { Critical, High, Medium, Low };
enum class Status   { Pass, Warn, Fail, Skip };

const char* severity_name(Severity s);
const char* status_name(Status s);

struct CheckResult {
    std::string id;          // "A1", "B3", …
    std::string title;       // one-liner, drawn in any output mode
    Severity    severity;
    Status      status;
    std::string detail;      // multi-line ok; only shown in verbose
    std::string fix_hint;    // single command or short instruction
};

struct CheckOptions {
    bool include_runtime = true;             // C-category: needs live session
    bool include_slow    = true;             // pacman -Qkk, arch-audit
    std::vector<std::string> only;           // ID prefixes; empty = all
    std::vector<std::string> exclude;        // ID prefixes
};

using CheckFn = CheckResult(*)();

struct CheckEntry {
    const char* id;
    const char* title;
    Severity    severity;
    bool        runtime;
    bool        slow;
    CheckFn     fn;
};

// Returns the registered table. Hand-maintained inside health.cpp so
// initialization order is deterministic and one grep finds every
// active check.
const std::vector<CheckEntry>& all_checks();

// Execute the filtered subset and collect results. Each check that
// throws is captured as a Fail with the exception message — never
// propagates out, because callers (pacman hook, preflight) must not
// be derailed by a single misbehaving probe.
std::vector<CheckResult> run_all(const CheckOptions& opts = {});

// Exit code policy. Callers map this to their behaviour:
//   0  = all Pass / Skip — green
//   1  = ≥1 Warn or ≥1 Medium/Low Fail — print but don't block
//   2  = ≥1 Critical Fail — fox-install bails, pacman hook prints red
//   3  = ≥1 High Fail
int worst_exit(const std::vector<CheckResult>& results);

}  // namespace fox_health

#endif
