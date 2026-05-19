// Tests for state_manifest read/write round-trip + atomicity.
// Standalone — no Google Test, just asserts and a simple main.

#include "../core/state_manifest.hpp"

#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace fox_install::state;

static int failures = 0;
#define EXPECT(cond) do { \
    if (!(cond)) { \
        std::cerr << "  FAIL: " #cond " at line " << __LINE__ << "\n"; \
        ++failures; \
    } else { \
        std::cout << "  ok: " #cond "\n"; \
    } \
} while (0)

static fs::path make_tmp_path() {
    fs::path p = fs::temp_directory_path() / ("fox_install_test_" + std::to_string(::getpid()) + ".json");
    fs::remove(p);  // start clean
    return p;
}

int main() {
    std::cout << "test_state_manifest:\n";

    // T1: reading a non-existent file returns an empty Manifest, not an error.
    {
        fs::path p = make_tmp_path();
        Manifest m = read(p);
        EXPECT(m.schema_version == 1);
        EXPECT(m.fox_version.empty());
        EXPECT(m.modules.empty());
    }

    // T2: write + read round-trip preserves content.
    {
        fs::path p = make_tmp_path();
        Manifest m;
        m.schema_version = 1;
        m.fox_version = "5.10.0-test";
        m.modules["render"]   = {"5.10.0-test", "abc123", "2026-05-19T01:23:45Z"};
        m.modules["waybar"]   = {"5.10.0-test", "def456", "2026-05-19T01:23:46Z"};
        m.modules["hyprland"] = {"5.10.0-test", "789xyz", "2026-05-19T01:23:47Z"};

        write(p, m);
        EXPECT(fs::exists(p));

        Manifest m2 = read(p);
        EXPECT(m2.schema_version == 1);
        EXPECT(m2.fox_version == "5.10.0-test");
        EXPECT(m2.modules.size() == 3);
        EXPECT(m2.modules.at("render").version == "5.10.0-test");
        EXPECT(m2.modules.at("render").source_hash == "abc123");
        EXPECT(m2.modules.at("render").deployed_at == "2026-05-19T01:23:45Z");
        EXPECT(m2.modules.at("waybar").source_hash == "def456");
        EXPECT(m2.modules.at("hyprland").source_hash == "789xyz");

        fs::remove(p);
    }

    // T3: write creates parent dirs as needed.
    {
        fs::path base = fs::temp_directory_path() / ("fox_install_test_nested_" + std::to_string(::getpid()));
        fs::remove_all(base);
        fs::path p = base / "deeply" / "nested" / "state.json";

        Manifest m;
        m.fox_version = "test";
        write(p, m);
        EXPECT(fs::exists(p));

        fs::remove_all(base);
    }

    // T4: write is atomic — no .tmp file left behind after success.
    {
        fs::path p = make_tmp_path();
        Manifest m;
        m.fox_version = "atomic-test";
        write(p, m);

        fs::path tmp = p.string() + ".tmp";
        EXPECT(!fs::exists(tmp));
        EXPECT(fs::exists(p));

        fs::remove(p);
    }

    // T5: now_iso8601 returns a 20-char ISO timestamp ending in Z.
    {
        std::string ts = now_iso8601();
        EXPECT(ts.size() == 20);
        EXPECT(ts.back() == 'Z');
        EXPECT(ts[4] == '-' && ts[7] == '-' && ts[10] == 'T' && ts[13] == ':' && ts[16] == ':');
    }

    // T6: default_path returns something under $HOME/.config/foxml/ (or XDG).
    {
        fs::path p = default_path();
        EXPECT(p.filename() == "install-state.json");
        EXPECT(p.parent_path().filename() == "foxml");
    }

    if (failures == 0) {
        std::cout << "state_manifest tests: OK\n";
        return 0;
    }
    std::cerr << "state_manifest tests: FAILED (" << failures << " failures)\n";
    return 1;
}
