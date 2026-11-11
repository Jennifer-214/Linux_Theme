// Tests for conflict_resolve::apply. The interactive prompt() path
// is excluded — it requires a TTY plus single-char input which we
// can't drive deterministically from a non-interactive test runner.
// prompt() gets exercised manually during the next install cycle.

#include "../core/conflict_resolve.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install::conflict;

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

static void write_all(const fs::path& p, const std::string& s) {
    fs::create_directories(p.parent_path());
    std::ofstream(p) << s;
}

int main() {
    std::cout << "test_conflict_resolve:\n";

    fs::path tmp_root = fs::temp_directory_path()
        / ("fox_conflict_resolve_test_" + std::to_string(::getpid()));
    fs::remove_all(tmp_root);
    fs::create_directories(tmp_root);

    // decision_name covers every enum value.
    EXPECT(std::string(decision_name(Decision::KeepMine)) == "keep-mine");
    EXPECT(std::string(decision_name(Decision::TakeNew)) == "take-new");
    EXPECT(std::string(decision_name(Decision::BackupThenTakeNew)) == "backup-then-take-new");

    // T1: KeepMine — deployed is untouched, source untouched, no .foxml-bak.
    {
        fs::path d = tmp_root / "t1_deployed";
        fs::path s = tmp_root / "t1_source";
        write_all(d, "deployed-orig\n");
        write_all(s, "source-new\n");
        EXPECT(apply(Decision::KeepMine, d, s));
        EXPECT(read_all(d) == "deployed-orig\n");
        EXPECT(read_all(s) == "source-new\n");
        EXPECT(!fs::exists(fs::path(d.string() + ".foxml-bak")));
    }

    // T2: TakeNew — deployed now matches source; no .foxml-bak; no .foxml-tmp.
    {
        fs::path d = tmp_root / "t2_deployed";
        fs::path s = tmp_root / "t2_source";
        write_all(d, "deployed-orig\n");
        write_all(s, "source-new\n");
        EXPECT(apply(Decision::TakeNew, d, s));
        EXPECT(read_all(d) == "source-new\n");
        EXPECT(!fs::exists(fs::path(d.string() + ".foxml-bak")));
        EXPECT(!fs::exists(fs::path(d.string() + ".foxml-tmp")));
    }

    // T3: BackupThenTakeNew — .foxml-bak holds the pre-install copy;
    // deployed now matches source; no .foxml-tmp left behind.
    {
        fs::path d = tmp_root / "t3_deployed";
        fs::path s = tmp_root / "t3_source";
        write_all(d, "deployed-orig\n");
        write_all(s, "source-new\n");
        EXPECT(apply(Decision::BackupThenTakeNew, d, s));
        EXPECT(read_all(d) == "source-new\n");
        fs::path bak(d.string() + ".foxml-bak");
        EXPECT(fs::exists(bak));
        EXPECT(read_all(bak) == "deployed-orig\n");
        EXPECT(!fs::exists(fs::path(d.string() + ".foxml-tmp")));
    }

    // T4: TakeNew with missing source — returns false, deployed unchanged.
    {
        fs::path d = tmp_root / "t4_deployed";
        write_all(d, "deployed-orig\n");
        fs::path missing = tmp_root / "t4_does_not_exist";
        fs::remove(missing);
        EXPECT(!apply(Decision::TakeNew, d, missing));
        EXPECT(read_all(d) == "deployed-orig\n");
        // No stray tmp file from the failed copy.
        EXPECT(!fs::exists(fs::path(d.string() + ".foxml-tmp")));
    }

    // T5: BackupThenTakeNew with missing source — backup still lands
    // (deliberately, so the user can recover even after a failed
    // overwrite), but the deployed file isn't broken.
    {
        fs::path d = tmp_root / "t5_deployed";
        write_all(d, "deployed-orig\n");
        fs::path missing = tmp_root / "t5_does_not_exist";
        fs::remove(missing);
        EXPECT(!apply(Decision::BackupThenTakeNew, d, missing));
        // Deployed file is untouched (copy_file to tmp failed).
        EXPECT(read_all(d) == "deployed-orig\n");
        // Backup was created before the overwrite attempt.
        fs::path bak(d.string() + ".foxml-bak");
        EXPECT(fs::exists(bak));
        EXPECT(read_all(bak) == "deployed-orig\n");
    }

    fs::remove_all(tmp_root);

    if (failures == 0) {
        std::cout << "conflict_resolve tests: OK\n";
        return 0;
    }
    std::cerr << "conflict_resolve tests: FAILED (" << failures << " failures)\n";
    return 1;
}
