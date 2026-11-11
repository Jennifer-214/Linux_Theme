// arkenfox user.js composition: overrides copied in after arkenfox, the theme's lines kept, cut-off downloads refused.
#include "../modules/arkenfox_userjs.hpp"
#include <iostream>

namespace af = desk_install::arkenfox;
static int failed = 0, passed = 0;
static void check(bool ok, const char* what) {
    if (ok) ++passed; else { ++failed; std::cerr << "FAIL: " << what << "\n"; }
}

int main() {
    const std::string download =
        "/******\n*    name: arkenfox user.js\n* version: 144\n******/\n"
        "user_pref(\"browser.startup.page\", 0);\n"
        "user_pref(\"browser.newtabpage.enabled\", false);\n"
        "/* END: internal custom pref to test for syntax errors ***/\n"
        "user_pref(\"_user.js.parrot\", \"SUCCESS: No no he's not dead, he's, he's restin'!\");\n";
    const std::string overrides = "user_pref(\"browser.startup.page\", 3);\n";
    const std::string theme =
        "// FoxML theming\nuser_pref(\"toolkit.legacyUserProfileCustomizations.stylesheets\", true);\n\n"
        "// >>> FoxML find colors\nuser_pref(\"ui.textHighlightBackground\", \"#f1d6de\");\n// <<< FoxML find colors\n";

    check(af::complete(download), "a full download is complete");
    check(!af::complete(download.substr(0, download.size() / 2)), "a cut-off download is refused");
    check(!af::complete("<html>rate limited</html>"), "something that is not arkenfox is refused");

    const std::string first = af::compose(download, overrides, theme);
    check(first.rfind(download, 0) == 0, "arkenfox comes first");
    const auto ark = first.find("\"browser.startup.page\", 0"), mine = first.find("\"browser.startup.page\", 3");
    check(ark != std::string::npos && mine != std::string::npos && mine > ark, "overrides come after arkenfox, so they win");
    const auto kept = first.find(theme);
    check(kept != std::string::npos && kept > first.find(af::OVERRIDES_END), "the theme's lines survive, after the overrides");
    check(af::has_overrides(first), "the overrides block is marked");

    check(af::compose(download, overrides, first) == first, "composing again changes nothing");
    const std::string edited = af::compose(download, "user_pref(\"browser.startup.page\", 1);\n", first);
    check(edited.find("\"browser.startup.page\", 3") == std::string::npos &&
          edited.find("\"browser.startup.page\", 1") != std::string::npos, "an edited override replaces the old copy");
    check(edited.find(theme) != std::string::npos, "the theme's lines survive an edit");

    const std::string appended = first + "user_pref(\"sidebar.verticalTabs\", true);\n";
    check(af::compose(download, overrides, appended).find("sidebar.verticalTabs") != std::string::npos,
          "lines added after the block later are kept");
    const std::string before_overrides = download + "\n" + theme;
    const std::string upgraded = af::compose(download, overrides, before_overrides);
    check(upgraded.find(theme) != std::string::npos && upgraded.find(download) == 0 &&
          upgraded.find(download, 1) == std::string::npos, "an older arkenfox-only user.js keeps its tail, not two arkenfoxes");
    check(af::arkenfox_part(first) == download, "arkenfox's own part can be reused without a download");
    check(af::compose(download, "", "").find(af::OVERRIDES_END) != std::string::npos, "no overrides and no old file still compose");

    std::cout << "test_arkenfox_userjs: " << passed << " passed, " << failed << " failed\n";
    return failed ? 1 : 0;
}
