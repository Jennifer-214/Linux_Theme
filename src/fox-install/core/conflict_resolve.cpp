#include "conflict_resolve.hpp"

#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdio>
#include <system_error>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install::conflict {

const char* decision_name(Decision d) {
    switch (d) {
        case Decision::KeepMine:           return "keep-mine";
        case Decision::TakeNew:            return "take-new";
        case Decision::BackupThenTakeNew:  return "backup-then-take-new";
    }
    return "unknown";
}

namespace {

void show_diff(const fs::path& deployed, const fs::path& source) {
    // diff exits 1 when files differ — that's success here, not failure.
    // Routed through sh::run so dry-run logging stays centralized; no
    // shell invocation means the paths can't shell-inject.
    std::vector<std::string> argv = {
        "diff", "-u",
        "--label", deployed.string() + " (deployed)",
        "--label", source.string()   + " (source)",
        deployed.string(),
        source.string(),
    };
    sh::run(argv);
}

}  // namespace

Decision prompt(
    const std::string& slug,
    const fs::path& deployed,
    const fs::path& source,
    bool assume_yes
) {
    if (assume_yes || !ui::tty()) return Decision::KeepMine;

    ui::section("Conflict: " + slug);
    ui::substep("deployed: " + deployed.string());
    ui::substep("source:   " + source.string());
    std::printf("\n  Both copies diverged from the manifest's recorded hash.\n"
                "  Choose how to resolve:\n\n"
                "    1) keep my version (don't touch the deployed file)\n"
                "    2) take new version (overwrite deployed)\n"
                "    3) save deployed as %s.foxml-bak, then take new\n"
                "    d) view diff (then re-prompt)\n\n",
                deployed.filename().string().c_str());

    while (true) {
        char c = ui::ask_choice("choice [1/2/3/d]: ", "123d", '1', /*assume_yes=*/false);
        switch (c) {
            case '1': return Decision::KeepMine;
            case '2': return Decision::TakeNew;
            case '3': return Decision::BackupThenTakeNew;
            case 'd':
            default:
                show_diff(deployed, source);
                std::printf("\n");
                break;
        }
    }
}

bool apply(
    Decision d,
    const fs::path& deployed,
    const fs::path& source
) {
    std::error_code ec;
    switch (d) {
        case Decision::KeepMine:
            return true;

        case Decision::BackupThenTakeNew: {
            // The backup MUST land before the overwrite — if the
            // overwrite fails, the .foxml-bak still gives the user
            // their pre-install copy back.
            const fs::path bak = deployed.string() + ".foxml-bak";
            fs::copy_file(deployed, bak,
                          fs::copy_options::overwrite_existing, ec);
            if (ec) return false;
            [[fallthrough]];
        }
        case Decision::TakeNew: {
            const fs::path tmp = deployed.string() + ".foxml-tmp";
            fs::copy_file(source, tmp,
                          fs::copy_options::overwrite_existing, ec);
            if (ec) {
                fs::remove(tmp);  // best-effort
                return false;
            }
            fs::rename(tmp, deployed, ec);
            if (ec) {
                fs::remove(tmp);  // best-effort
                return false;
            }
            return true;
        }
    }
    return false;
}

}  // namespace fox_install::conflict
