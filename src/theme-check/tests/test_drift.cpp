// Unit tests for drift.hpp: what counts as the same file, your own additions, or drift.
#include "../drift.hpp"

#include <cstdio>
#include <string>

using namespace fox_theme_check;

static int failures = 0, passed = 0;
static void check(bool ok, const char* what) {
    if (ok) ++passed; else { ++failures; std::printf("FAIL: %s\n", what); }
}

int main() {
    check(compare("a\nb\n", "a\nb", Kind::Plain) == Verdict::Same, "a missing final newline is the same file");
    check(compare("a  \nb\n\n\n", "a\nb\n", Kind::Plain) == Verdict::Same, "trailing spaces and blank lines at the end don't count");
    check(compare("a\nb\n", "a\nmine\nb\n", Kind::Plain) == Verdict::Yours, "a line of your own keeps the file yours");
    check(compare("a\nb\n", "a\nc\n", Kind::Plain) == Verdict::Drift, "a changed shipped line is drift");
    check(compare("a\nb\n", "b\na\n", Kind::Plain) == Verdict::Drift, "reordered lines are drift");
    check(compare("a\nb\n", "a\n", Kind::Plain) == Verdict::Drift, "a removed shipped line is drift");

    const std::string lock =
        "# foxml:hyprlock-backgrounds-begin\nbackground {\n    monitor =\n    path = ~/a.jpg\n}\n"
        "# foxml:hyprlock-backgrounds-end\nlabel {\n    monitor =\n    text = hi\n}\n";
    const std::string pinned =
        "# foxml:hyprlock-backgrounds-begin\nbackground {\n    monitor = eDP-1\n    path = ~/.wallpapers/b.jpg\n    blur_size = 8\n}\n"
        "# foxml:hyprlock-backgrounds-end\nlabel {\n    monitor = eDP-1\n    text = hi\n}\n";
    check(compare(lock, pinned, Kind::Hyprlock) == Verdict::Same, "per-monitor backgrounds and panel pins are this machine's");
    check(compare(lock, pinned + "", Kind::Plain) == Verdict::Drift, "...but only for the lock screen");
    std::string changed = pinned;
    changed.replace(changed.find("text = hi"), 9, "text = bye");
    check(compare(lock, changed, Kind::Hyprlock) == Verdict::Drift, "a changed label is still drift");

    check(compare("workspace = 1, default:true\n", "workspace = 1, monitor:eDP-1, default:true\n", Kind::Rules) == Verdict::Same,
          "a workspace pinned to a monitor (conf)");
    check(compare("hl.workspace_rule({ workspace = \"1\", default = true })\n",
                  "hl.workspace_rule({ workspace = \"1\", monitor = \"eDP-1\", default = true })\n", Kind::Rules) == Verdict::Same,
          "a workspace pinned to a monitor (lua)");
    check(compare("workspace = 1, default:true\n", "workspace = 2, default:true\n", Kind::Rules) == Verdict::Drift,
          "a different workspace is drift");

    check(compare("exec-once = rotate_wallpaper.sh && x\n", "exec-once = rotate_wallpaper.sh --static && x\n", Kind::Autostart) == Verdict::Same,
          "the wallpaper mode flag is this machine's");
    check(compare("exec-once = rotate_wallpaper.sh\n", "exec-once = rotate_wallpaper.sh --static\n", Kind::Autostart) == Verdict::Same,
          "...at the end of the line too");

    std::printf("test_drift: %d passed%s\n", passed, failures ? "" : "");
    return failures ? 1 : 0;
}
