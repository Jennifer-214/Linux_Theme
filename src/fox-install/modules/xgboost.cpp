// modules/xgboost.cpp — build XGBoost from source.
//
// Mirrors install.sh's xgboost block. Idempotent: if
// /usr/local/lib/libxgboost.so already exists, we skip the 5-10 min
// build entirely. Clone path matches install.sh's $XGB_DIR=~/code/xgboost.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

}  // namespace

void run_xgboost(Context& ctx) {
    ui::section("XGBoost — build from source");

    if (fs::exists("/usr/local/lib/libxgboost.so")) {
        ui::skipped("XGBoost already installed (skipping build)");
        return;
    }

    if (!have("cmake")) {
        ui::err("cmake not found — run with --deps first, or `sudo pacman -S cmake`");
        return;
    }

    fs::path xgb_dir = ctx.home / "code/xgboost";
    if (!fs::is_directory(xgb_dir)) {
        ui::substep("cloning github.com/dmlc/xgboost → " + xgb_dir.string());
        if (sh::run({"git", "clone", "--recursive",
                     "https://github.com/dmlc/xgboost.git",
                     xgb_dir.string()}) != 0) {
            ui::err("git clone failed");
            return;
        }
    } else {
        ui::skipped("xgboost checkout already present at " + xgb_dir.string());
    }

    fs::path build_dir = xgb_dir / "build";
    fs::create_directories(build_dir);

    ui::substep("cmake configure");
    if (sh::run({"sh", "-c",
                 "cd " + build_dir.string() + " && cmake .. -DBUILD_STATIC_LIB=OFF"}) != 0) {
        ui::err("cmake configure failed");
        return;
    }

    ui::substep("make -j$(nproc) (this is the slow part)");
    if (sh::run({"sh", "-c",
                 "cd " + build_dir.string() + " && make -j$(nproc)"}) != 0) {
        ui::err("make failed — see output above");
        return;
    }

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold for `sudo make install` — `sudo -v` first");
        return;
    }
    sh::run({"sh", "-c",
             "cd " + build_dir.string() + " && sudo make install && sudo ldconfig"});
    ui::ok("XGBoost installed to /usr/local/");
}

}  // namespace fox_install
