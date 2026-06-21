// Tests for the iommu module's lockdown gate + self-heal strip.
//
// Two guarantees this pins, neither needing a VM or sudo:
//   1. build_iommu_args() withholds lockdown=integrity exactly when asked
//      (the nvidia/DKMS gate decision — the brick we shipped and removed).
//   2. LOCKDOWN_STRIP_SED removes a stale lockdown=integrity from a real
//      boot-entry fixture, preserves root=/rw, and is IDEMPOTENT (a second
//      pass is a no-op) — same fixed-point discipline as test_gaming. It
//      runs the REAL sed from iommu.hpp, so there's no reimplementation to
//      drift from production.
//   3. cmdline_options_sane() is the post-edit self-check that drives the
//      auto-revert: a line that lost root= or rw is rejected.

#include "../modules/iommu.hpp"
#include "../../fox-common/shell.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; ++failures; } \
    else { std::cout << "  ok: " #cond "\n"; } \
} while (0)

static std::string read_file(const fs::path& p) {
    std::ifstream f(p);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static void run_strip_sed(const fs::path& p) {
    // The REAL program from iommu.hpp, on a user-writable temp file (no sudo).
    sh::run({"sed", "-i", LOCKDOWN_STRIP_SED, p.string()});
}

int main() {
    std::cout << "test_iommu:\n";

    // ── 1. the gate decision ──────────────────────────────────────────
    EXPECT(build_iommu_args("intel", true)  == "intel_iommu=on iommu=pt lockdown=integrity");
    EXPECT(build_iommu_args("intel", false) == "intel_iommu=on iommu=pt");
    EXPECT(build_iommu_args("amd",   true)  == "amd_iommu=on iommu=pt lockdown=integrity");
    EXPECT(build_iommu_args("amd",   false) == "amd_iommu=on iommu=pt");
    // base (no-lockdown) form never contains lockdown — the prepend guard
    // greps for this, so it must not accidentally match the lockdown form.
    EXPECT(build_iommu_args("intel", false).find("lockdown") == std::string::npos);

    // ── 2. the self-heal strip, against a real boot-entry line ─────────
    const char* fixture =
        "options intel_iommu=on iommu=pt root=PARTUUID=abc-123 rw "
        "nvidia_drm.modeset=1 lockdown=integrity lsm=landlock,lockdown,yama\n";

    fs::path tmp = fs::temp_directory_path()
        / ("fox_iommu_strip_test_" + std::to_string(::getpid()) + ".conf");
    std::ofstream(tmp) << fixture;

    run_strip_sed(tmp);
    const std::string after1 = read_file(tmp);
    // The kernel-cmdline param is gone …
    EXPECT(after1.find(" lockdown=integrity") == std::string::npos);
    // … but the IOMMU knobs and the bootable tokens survive …
    EXPECT(after1.find("intel_iommu=on iommu=pt") != std::string::npos);
    EXPECT(after1.find("root=PARTUUID=abc-123") != std::string::npos);
    EXPECT(after1.find(" rw ") != std::string::npos);
    // … and `lockdown` as an lsm= list entry (no leading space) is NOT
    // touched — only the standalone " lockdown=integrity" param is.
    EXPECT(after1.find("lsm=landlock,lockdown,yama") != std::string::npos);

    // THE FIXED-POINT PROOF: a second strip changes nothing.
    run_strip_sed(tmp);
    EXPECT(read_file(tmp) == after1);

    fs::remove(tmp);

    // ── 3. the post-edit self-check (drives auto-revert) ───────────────
    EXPECT(cmdline_options_sane(
        "options intel_iommu=on iommu=pt root=PARTUUID=abc rw quiet"));
    EXPECT(!cmdline_options_sane(            // root= mangled away
        "options intel_iommu=on iommu=pt rw quiet"));
    EXPECT(!cmdline_options_sane(            // rw mangled away
        "options intel_iommu=on iommu=pt root=PARTUUID=abc quiet"));
    EXPECT(!cmdline_options_sane(""));       // line destroyed entirely

    if (failures == 0) {
        std::cout << "iommu tests: OK\n";
        return 0;
    }
    std::cerr << "iommu tests: FAILED (" << failures << " failures)\n";
    return 1;
}
