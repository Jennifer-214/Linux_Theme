// tests/test_soloist.cpp — the soloist module: where the key lives, that its folder and key end up private, and
// that the unit names the device after the computer and never carries the key.

#include "../modules/soloist_files.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
namespace so = desk_install::soloist;

int main() {
    int failures = 0;
    auto expect = [&](bool ok, const std::string& why) {
        if (!ok) { std::cerr << "FAIL: " << why << '\n'; ++failures; }
    };

    expect(so::data_dir("/h", nullptr) == "/h/.local/share/soloist", "default data folder");
    expect(so::data_dir("/h", "") == "/h/.local/share/soloist", "an empty XDG_DATA_HOME is ignored");
    expect(so::data_dir("/h", "/x") == "/x/soloist", "XDG_DATA_HOME is followed, as Soloist does");

    std::string pattern = (fs::temp_directory_path() / "fox-soloist-XXXXXX").string();
    const char* temp = ::mkdtemp(pattern.data());
    if (!temp) return 1;
    const fs::path data = fs::path(temp) / "soloist";
    fs::create_directories(data / "credentials");
    expect(!so::key_saved(data), "no key file: no key");
    std::ofstream(so::key_file(data)).close();
    expect(!so::key_saved(data), "an empty key file is no key");
    std::ofstream(so::key_file(data)) << "secret";
    expect(so::key_saved(data), "a key file with text is a key");

    // As Soloist leaves them.
    const auto open_dir = fs::perms::owner_all | fs::perms::group_read | fs::perms::group_exec |
                          fs::perms::others_read | fs::perms::others_exec;
    const auto open_file = fs::perms::owner_read | fs::perms::owner_write | fs::perms::group_read | fs::perms::others_read;
    fs::permissions(data, open_dir);
    fs::permissions(data / "credentials", open_dir);
    fs::permissions(so::key_file(data), open_file);
    expect(so::make_private(data), "make_private succeeds");
    auto mode = [](const fs::path& p) { return fs::status(p).permissions() & fs::perms::mask; };
    expect(mode(data) == fs::perms::owner_all, "data folder is 700");
    expect(mode(data / "credentials") == fs::perms::owner_all, "credentials folder is 700");
    expect(mode(so::key_file(data)) == (fs::perms::owner_read | fs::perms::owner_write), "key is 600");
    expect(so::make_private(fs::path(temp) / "missing"), "a folder not made yet is not a failure");
    fs::remove_all(temp);

    const fs::path unit = fs::path("../../shared/soloist") / so::UNIT;  // run from src/desk-install, as make test does
    std::ifstream in(unit);
    expect(bool(in), "unit file exists: " + unit.string());
    std::ostringstream text;
    text << in.rdbuf();
    const std::string body = text.str();
    auto has = [&](const std::string& needle) { return body.find(needle) != std::string::npos; };
    expect(has(std::string("ExecStart=") + so::BIN + " --device-name %H "), "the device is named after the hostname");
    expect(has(std::string("ConditionPathExists=") + so::BIN), "the unit does nothing without Soloist");
    expect(has("\nUMask=0077\n"), "files Soloist writes from the service are private");
    expect(has("\nWantedBy=default.target\n"), "the unit starts at login");
    expect(!has("--api-key") && !has("-k "), "the key is never on the command line");

    if (failures) std::cerr << failures << " failure(s)\n";
    else std::cout << "test_soloist: ok\n";
    return failures ? 1 : 0;
}
