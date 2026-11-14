// noexec_tmp's fstab edit: /tmp found by its mount point; a tmpfs gains only what it lacks; a partition of its own is
// left alone (a second /tmp line used to be appended); an fstab without a final newline does not glue lines; only
// errors the candidate adds count.
#include "../modules/fstab_tmp.hpp"

#include <cstdio>

using namespace desk_install::fstab_tmp;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}

int main() {
    const std::string root = "UUID=abc / ext4 rw,relatime 0 1\n";
    expect(tmp_kind(root) == TmpKind::None, "no /tmp entry");
    const auto added = with_tmp_locked(root);
    expect(added && *added == root + kTmpLine + "\n", "a tmpfs line on a line of its own");
    expect(added && locked_down(*added) && !with_tmp_locked(*added), "then nothing more to do");
    const auto glued = with_tmp_locked("UUID=abc / ext4 rw 0 1");
    expect(glued && glued->find("0 1\n" + std::string(kTmpLine)) != std::string::npos, "no final newline: no glued line");

    const std::string tmpfs = root + "tmpfs  /tmp  tmpfs  defaults,size=2G  0 0\n";
    const auto amended = with_tmp_locked(tmpfs);
    expect(amended && *amended == root + "tmpfs  /tmp  tmpfs  defaults,size=2G,noexec,nosuid,nodev  0 0\n",
           "a tmpfs gains the options it lacks; spacing and the rest stay");
    expect(!with_tmp_locked(root + "tmpfs /tmp tmpfs nodev,noexec,nosuid 0 0\n"), "already locked down");
    expect(!locked_down(root + "tmpfs /tmp tmpfs defaults,noexecx,nosuid,nodev 0 0\n"), "options are whole words");
    expect(!locked_down("# tmpfs /tmp tmpfs noexec,nosuid,nodev 0 0\n"), "a comment is not an entry");

    const std::string partition = root + "UUID=def /tmp ext4 defaults 0 2\n";
    expect(tmp_kind(partition) == TmpKind::Partition && !with_tmp_locked(partition), "a partition of its own is left alone");

    const std::string before = "/mnt/old\n   [E] unreachable on boot required target: No such file or directory\n"
                               "   [W] unreachable source: /dev/x: No such file or directory\n\n0 parse errors, 1 error, 1 warning\n";
    const std::string after = before + "/tmp\n   [E] unreachable on boot required target: No such file or directory\n";
    const auto old_errors = verify_errors(before), new_errors = verify_errors(after);
    expect(old_errors.size() == 1, "warnings are not errors");
    std::size_t added_errors = 0;
    for (const auto& e : new_errors) added_errors += old_errors.count(e) == 0;
    expect(added_errors == 1, "the same message under another mount point is a new error");

    if (failures == 0) std::printf("test_fstab_tmp: ok\n");
    return failures == 0 ? 0 : 1;
}
