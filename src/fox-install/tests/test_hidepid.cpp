// Unit test for modules/hidepid_check.hpp — when run_hidepid must leave /proc's hidepid alone (installer audit
// 2026-10-15): it's live in either spelling, or foxml's newer unit (gid=proc) is in place.

#include "../modules/hidepid_check.hpp"

#include <cstdio>
#include <string>

int main() {
    using namespace fox_install;
    int failed = 0;
    auto eq = [&](const char* what, const std::string& got, const std::string& want) {
        if (got != want) { std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", what, got.c_str(), want.c_str()); ++failed; }
    };
    auto expect = [&](const char* what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++failed; }
    };

    // Her live unit (the bash installer's newer form) vs run_hidepid's UNIT_BODY.
    const std::string newer =
        "# foxml-managed — apply hidepid=2 to /proc on boot.\n[Unit]\nDescription=Remount /proc with hidepid=2 (foxml)\n"
        "[Service]\nType=oneshot\nExecStart=/bin/mount -o remount,hidepid=2,gid=proc /proc\nRemainAfterExit=yes\n";
    const std::string native =
        "# foxml-managed — apply hidepid=2 to /proc on boot.\n[Service]\nExecStart=/bin/mount -o remount,hidepid=2 /proc\n";
    expect("the gid=proc unit is newer", is_newer_foxml_hidepid_unit(newer));
    expect("UNIT_BODY's form isn't", !is_newer_foxml_hidepid_unit(native));
    expect("someone else's unit isn't foxml's",
           !is_newer_foxml_hidepid_unit("[Service]\nExecStart=/bin/mount -o remount,hidepid=2,gid=proc /proc\n"));
    expect("no unit", !is_newer_foxml_hidepid_unit(""));
    expect("gid= only in a comment doesn't count",
           !is_newer_foxml_hidepid_unit("# foxml-managed gid=proc\nExecStart=/bin/mount -o remount,hidepid=2 /proc\n"));

    const std::string root = "/dev/nvme0n1p2 / ext4 rw,relatime 0 0\n";
    // Her machine, kernel 7.2: the name form, with gid=26 (proc).
    eq("5.8+ name form", live_hidepid(root + "proc /proc proc rw,nosuid,nodev,noexec,relatime,gid=26,hidepid=invisible 0 0\n"), "invisible");
    eq("pre-5.8 number form", live_hidepid("proc /proc proc rw,nosuid,nodev,noexec,relatime,hidepid=2 0 0\n"), "2");
    eq("ptraceable is stricter", live_hidepid("proc /proc proc rw,hidepid=ptraceable 0 0\n"), "ptraceable");
    eq("4 is ptraceable", live_hidepid("proc /proc proc rw,hidepid=4 0 0\n"), "4");
    eq("noaccess (1) doesn't hide the pids", live_hidepid("proc /proc proc rw,hidepid=noaccess 0 0\n"), "");
    eq("no hidepid", live_hidepid(root + "proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0\n"), "");
    eq("another mount point doesn't count", live_hidepid("proc /run/x/proc proc rw,hidepid=2 0 0\n"), "");
    eq("the top /proc mount wins", live_hidepid("proc /proc proc rw,hidepid=2 0 0\nproc /proc proc rw 0 0\n"), "");
    eq("empty", live_hidepid(""), "");

    if (failed) { std::fprintf(stderr, "hidepid tests: %d FAILED\n", failed); return 1; }
    std::printf("hidepid tests: OK\n");
    return 0;
}
