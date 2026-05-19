// Tests for the fox-common stderr-log sink added in Phase 6 Step 12.
// Validates: set/get path round-trip, section markers land in the log,
// child-process stderr gets redirected into the file, tail_log reads
// back the last N lines.

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
    if (!(cond)) { \
        std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " #cond "\n"; \
    } \
} while (0)

static std::string read_all(const fs::path& p) {
    std::ifstream f(p);
    std::ostringstream o;
    o << f.rdbuf();
    return o.str();
}

int main() {
    std::cout << "test_subprocess_log:\n";

    fs::path tmp_log = fs::temp_directory_path()
        / ("fox_subprocess_log_test_" + std::to_string(::getpid()) + ".log");
    fs::remove(tmp_log);

    // T1: empty default — no log, tail returns nothing, log_section is no-op.
    {
        sh::set_stderr_log("");
        EXPECT(sh::stderr_log().empty());
        sh::log_section("should be a no-op");
        EXPECT(sh::tail_log(10).empty());
    }

    // T2: set_stderr_log creates parent dir and remembers the path.
    {
        fs::path nested = fs::temp_directory_path()
            / ("fox_subprocess_log_nested_" + std::to_string(::getpid()))
            / "deeper" / "install.log";
        fs::remove_all(nested.parent_path().parent_path());
        sh::set_stderr_log(nested);
        EXPECT(sh::stderr_log() == nested);
        EXPECT(fs::exists(nested.parent_path()));
        fs::remove_all(nested.parent_path().parent_path());
    }

    // T3: log_section writes a marker line, tail_log reads it back.
    {
        sh::set_stderr_log(tmp_log);
        sh::log_section("alpha");
        sh::log_section("beta");
        sh::log_section("gamma");
        auto last2 = sh::tail_log(2);
        EXPECT(last2.size() == 2);
        EXPECT(last2[0] == "=== beta ===");
        EXPECT(last2[1] == "=== gamma ===");
        auto all3 = sh::tail_log(10);
        EXPECT(all3.size() == 3);
        EXPECT(all3[0] == "=== alpha ===");
    }

    // T4: child-process stderr lands in the log. sh::run forks and the
    // redirect happens before execvp; the child writes "hello-stderr"
    // via /bin/sh -c.
    {
        fs::remove(tmp_log);
        sh::set_stderr_log(tmp_log);
        sh::log_section("subprocess");
        int rc = sh::run({"sh", "-c", "printf 'hello-stderr\\n' >&2"});
        EXPECT(rc == 0);
        std::string contents = read_all(tmp_log);
        EXPECT(contents.find("hello-stderr") != std::string::npos);
        EXPECT(contents.find("=== subprocess ===") != std::string::npos);
    }

    // T5: sh::capture also redirects child stderr but still returns
    // stdout to the caller. The child writes "out" to stdout and
    // "err-via-capture" to stderr; the log gets stderr, the out param
    // gets stdout.
    {
        fs::remove(tmp_log);
        sh::set_stderr_log(tmp_log);
        std::string out;
        bool ok = sh::capture(
            {"sh", "-c", "printf 'out'; printf 'err-via-capture\\n' >&2"}, out);
        EXPECT(ok);
        EXPECT(out == "out");
        std::string contents = read_all(tmp_log);
        EXPECT(contents.find("err-via-capture") != std::string::npos);
    }

    // T6: clearing the log path (empty) puts us back to terminal stderr.
    {
        sh::set_stderr_log("");
        EXPECT(sh::stderr_log().empty());
        EXPECT(sh::tail_log(10).empty());
    }

    fs::remove(tmp_log);

    if (failures == 0) {
        std::cout << "subprocess_log tests: OK\n";
        return 0;
    }
    std::cerr << "subprocess_log tests: FAILED (" << failures << " failures)\n";
    return 1;
}
