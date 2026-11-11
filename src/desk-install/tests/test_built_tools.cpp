// Unit test for core/built_tools.hpp — the names the src/<tool> Makefiles build, which specials' shared/bin bulk copy
// never overwrites with a script. Fixture: a fake src/ with each BIN spelling, a library with no BIN, a stray file.

#include "../core/built_tools.hpp"

#include <cstdio>
#include <fstream>
#include <set>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

int main() {
    using namespace fox_install;
    const fs::path src = fs::path(BUILD_DIR) / ("built_tools_fixture_" + std::to_string(::getpid()));
    fs::remove_all(src);
    auto mk = [&](const char* dir, const char* body) {
        fs::create_directories(src / dir);
        std::ofstream(src / dir / "Makefile") << body;
    };
    mk("fox",        "CXX ?= g++\nBIN := fox\n");
    mk("desk-vault",  "BIN = desk-vault\n");
    mk("desk-render", "  BIN=desk-render-fast   # the engine\n");
    mk("desk-common", "LIB := libfox-common.a\nBINARY_DIR = x\n");
    mk("desk-dev",    "# BIN := commented-out\nBIN:=desk-dev\nBIN := second-ignored\n");
    std::ofstream(src / "README") << "not a tool\n";

    const std::set<std::string> want = {"fox", "desk-vault", "desk-render-fast", "desk-dev"};
    const auto got = built_tool_names(src);
    int failed = 0;
    if (got != want) {
        std::fprintf(stderr, "FAIL built_tool_names: got");
        for (const auto& n : got) std::fprintf(stderr, " %s", n.c_str());
        std::fprintf(stderr, "\n");
        ++failed;
    }
    if (!built_tool_names(src / "missing").empty()) { std::fprintf(stderr, "FAIL a missing src/ isn't empty\n"); ++failed; }
    fs::remove_all(src);

    if (failed) { std::fprintf(stderr, "built_tools tests: %d FAILED\n", failed); return 1; }
    std::printf("built_tools tests: OK\n");
    return 0;
}
