// modules/cpp_pro.cpp — C++ trading toolchain extras (opt-in).
//
// base-devel from --deps covers gcc/make. This module adds the rest of
// the development stack the FoxML_Trader / FoxLIB / per-core engine
// projects expect:
//
//   clang, lldb        alternative compiler + debugger
//   mold               5-10x faster linker than ld.bfd
//   ccache             compiler output cache
//   gdb                GNU debugger
//   valgrind           memory + cache analyser
//   perf               kernel performance counters
//   hyperfine          benchmark harness
//
// Off by default. Bash had INSTALL_CPP_PRO=false, --cpp-pro toggled
// it on. --full does NOT enable this (dev-only).

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

namespace fox_install {

void run_cpp_pro(Context& ctx) {
    ui::section("C++ toolchain extras (clang / lldb / mold / valgrind / perf)");

    if (sh::run({"sh", "-c",
                 "pacman -Qi clang lldb mold ccache gdb valgrind perf hyperfine "
                 ">/dev/null 2>&1"}) == 0
        && !ctx.force_reapply) {
        ui::skipped("C++ toolchain extras already installed");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would pacman -S clang lldb mold ccache gdb "
                    "valgrind perf hyperfine");
        return;
    }
    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    int rc = sh::pacman({"clang", "lldb", "mold", "ccache",
                         "gdb", "valgrind", "perf", "hyperfine"});
    if (rc == 0) ui::ok("C++ toolchain extras installed");
    else         ui::warn("pacman failed — packages may be partial");
}

}  // namespace fox_install
