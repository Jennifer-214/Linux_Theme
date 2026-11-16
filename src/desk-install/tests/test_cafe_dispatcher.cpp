// The security step's café cleanup (modules/cafe_dispatcher.hpp) on a scratch dispatcher, with a stand-in sudo that runs
// its command as the test's user: the real /etc is never named. Before 2026-11-16 the dispatcher NetworkManager runs as
// root sourced ~/.config/foxml/cafe.conf and ran ~/.local/bin/fox-firewall, and an upgrade left it in place.
//   - an old dispatcher (no v2 mark) is removed, and the step says café mode is off and how to turn it back on;
//   - a v2 dispatcher is never touched, byte for byte; none at all is nothing;
//   - one root cannot read (a cold sudo) or remove is left as it is and reported, never taken for removed;
//   - the mark is the one desk-cafe writes and `desk theme check` (D14) looks for.

#include "../modules/cafe_dispatcher.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using desk_install::cafe::Old;
using desk_install::cafe::remove_old;

namespace {

int failed = 0;
void expect(const std::string& what, bool ok) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
}

std::string slurp(const fs::path& p) {
    std::ifstream f(p);
    std::stringstream b;
    b << f.rdbuf();
    return b.str();
}

void program(const fs::path& path, const std::string& body) {
    std::ofstream(path) << body;
    fs::permissions(path, fs::perms::owner_all, fs::perm_options::replace);
}

// sudo -n CMD: runs CMD as the caller; fails (a cold cache) while `cold` exists, and refuses rm while `stuck` exists.
void sudo_standin(const fs::path& bin, const fs::path& t) {
    program(bin / "sudo", "#!/bin/sh\n[ \"$1\" = -n ] && shift\n"
                          "[ -e '" + (t / "cold").string() + "' ] && exit 1\n"
                          "[ \"$1\" = rm ] && [ -e '" + (t / "stuck").string() + "' ] && exit 1\n"
                          "exec \"$@\"\n");
}

}  // namespace

int main() {
    const fs::path t = fs::path(BUILD_DIR) / ("cafe_dispatcher_" + std::to_string(::getpid()));
    fs::remove_all(t);
    const fs::path bin = t / "bin", dir = t / "dispatcher.d", dispatcher = dir / "99-foxml-cafe";
    fs::create_directories(bin);
    fs::create_directories(dir);
    sudo_standin(bin, t);
    const char* old_path = std::getenv("PATH");
    const std::string saved = old_path ? old_path : "";
    ::setenv("PATH", (bin.string() + ":/usr/bin:/bin").c_str(), 1);

    // As `desk cafe --setup` wrote it before 2026-11-16 (its head: root sources a file the user owns).
    const std::string old_text = "#!/bin/bash\n# foxml-managed — Café Mode trigger.\nINTERFACE=\"$1\"\nEVENT=\"$2\"\n"
                                 "[[ \"$EVENT\" == \"up\" ]] || exit 0\nUSER_HOME=/home/tester\n"
                                 "CONF=\"$USER_HOME/.config/foxml/cafe.conf\"\n[[ -r \"$CONF\" ]] || exit 0\n. \"$CONF\"\n";
    const std::string v2_text = "#!/bin/bash\n# foxml-managed: cafe v2 — Café Mode, written by `desk cafe --setup`.\n"
                                "PATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\nCONF=/etc/foxml/cafe.conf\n";

    expect("no dispatcher: nothing", remove_old(dispatcher) == Old::None);

    std::ofstream(dispatcher) << old_text;
    expect("the old dispatcher is removed", remove_old(dispatcher) == Old::Removed);
    expect("the old dispatcher is gone from the folder", !fs::exists(fs::symlink_status(dispatcher)));

    std::ofstream(dispatcher) << v2_text;
    fs::permissions(dispatcher, fs::perms(0755), fs::perm_options::replace);
    const auto when = fs::last_write_time(dispatcher);
    expect("a v2 dispatcher is kept", remove_old(dispatcher) == Old::Kept);
    expect("a v2 dispatcher is untouched", slurp(dispatcher) == v2_text && fs::last_write_time(dispatcher) == when &&
                                               (fs::status(dispatcher).permissions() & fs::perms::all) == fs::perms(0755));

    // A link in the dispatcher's place is judged by what it runs; removing it removes the link, never its target.
    const fs::path elsewhere = t / "old-elsewhere";
    std::ofstream(elsewhere) << old_text;
    fs::remove(dispatcher);
    fs::create_symlink(elsewhere, dispatcher);
    expect("a link to an old dispatcher is removed", remove_old(dispatcher) == Old::Removed);
    expect("the link is gone, its target kept", !fs::exists(fs::symlink_status(dispatcher)) && slurp(elsewhere) == old_text);

    std::ofstream(dispatcher) << old_text;
    std::ofstream(t / "cold") << "";
    expect("sudo cold: not read, reported", remove_old(dispatcher) == Old::Unread);
    expect("sudo cold: left as it is", slurp(dispatcher) == old_text);
    fs::remove(t / "cold");

    std::ofstream(t / "stuck") << "";
    expect("rm refused: reported as a failure, not as removed", remove_old(dispatcher) == Old::Failed);
    expect("rm refused: the old dispatcher is still there", slurp(dispatcher) == old_text);
    fs::remove(t / "stuck");

    // One mark: desk-cafe writes it into the v2 dispatcher, and theme-check's D14 looks for it.
    const fs::path repo = fs::path(BUILD_DIR).parent_path().parent_path().parent_path();
    expect("desk-cafe's MARK is the mark the cleanup keeps",
           slurp(repo / "shared/bin/desk-cafe").find(std::string("MARK='") + desk_install::cafe::V2_MARK + "'") != std::string::npos);
    expect("theme-check's D14 looks for the same mark",
           slurp(repo / "src/theme-check/main.cpp").find(std::string("\"") + desk_install::cafe::V2_MARK + "\"") != std::string::npos);

    ::setenv("PATH", saved.c_str(), 1);
    fs::remove_all(t);
    if (failed) { std::fprintf(stderr, "café dispatcher cleanup tests: %d FAILED\n", failed); return 1; }
    std::printf("café dispatcher cleanup tests: OK\n");
    return 0;
}
