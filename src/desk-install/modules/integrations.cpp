#include "workflow_update.hpp"
#include "../../desk-common/ui.hpp"

namespace desk_install {
void run_integrations(Context& ctx) {
    ui::section("Finalizing work integrations and their installed versions");
    if (sh::dry_run()) { ui::substep("[dry-run] would stage and verify work integrations with backups; agent sessions stay running"); return; }
    if (ctx.render_ran && !ctx.render_ok) { ui::err("Rendering failed; leaving work integrations unchanged"); ctx.deploy_failed = true; return; }
    workflow::Stage stage; std::string error;
    if (!workflow::prepare(ctx, stage, error)) { ui::err(error); ctx.deploy_failed = true; return; }
    const auto result = workflow::apply(ctx, stage, stage.plan.value("plan", ""));
    if (!result.value("ok", false)) { ui::err(result.value("message", "Integration deployment failed")); ctx.deploy_failed = true; }
    else ui::ok("Work integrations verified; loaded sessions pick up changes on their normal reload");
}
}
