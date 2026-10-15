// core/hw_autoenable.hpp — which modules a default / --full run switches on for the hardware detect found.
// Pure, so tests/test_hw_autoenable pins it: a hardware module is off unless its hardware is there, and a module that
// edits PAM is only switched on by a reader when it carries the safety gates its siblings do.
#pragma once

#include <vector>

namespace fox_install {

struct HwPresent {
    bool nvidia = false, amd_gpu = false, intel_gpu = false, fprint = false;
};

// Every hardware-gated slug. A default / --full run turns each off first, then on per auto_enabled().
inline const std::vector<const char*>& hw_gated_slugs() {
    static const std::vector<const char*> slugs = {
        "nvidia", "amd_gpu", "intel_gpu", "fprint", "fprint_pam", "greetd_fingerprint", "sudo_fingerprint",
    };
    return slugs;
}

inline std::vector<const char*> auto_enabled(const HwPresent& hw) {
    std::vector<const char*> on;
    if (hw.nvidia)    on.push_back("nvidia");
    if (hw.amd_gpu)   on.push_back("amd_gpu");
    if (hw.intel_gpu) on.push_back("intel_gpu");
    if (hw.fprint) {
        // fprint installs the daemon and enrolls. fprint_pam and sudo_fingerprint splice pam_fprintd `sufficient`, and
        // each refuses a stack with try_first_pass and an unenrolled reader (the B1/B2 gates).
        on.push_back("fprint");
        on.push_back("fprint_pam");
        on.push_back("sudo_fingerprint");
        // Not greetd_fingerprint: it edits /etc/pam.d/greetd with neither gate, and overwrites its backup on every run
        // (installer audit 2026-10-15). It runs only when asked by name (--greetd-fingerprint) until it has them.
    }
    return on;
}

}  // namespace fox_install
