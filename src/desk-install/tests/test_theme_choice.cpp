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
    for (const char* name : {"Classic", "Paper", "Amsterdam_Orange"}) {
        fs::create_directories(themes / name);
        std::ofstream(themes / name / "palette.sh") << "BG=000000\n";
    }
    const char* fallback = "Classic";

    expect("first install", choose_theme("", themes, root, fallback), "Classic", "default");

    std::ofstream(root / ".active-theme") << "Paper\n";
    expect("saved", choose_theme("", themes, root, fallback), "Paper", "saved theme");
    expect("named beats saved", choose_theme("Amsterdam_Orange", themes, root, fallback),
           "Amsterdam_Orange", "command line");
    expect("typo keeps saved", choose_theme("Pape", themes, root, fallback),
           "Paper", "'Pape' not found, using saved theme");

    // An install from before the rename: the saved name and a typed name still carry the old prefix.
    std::ofstream(root / ".active-theme") << "FoxML_Paper\n";                                        // old-theme-name
    expect("old saved name", choose_theme("", themes, root, fallback), "Paper", "saved theme");
    expect("old typed name", choose_theme("FoxML_Classic", themes, root, fallback), "Classic", "command line");  // old-theme-name
    expect("old typo keeps saved", choose_theme("FoxML_Pape", themes, root, fallback),                // old-theme-name
           "Paper", "'FoxML_Pape' not found, using saved theme");                                    // old-theme-name
    expect("a prefix alone is not a theme", choose_theme("FoxML_", themes, root, fallback), "Paper", // old-theme-name
           "'FoxML_' not found, using saved theme");                                                 // old-theme-name

    std::ofstream(root / ".active-theme") << "Deleted_Theme\n";
    expect("deleted saved theme", choose_theme("", themes, root, fallback), "Classic", "default");

    fs::remove_all(root);
    if (failures == 0) std::printf("test_theme_choice: ok\n");
    return failures == 0 ? 0 : 1;
}
