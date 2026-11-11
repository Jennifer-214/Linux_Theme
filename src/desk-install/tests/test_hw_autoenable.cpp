// Unit test for core/hw_autoenable.hpp — which modules detected hardware switches on in a default / --full run.
// Pins the 2026-10-15 audit fix: a fingerprint reader must not auto-enable greetd_fingerprint, which edits
// /etc/pam.d/greetd without the try_first_pass refusal and enrolled-finger check its siblings carry.

#include "../core/hw_autoenable.hpp"

#include <algorithm>
#include <cstdio>
#include <string>
#include <vector>

int main() {
    using namespace fox_install;
    int failed = 0;
    auto has = [](const std::vector<const char*>& v, const char* s) {
        return std::any_of(v.begin(), v.end(), [&](const char* x) { return std::string(x) == s; });
    };
    auto expect = [&](const char* what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
    };

    const auto none = auto_enabled(HwPresent{});
    expect("no hardware enables nothing", none.empty());

    const auto reader = auto_enabled(HwPresent{false, false, false, true});
    expect("a reader enables fprint", has(reader, "fprint"));
    expect("a reader enables fprint_pam (it has the PAM gates)", has(reader, "fprint_pam"));
    expect("a reader enables sudo_fingerprint (it has the PAM gates)", has(reader, "sudo_fingerprint"));
    expect("a reader does NOT enable greetd_fingerprint (no gates: lockout risk)", !has(reader, "greetd_fingerprint"));

    const auto gpus = auto_enabled(HwPresent{true, true, true, false});
    expect("each GPU enables its module", has(gpus, "nvidia") && has(gpus, "amd_gpu") && has(gpus, "intel_gpu"));
    expect("GPUs alone never touch PAM", !has(gpus, "fprint_pam") && !has(gpus, "sudo_fingerprint"));

    // Whatever can be switched on must be switched off first: every enabled slug is a gated one.
    const auto all = auto_enabled(HwPresent{true, true, true, true});
    for (const char* s : all) {
        if (!has(hw_gated_slugs(), s)) { std::fprintf(stderr, "FAIL %s is enabled but not gated\n", s); ++failed; }
    }
    expect("greetd_fingerprint is still gated off on every run", has(hw_gated_slugs(), "greetd_fingerprint"));

    if (failed) { std::fprintf(stderr, "hw_autoenable tests: %d FAILED\n", failed); return 1; }
    std::printf("hw_autoenable tests: OK\n");
    return 0;
}
