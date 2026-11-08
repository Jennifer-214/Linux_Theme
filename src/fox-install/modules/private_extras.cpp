// modules/private_extras.cpp — the owner's private extras (see private_extras.hpp for the checks).
//
// Off by default; the owner turns it on (--private-extras, or `private_extras = on` in her preset). Whatever the
// extras are lives in her private repo, not here. Any check that fails is printed with its reason and this step
// counts as incomplete (the install goes on, its summary lists the step and the install exits 3); nothing from the
// private script runs before every check passes. Someone else who switches it on gets one red line.
#include "private_extras.hpp"

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdio>
#include <filesystem>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

void run_private_extras(Context& ctx) {
    namespace pe = private_extras;
    ui::section("Private extras");
    const fs::path workspace = ctx.home / "code" / pe::WORKSPACE_REPO;
    const fs::path script = workspace / pe::SCRIPT;
    if (sh::dry_run()) {
        ui::substep(std::string("[dry-run] would check the GitHub login is ") + pe::OWNER + ", " + workspace.string()
                    + " is that account's private repo and on GitHub, and its HEAD is signed by key "
                    + pe::OWNER_SIGNING_KEY + "; then run " + script.string());
        return;
    }
    const auto refuse = [](const std::string& why) {
        ui::err("private extras not run: " + why);
    };
    std::error_code ec;
    if (!fs::is_regular_file(script, ec)) {
        refuse(script.string() + " is not here (the github step clones " + pe::WORKSPACE_REPO + " for its owner)");
        return;
    }
    const std::string ws = workspace.string();
    std::string out;

    // 1. Whose GitHub login this is.
    if (!sh::have("gh") || !sh::capture({"gh", "api", "user", "--jq", ".login"}, out) || pe::trim(out) != pe::OWNER) {
        refuse(std::string("the GitHub login is not ") + pe::OWNER + " (these extras are its owner's own)");
        return;
    }
    // 2. The checkout is the owner's private repo, GitHub still serves it to this login, and the commit is on it.
    if (!sh::capture({"git", "-C", ws, "remote", "get-url", "origin"}, out) || !pe::origin_is_owners(out)) {
        refuse(ws + "'s origin is not github.com/" + pe::OWNER + "/" + pe::WORKSPACE_REPO);
        return;
    }
    if (sh::probe({"env", "GIT_TERMINAL_PROMPT=0", "git", "-C", ws, "fetch", "--quiet", "origin"}, out) != 0) {
        refuse(std::string("GitHub would not serve ") + pe::WORKSPACE_REPO + " to this login");
        return;
    }
    if (sh::probe({"git", "-C", ws, "merge-base", "--is-ancestor", "HEAD", "@{u}"}, out) != 0) {
        refuse("this checkout's commit is not on GitHub yet (push it first)");
        return;
    }
    if (sh::probe({"git", "-C", ws, "ls-files", "--error-unmatch", pe::SCRIPT}, out) != 0
        || sh::probe({"git", "-C", ws, "diff", "--quiet", "HEAD", "--", pe::SCRIPT}, out) != 0) {
        refuse(std::string(pe::SCRIPT) + " is not the committed one (commit or restore it)");
        return;
    }
    // 3. The commit is signed by the owner's key. gpg writes its status lines to stderr.
    if (sh::probe({"sh", "-c", "git -C \"$1\" verify-commit --raw HEAD 2>&1", "sh", ws}, out) != 0
        || !pe::signed_by_owner(out)) {
        refuse(std::string("its HEAD is not signed by key ") + pe::OWNER_SIGNING_KEY);
        return;
    }

    ui::ok(std::string("private extras: ") + pe::OWNER + "'s signed " + pe::WORKSPACE_REPO + " checked");
    std::fflush(stdout);  // the script writes straight to the terminal; keep the order
    const int rc = sh::run({"bash", script.string()});
    if (rc != 0) ui::err("private extras: " + script.string() + " failed (exit " + std::to_string(rc) + ")");
    else ui::ok("private extras installed");
}

}  // namespace fox_install
