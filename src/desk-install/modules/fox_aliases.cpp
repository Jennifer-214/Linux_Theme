// modules/fox_aliases.cpp — keeps the old fox-* command names working after the 2026-11 rename (fox_aliases.hpp).
#include "../core/context.hpp"
#include "../../desk-common/shell.hpp"
#include "../../desk-common/ui.hpp"
#include "fox_aliases.hpp"

namespace desk_install {

void run_fox_aliases(Context& ctx) {
    ui::section("Old fox-* names as links to their new names");
    const auto bin = ctx.home / ".local/bin";
    const auto n = lay_fox_aliases(bin, sh::dry_run());
    if (sh::dry_run()) { ui::substep("[dry-run] would link " + std::to_string(n.linked) + " old names"); return; }
    ui::ok(std::to_string(n.linked) + " linked, " + std::to_string(n.kept) + " already in place" +
           (n.left ? ", " + std::to_string(n.left) + " left alone (not ours)" : ""));
}

}  // namespace desk_install
