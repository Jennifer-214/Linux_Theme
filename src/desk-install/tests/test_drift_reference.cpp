// detect_drift compares ~/.config with the last render, which lives in ~/.local/state/foxml/rendered (2026-11-15).
// Before that it lived in <checkout>/rendered: a stale copy there made every file look hand-edited after installing
// from another checkout. The old copy is read only while the new one does not exist yet.

#include "../modules/render_drift.hpp"
#include "../core/context.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;
using namespace desk_install;

int main() {
    int failed = 0;
    auto expect = [&](const std::string& what, bool ok) {
        if (!ok) { std::fprintf(stderr, "FAIL %s\n", what.c_str()); ++failed; }
        else std::printf("  ok: %s\n", what.c_str());
    };
    const fs::path root = fs::temp_directory_path() / ("drift_reference_test_" + std::to_string(::getpid()));
    fs::remove_all(root);
    Context ctx;
    ctx.home = root / "home";
    ctx.script_dir = root / "checkout";
    ctx.rendered_dir = root / "state" / "rendered";
    const fs::path live = ctx.home / ".config/kitty/kitty.conf";
    fs::create_directories(live.parent_path());
    std::ofstream(live) << "deployed\n";
    auto put = [](const fs::path& p, const char* text) { fs::create_directories(p.parent_path()); std::ofstream(p) << text; };

    expect("no render anywhere: a first install sees no drift", detect_drift(ctx).empty());

    put(ctx.script_dir / "rendered/kitty/kitty.conf", "older render\n");
    auto d = detect_drift(ctx);
    expect("no state copy yet: the checkout's old render is the reference", d.size() == 1 && d[0] == live);

    put(ctx.rendered_dir / "kitty/kitty.conf", "deployed\n");
    expect("state copy present: it wins over a stale checkout copy", detect_drift(ctx).empty());

    put(ctx.rendered_dir / "kitty/kitty.conf", "rendered, then hand-edited live\n");
    d = detect_drift(ctx);
    expect("state copy differs from ~/.config: that is drift", d.size() == 1 && d[0] == live);

    // Another step deployed the current templates' render (the integrations update writes the notebook theme itself):
    // ~/.config differs from the last render but matches what the templates give now, so it is not an edit.
    const fs::path fresh = root / "fresh";
    put(fresh / "kitty/kitty.conf", "deployed\n");
    expect("matches the current templates: not drift", detect_drift(ctx, fresh).empty());
    put(fresh / "kitty/kitty.conf", "the templates now say something else\n");
    d = detect_drift(ctx, fresh);
    expect("differs from both renders: drift", d.size() == 1 && d[0] == live);
    ctx.palette_path = root / "no-palette.sh";
    d = detect_drift(ctx);
    expect("no palette to render with: the last render alone decides", d.size() == 1 && d[0] == live);

    fs::remove_all(root);
    if (failed) { std::fprintf(stderr, "drift_reference tests: %d FAILED\n", failed); return 1; }
    std::printf("drift_reference tests: OK\n");
    return 0;
}
