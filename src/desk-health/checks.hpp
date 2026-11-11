#ifndef FOX_HEALTH_CHECKS_HPP
#define FOX_HEALTH_CHECKS_HPP

// Forward declarations of every check function. Implementations are
// split across checks_a_boot.cpp + checks_b_auth.cpp by category.
// The registry in health.cpp references these symbols directly so
// `nm libfox-health.a | grep ' T '` lists every check at a glance.

#include "health.hpp"

namespace fox_health::checks {

// Category A: boot path
CheckResult a1_kernel_modules_dep();
CheckResult a2_pacman_qkk_linux();
CheckResult a3_vmlinuz_matches_kver();
CheckResult a4_esp_matches_boot();
CheckResult a7_arch_conf_no_dupes();

// A3 pure verdict (kernel-currency by module-tree ownership), exposed for unit tests.
Status a3_verdict(bool owned, bool tree_exists);

// Category B: auth stack
CheckResult b1_sudo_header_first();
CheckResult b2_fprintd_safe_placement();
CheckResult b3_faillock_clear();

}  // namespace fox_health::checks

#endif
