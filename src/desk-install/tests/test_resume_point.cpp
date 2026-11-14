// --resume across a registry change: the saved point must name the same module after
// modules.def gains or loses entries, and anything it cannot place means "start over".

#include "../core/resume_point.hpp"

#include <iostream>

using namespace desk_install;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; ++failures; } \
    else { std::cout << "  ok: " #cond "\n"; } \
} while (0)

static Module mod(const char* slug) { return Module{slug, nullptr, "", "", false, false, false, false, nullptr}; }

int main() {
    std::cout << "test_resume_point:\n";

    const Module before[] = {mod("detect"), mod("deps"), mod("render"), mod("symlinks")};
    const Module added[]  = {mod("detect"), mod("preflight"), mod("deps"), mod("render"), mod("symlinks")};
    const Module removed[] = {mod("detect"), mod("render"), mod("symlinks")};

    // Saved after "deps" succeeded; the next build put a module before it.
    const std::string saved = resume::record(before, 1) + "\n";
    EXPECT(resume::start_after(saved, before, 4) == std::optional<std::size_t>(2));
    EXPECT(resume::start_after(saved, added, 5) == std::optional<std::size_t>(3));

    // The saved module is gone from the registry: no guess.
    EXPECT(!resume::start_after(saved, removed, 3).has_value());

    // A file from an older build holds an index, which says nothing about this registry.
    EXPECT(!resume::start_after("1\n", before, 4).has_value());
    EXPECT(!resume::start_after("", before, 4).has_value());

    std::cout << (failures ? "FAILED\n" : "all passed\n");
    return failures ? 1 : 0;
}
