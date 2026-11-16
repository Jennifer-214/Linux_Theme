// The lockdown gate, asked of the installer's own code on stand-in machines: lspci and dkms stand-ins (the only
// programs on PATH) print each case of tests/fixtures/lockdown_gate.cases, run_detect() sets has_nvidia from lspci as
// an install does, and dkms_has_modules() reads `dkms status`. run_iommu and run_lockdown_heal decide on
// has_nvidia || dkms_has_modules(); `desk harden enable iommu` asks mappings.sh's copy of the question, which
// tests/test_harden_lockdown.py runs on the same cases.

#include "../core/context.hpp"
#include "../modules/iommu.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace desk_install { void run_detect(Context& ctx); }
using namespace desk_install;

namespace {

std::vector<std::string> fields(const std::string& line) {
    std::vector<std::string> out;
    std::size_t from = 0, at;
    while ((at = line.find(" | ", from)) != std::string::npos) {
        out.push_back(line.substr(from, at - from));
        from = at + 3;
    }
    out.push_back(line.substr(from));
    return out;
}

// What a stand-in prints: "(nothing)" is no output, \n a new line, and output ends in a newline as lspci's does.
std::string printed(const std::string& field) {
    if (field == "(nothing)") return {};
    std::string out;
    for (std::size_t i = 0; i < field.size(); ++i) {
        if (field[i] == '\\' && i + 1 < field.size() && field[i + 1] == 'n') { out += '\n'; ++i; }
        else out += field[i];
    }
    return out + "\n";
}

// exit_status "-" means the program is not installed.
void stand_in(const fs::path& dir, const std::string& name, const std::string& exit_status, const std::string& out,
              const char* only_for_arg) {
    if (exit_status == "-") return;
    const fs::path text = dir / (name + ".out");
    std::ofstream(text) << out;
    {
        std::ofstream s(dir / name);
        s << "#!/bin/sh\n";
        if (only_for_arg) s << "[ \"$1\" = " << only_for_arg << " ] || exit 2\n";
        s << "/usr/bin/cat '" << text.string() << "'\nexit " << exit_status << "\n";
    }
    fs::permissions(dir / name, fs::perms::owner_all, fs::perm_options::add);
}

}  // namespace

int main() {
    int failed = 0, cases = 0;
    std::ifstream in(CASES);
    if (!in) { std::fprintf(stderr, "FAIL cannot read %s\n", CASES); return 1; }
    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    for (std::string line; std::getline(in, line);) {
        if (line.empty() || line[0] == '#') continue;
        const auto f = fields(line);
        if (f.size() != 6 || (f[5] != "block" && f[5] != "allow")) {
            std::fprintf(stderr, "FAIL malformed case: %s\n", line.c_str());
            ++failed;
            continue;
        }
        // In the build tree, not /tmp: the stand-ins must be executable and /tmp may be noexec.
        const fs::path dir = fs::path(BUILD_DIR) / ("lockdown_gate_" + std::to_string(::getpid()) + "_" +
                                                    std::to_string(cases++));
        fs::remove_all(dir);
        fs::create_directories(dir);
        stand_in(dir, "lspci", f[1], printed(f[2]), nullptr);
        stand_in(dir, "dkms", f[3], printed(f[4]), "status");
        ::setenv("PATH", dir.c_str(), 1);
        Context ctx;
        ctx.assume_yes = true;   // an install run with -y: detect's "install the NVIDIA driver?" is a yes
        run_detect(ctx);
        const bool blocks = ctx.has_nvidia || dkms_has_modules();
        ::setenv("PATH", saved.c_str(), 1);
        fs::remove_all(dir);
        if (blocks != (f[5] == "block")) {
            std::fprintf(stderr, "FAIL %s: the installer says %s\n", f[0].c_str(), blocks ? "block" : "allow");
            ++failed;
        }
    }
    if (cases < 8) {
        std::fprintf(stderr, "FAIL only %d cases in %s\n", cases, CASES);
        ++failed;
    }
    if (failed) {
        std::fprintf(stderr, "lockdown gate tests: FAILED (%d)\n", failed);
        return 1;
    }
    std::printf("lockdown gate tests: OK (%d cases)\n", cases);
    return 0;
}
