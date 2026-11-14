// The PAM edit: the fingerprint line lands after the header (leading blanks too, which the old sed missed), never
// twice, never without a header for sudo; the install script replaces a file in one step, keeps the first backup,
// leaves nothing behind, and changes nothing when it fails. The script runs here as the user, on files in a temp dir.
#include "../modules/pam_file.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace desk_install::pam_file;

static int failures = 0;
static void expect(bool ok, const char* what) {
    if (ok) return;
    std::printf("FAIL %s\n", what);
    ++failures;
}
static std::string read(const fs::path& p) {
    std::ifstream in(p);
    return {std::istreambuf_iterator<char>(in), {}};
}
static void write(const fs::path& p, const std::string& text) { std::ofstream(p) << text; }
static int run_script(const fs::path& file, const fs::path& next) {
    const pid_t pid = ::fork();
    if (pid == 0) {
        ::execlp("sh", "sh", "-c", kInstallScript, "sh", file.c_str(), next.c_str(), static_cast<char*>(nullptr));
        ::_exit(127);
    }
    int status = 0;
    ::waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main() {
    const std::string stock = "#%PAM-1.0\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\n";
    const auto sudo = with_fprintd(stock, false);
    expect(sudo && *sudo == "#%PAM-1.0\n" + std::string(kFprintdLine) + "\nauth\t\tinclude\t\tsystem-auth\naccount\t\tinclude\t\tsystem-auth\n",
           "the line goes right after the header and nothing else moves");
    const auto indented = with_fprintd("  #%PAM-1.0\nauth include system-auth\n", false);
    expect(indented && indented->find("  #%PAM-1.0\n" + std::string(kFprintdLine) + "\n") == 0,
           "a header after blanks is found (the sed's ^ anchor missed it and did nothing)");
    expect(!with_fprintd(*sudo, false), "never a second fingerprint line");
    expect(!with_fprintd("#%PAM-1.0\nauth [success=1 default=ignore] pam_fprintd.so\n", false), "a bracketed control counts as wired");
    expect(!with_fprintd("auth include login\n", false), "sudo: no header, no edit");
    const auto greetd = with_fprintd("auth include login\n", true);
    expect(greetd && *greetd == std::string(kFprintdLine) + "\nauth include login\n", "greetd: no header, first line");
    expect(try_first_pass_in("auth       [success=1 default=bad]     pam_unix.so          try_first_pass nullok\n"),
           "try_first_pass is seen behind a bracketed control");
    expect(!try_first_pass_in("auth       required                    pam_unix.so          nullok\n"), "and not invented");

    char pattern[] = "/tmp/pam-file-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path dir(pattern), file = dir / "sudo", next = dir / "next";
    write(file, stock);
    write(next, *sudo);
    expect(run_script(file, next) == 0, "the script succeeds");
    expect(read(file) == *sudo, "the file holds the new text");
    expect(read(dir / "sudo.foxml-bak") == stock, "the backup holds the original");
    expect(!fs::exists(dir / "sudo.foxml-new") && !fs::exists(dir / "sudo.foxml-prev"), "nothing is left beside it");
    write(next, *sudo + "# later\n");
    expect(run_script(file, next) == 0 && read(dir / "sudo.foxml-bak") == stock, "a second run keeps the first backup");
    const auto before = read(file);
    expect(run_script(file, dir / "missing") != 0, "a missing new text fails");
    expect(read(file) == before && !fs::exists(dir / "sudo.foxml-new") && !fs::exists(dir / "sudo.foxml-prev"),
           "a failed run changes nothing and leaves nothing");
    fs::remove_all(dir);

    if (failures == 0) std::printf("test_pam_file: ok\n");
    return failures == 0 ? 0 : 1;
}
