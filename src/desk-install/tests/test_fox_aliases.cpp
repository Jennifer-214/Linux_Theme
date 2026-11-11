// Unit test for modules/fox_aliases.hpp: in a fake ~/.local/bin, old names become links to installed new names; an
// old copy is replaced, a link of ours is re-pointed or kept, someone else's link and a folder are left alone.
#include "../modules/fox_aliases.hpp"

#include <cstdio>
#include <fstream>
#include <unistd.h>

namespace fs = std::filesystem;
using desk_install::lay_fox_aliases;
static int failed = 0;
static void expect(bool ok, const char* what) { if (!ok) { std::printf("FAIL: %s\n", what); ++failed; } }

int main() {
    const fs::path bin = fs::temp_directory_path() / ("fox-aliases-" + std::to_string(::getpid()));
    fs::create_directories(bin);
    for (const char* n : {"desk-drawer", "ai-doctor", "desk-pulse", "word-count", "desk", "desk-vault"}) std::ofstream(bin / n) << "#!/bin/sh\n";
    std::ofstream(bin / "fox-drawer") << "old copy\n";                       // an old copy of our tool: replaced
    fs::create_symlink("desk-pulse-old", bin / "fox-pulse");                 // our link, pointing wrong: re-pointed
    fs::create_symlink("word-count", bin / "fox-word-count");                // already right: kept
    fs::create_symlink("/opt/mine/vault", bin / "fox-vault");                // someone's own link: left alone
    fs::create_directories(bin / "fox");                                     // a folder: left alone
    const auto dry = lay_fox_aliases(bin, true);
    expect(fs::is_regular_file(fs::symlink_status(bin / "fox-drawer")), "a dry run changes nothing");
    const auto n = lay_fox_aliases(bin, false);
    expect(dry.linked == n.linked, "the dry run counts what the real run does");
    expect(fs::read_symlink(bin / "fox-drawer") == "desk-drawer", "an old copy becomes a link");
    expect(fs::read_symlink(bin / "fox-ai-doctor") == "ai-doctor", "a missing old name is linked");
    expect(fs::read_symlink(bin / "fox-pulse") == "desk-pulse", "our wrong link is re-pointed");
    expect(fs::read_symlink(bin / "fox-word-count") == "word-count", "a right link is kept");
    expect(fs::read_symlink(bin / "fox-vault") == "/opt/mine/vault", "someone else's link is left alone");
    expect(fs::is_directory(bin / "fox"), "a folder is left alone");
    std::error_code ec;
    expect(!fs::exists(fs::symlink_status(bin / "fox-tripwire", ec)), "no link for a tool that is not installed");
    expect(n.kept == 1 && n.left == 2 && n.linked == 3, "counts: 3 linked, 1 kept, 2 left");
    expect(!fs::exists(bin / ".fox-drawer.alias-tmp"), "no temporary left behind");
    fs::remove_all(bin);
    std::printf("fox_aliases: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
