// The owner-only checks of the private_extras step, and the shape of the step itself.
#include "../modules/private_extras.hpp"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <string>

using namespace fox_install::private_extras;

static int failures = 0, passed = 0;
static void check(bool ok, const char* what) {
    if (ok) ++passed; else { ++failures; std::printf("FAIL: %s\n", what); }
}
static std::string slurp(const char* path) {
    std::ifstream in(path);
    std::ostringstream out;
    out << in.rdbuf();
    return out.str();
}

int main() {
    check(origin_is_owners("git@github.com:Jennifer-214/linux-theme-workspace.git\n"), "ssh origin");
    check(origin_is_owners("https://github.com/Jennifer-214/linux-theme-workspace"), "https origin");
    check(!origin_is_owners("git@github.com:someone/linux-theme-workspace.git"), "someone else's fork");
    check(!origin_is_owners("git@github.com:Jennifer-214/linux-theme-workspace-copy.git"), "a look-alike name");
    check(!origin_is_owners("/home/x/linux-theme-workspace"), "a local path");
    check(!origin_is_owners("git@evil.example:Jennifer-214/linux-theme-workspace.git"), "another host");

    const std::string fpr = OWNER_SIGNING_KEY;
    const std::string good = "[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG 1B1217DD23B57785 Caramel\n"
                             "[GNUPG:] VALIDSIG " + fpr + " 2026-10-18 1792359113 0 4 0 22 10 00 " + fpr + "\n"
                             "[GNUPG:] TRUST_ULTIMATE 0 pgp\n";
    check(signed_by_owner(good), "her key, a good signature");
    const std::string sub = "[GNUPG:] GOODSIG AAAA Caramel\n[GNUPG:] VALIDSIG 1111222233334444555566667777888899990000"
                            " 2026-10-18 1 0 4 0 22 10 00 " + fpr + "\n";
    check(signed_by_owner(sub), "signed by a subkey of her primary key");
    check(!signed_by_owner("[GNUPG:] GOODSIG AAAA Other\n[GNUPG:] VALIDSIG 1111222233334444555566667777888899990000"
                           " 2026-10-18 1 0 4 0 22 10 00 1111222233334444555566667777888899990000\n"), "someone else's key");
    check(!signed_by_owner("[GNUPG:] VALIDSIG " + fpr + " x\n"), "no GOODSIG line");
    check(!signed_by_owner(good + "[GNUPG:] EXPKEYSIG 1B12 Caramel\n"), "an expired key");
    check(!signed_by_owner("[GNUPG:] BADSIG 1B12 Caramel\n[GNUPG:] VALIDSIG " + fpr + " x\n"), "a bad signature");
    check(!signed_by_owner(""), "unsigned");

    // The step: off by default, and nothing from the private script runs before every check.
    const auto def = slurp("core/modules.def");
    check(def.find("FOX_MODULE( private_extras, run_private_extras, \"--private-extras\",") != std::string::npos
          && def.find("signed commit checked)\", false )") != std::string::npos, "registered, off by default");
    const auto step = slurp("modules/private_extras.cpp");
    const auto run = step.find("sh::run({\"bash\", script.string()})");
    for (const char* gate : {"\"gh\", \"api\", \"user\"", "origin_is_owners(out)", "\"fetch\", \"--quiet\", \"origin\"",
                             "\"--is-ancestor\", \"HEAD\", \"@{u}\"", "\"diff\", \"--quiet\", \"HEAD\"", "signed_by_owner(out)"})
        check(step.find(gate) != std::string::npos && step.find(gate) < run, "each check comes before the script runs");
    check(step.find("throw") == std::string::npos, "a failed check never stops the rest of the install");

    std::printf("test_private_extras: %d passed\n", passed);
    return failures ? 1 : 0;
}
