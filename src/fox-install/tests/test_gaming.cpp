// Tests for the gaming module's [multilib] enablement — specifically that it
// is IDEMPOTENT: re-running the uncomment is a no-op. This is the fixed-point
// proof that guards against the iommu boot-corruption class (a blind append
// would stack a duplicate line every run). Runs the REAL MULTILIB_UNCOMMENT_SED
// against a temp pacman.conf fixture (no sudo, no /etc) so there is no
// reimplementation to drift from the production code.

#include "../modules/gaming.hpp"
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

static void run_uncomment_sed(const fs::path& p) {
    // The REAL program from gaming.hpp, on a user-writable temp file (no sudo).
    sh::run({"sed", "-i", MULTILIB_UNCOMMENT_SED, p.string()});
}

int main() {
    std::cout << "test_gaming:\n";

    const char* fixture =
        "[options]\n"
        "HoldPkg = pacman glibc\n"
        "\n"
        "#[multilib]\n"
        "#Include = /etc/pacman.d/mirrorlist\n";

    fs::path tmp = fs::temp_directory_path()
        / ("fox_gaming_multilib_test_" + std::to_string(::getpid()) + ".conf");
    std::ofstream(tmp) << fixture;

    // Guard reports "not enabled" on the commented fixture.
    EXPECT(!multilib_already_enabled(tmp.string()));

    // First uncomment: [multilib] + its Include become active.
    run_uncomment_sed(tmp);
    const std::string after1 = read_file(tmp);
    EXPECT(after1.find("\n[multilib]\n") != std::string::npos);
    EXPECT(after1.find("\nInclude = /etc/pacman.d/mirrorlist\n") != std::string::npos);
    EXPECT(after1.find("#[multilib]") == std::string::npos);
    // The guard now agrees the writer's output is "enabled" — guard spelling
    // matches written content (the anti-pattern's core requirement).
    EXPECT(multilib_already_enabled(tmp.string()));

    // THE FIXED-POINT PROOF: a second uncomment changes nothing (arm→arm
    // no-op). If MULTILIB_UNCOMMENT_SED were ever made trigger-preserving
    // (e.g. a blind append), this assertion goes red.
    run_uncomment_sed(tmp);
    const std::string after2 = read_file(tmp);
    EXPECT(after2 == after1);

    EXPECT(multilib_already_enabled(tmp.string()));

    fs::remove(tmp);

    if (failures == 0) {
        std::cout << "gaming tests: OK\n";
        return 0;
    }
    std::cerr << "gaming tests: FAILED (" << failures << " failures)\n";
    return 1;
}
