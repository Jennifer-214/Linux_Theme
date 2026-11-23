// The zram step writes its config on a machine without zram and never replaces a zram setup of the machine's own.

#include "../modules/zram_conf.hpp"

#include <iostream>
#include <string>

using namespace desk_install::zram;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; ++failures; } \
    else { std::cout << "  ok: " #cond "\n"; } \
} while (0)

int main() {
    std::cout << "test_zram:\n";
    const std::string theirs = "[zram0]\nzram-size = ram / 2\n";
    const std::string old_ours = std::string(MARKER) + ": an older body\n[zram0]\nzram-size = 4096\n";

    EXPECT(decide(false, "", false) == Action::Write);           // a new machine
    EXPECT(decide(true, CONF_BODY, true) == Action::UpToDate);   // this machine after an install
    EXPECT(decide(true, theirs, true) == Action::LeaveTheirs);   // their own config, active
    EXPECT(decide(true, theirs, false) == Action::LeaveTheirs);  // their own config, not started yet
    EXPECT(decide(false, "", true) == Action::LeaveTheirs);      // zram from another tool (zramswap, …)
    EXPECT(decide(true, old_ours, true) == Action::Write);       // ours, an older version: updated

    if (failures) { std::cerr << "zram tests: FAILED (" << failures << ")\n"; return 1; }
    std::cout << "zram tests: OK\n";
    return 0;
}
