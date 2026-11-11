// A run with no theme named must keep the saved theme: it used to fall back to Classic and then save Classic.
#include "../core/theme_choice.hpp"

#include <cstdio>
#include <unistd.h>

namespace fs = std::filesystem;
using desk_install::choose_theme;

static int failures = 0;
static void expect(const char* what, const desk_install::ThemeChoice& got, const char* name, const char* source) {
    if (got.name == name && got.source == source) return;
    std::printf("FAIL %s: %s (%s)\n", what, got.name.c_str(), got.source.c_str());
    ++failures;
}

int main() {
    char pattern[] = "/tmp/fox-theme-choice-XXXXXX";
    if (!::mkdtemp(pattern)) return 1;
    const fs::path root(pattern), themes = root / "themes";
    for (const char* name : {"FoxML_Classic", "FoxML_Paper", "Amsterdam_Orange"}) {
        fs::create_directories(themes / name);
        std::ofstream(themes / name / "palette.sh") << "BG=000000\n";
    }
    const char* fallback = "FoxML_Classic";

    expect("first install", choose_theme("", themes, root, fallback), "FoxML_Classic", "default");

    std::ofstream(root / ".active-theme") << "FoxML_Paper\n";
    expect("saved", choose_theme("", themes, root, fallback), "FoxML_Paper", "saved theme");
    expect("named beats saved", choose_theme("Amsterdam_Orange", themes, root, fallback),
           "Amsterdam_Orange", "command line");
    expect("typo keeps saved", choose_theme("FoxML_Pape", themes, root, fallback),
           "FoxML_Paper", "'FoxML_Pape' not found, using saved theme");

    std::ofstream(root / ".active-theme") << "Deleted_Theme\n";
    expect("deleted saved theme", choose_theme("", themes, root, fallback), "FoxML_Classic", "default");

    fs::remove_all(root);
    if (failures == 0) std::printf("test_theme_choice: ok\n");
    return failures == 0 ? 0 : 1;
}
