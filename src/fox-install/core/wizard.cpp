#include "wizard.hpp"

#include "../../fox-common/ui.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <optional>
#include <string>
#include <system_error>
#include <termios.h>
#include <unistd.h>
#include <utility>

namespace fox_install::wizard {

const char* action_name(Action a) {
    switch (a) {
        case Action::Skip:     return "skip";
        case Action::Run:      return "run";
        case Action::Conflict: return "conflict";
    }
    return "unknown";
}

Action default_action_for(state::Status status) {
    switch (status) {
        case state::Status::Fresh:    return Action::Run;
        case state::Status::Update:   return Action::Run;
        case state::Status::Noop:     return Action::Skip;
        case state::Status::Conflict: return Action::Conflict;
        case state::Status::Blocked:  return Action::Skip;
    }
    return Action::Skip;
}

Plan default_plan(
    const std::vector<const Module*>& modules,
    const Context& ctx,
    const state::Manifest& manifest
) {
    Plan p;
    p.modules.reserve(modules.size());
    for (const Module* m : modules) {
        ModulePlan mp{};
        mp.module = m;
        if (m->state_check) {
            mp.classification = m->state_check(ctx, manifest);
        } else {
            mp.classification = {state::Status::Fresh,
                                 "no state_check — assumed fresh"};
        }
        mp.action            = default_action_for(mp.classification.status);
        mp.conflict_decision = conflict::Decision::KeepMine;
        p.modules.push_back(std::move(mp));
    }
    return p;
}

namespace {

// Read one key in cbreak mode. Mirrors fox-common/ui.cpp's private
// CbreakMode + read_one_char pair — kept local here because the
// wizard wants its own ownership over the termios lifetime (and
// ui's helpers are intentionally private to that translation unit).
char read_key() {
    struct termios old{};
    if (::tcgetattr(STDIN_FILENO, &old) != 0) return 0;
    struct termios n = old;
    n.c_lflag &= ~(ICANON | ECHO);
    n.c_cc[VMIN]  = 1;
    n.c_cc[VTIME] = 0;
    if (::tcsetattr(STDIN_FILENO, TCSANOW, &n) != 0) return 0;
    char c = 0;
    ssize_t r = ::read(STDIN_FILENO, &c, 1);
    ::tcsetattr(STDIN_FILENO, TCSANOW, &old);
    return r == 1 ? c : 0;
}

void clear_screen() {
    // ED 2 = erase the entire screen; CUP 1,1 = move cursor to home.
    // Standard VT100 sequences, supported by every terminal we care
    // about including TERM=linux on the bare console.
    std::printf("\033[2J\033[H");
}

const char* prereq_mark(bool needed) {
    // ASCII-only — TERM=linux can't render Unicode checkmarks reliably.
    return needed ? "needed" : "—";
}

void render_screen(const ModulePlan& mp, std::size_t idx, std::size_t total) {
    const Module& m = *mp.module;

    ui::section("fox-install wizard (" + std::to_string(idx + 1)
                + "/" + std::to_string(total) + ")");
    std::printf("\n");
    std::printf("  module       : %s\n", m.slug);
    std::printf("  description  : %s\n", m.description);
    std::printf("  state        : %s — %s\n",
                state::status_name(mp.classification.status),
                mp.classification.reason.c_str());
    std::printf("  prereqs      : root[%s]  graphical[%s]  network[%s]\n",
                prereq_mark(m.requires_root),
                prereq_mark(m.requires_graphical),
                prereq_mark(m.requires_network));
    std::printf("\n");

    switch (mp.classification.status) {
        case state::Status::Conflict: {
            using D = conflict::Decision;
            std::printf("  Conflict resolution:\n");
            std::printf("    [%s] keep my version\n",
                        mp.conflict_decision == D::KeepMine ? "*" : " ");
            std::printf("    [%s] take new version\n",
                        mp.conflict_decision == D::TakeNew ? "*" : " ");
            std::printf("    [%s] save .foxml-bak then take new\n",
                        mp.conflict_decision == D::BackupThenTakeNew ? "*" : " ");
            std::printf("\n");
            std::printf("  [SPACE] cycle   [l/Enter] next   [h] prev   [q] quit\n");
            break;
        }
        case state::Status::Blocked: {
            std::printf("  Action       : skip (blocked — cannot run)\n");
            std::printf("\n");
            std::printf("  [l/Enter] next   [h] prev   [q] quit\n");
            break;
        }
        default: {
            std::printf("  Action:\n");
            std::printf("    [%s] run\n",  mp.action == Action::Run  ? "*" : " ");
            std::printf("    [%s] skip\n", mp.action == Action::Skip ? "*" : " ");
            std::printf("\n");
            std::printf("  [SPACE] toggle   [l/Enter] next   [h] prev   [q] quit\n");
            break;
        }
    }
    std::fflush(stdout);
}

void toggle_binary(ModulePlan& mp) {
    mp.action = (mp.action == Action::Run) ? Action::Skip : Action::Run;
}

void cycle_conflict(ModulePlan& mp) {
    using D = conflict::Decision;
    switch (mp.conflict_decision) {
        case D::KeepMine:          mp.conflict_decision = D::TakeNew;          break;
        case D::TakeNew:           mp.conflict_decision = D::BackupThenTakeNew; break;
        case D::BackupThenTakeNew: mp.conflict_decision = D::KeepMine;         break;
    }
}

}  // namespace

Plan run(Plan plan, const Context& ctx) {
    // Non-interactive contexts: hand the plan straight back. The default
    // actions populated by default_plan are already the conservative
    // pick for an unattended run (Noop/Blocked → Skip; Conflict default
    // is KeepMine — never silently overwrite).
    if (ctx.assume_yes || !ui::tty()) return plan;
    if (plan.modules.empty())          return plan;

    std::size_t cursor = 0;
    while (cursor < plan.modules.size()) {
        ModulePlan& mp = plan.modules[cursor];

        clear_screen();
        render_screen(mp, cursor, plan.modules.size());

        char key = read_key();
        if (key == 0) break;                              // EOF — non-TTY surprise; bail
        if (key == 'q' || key == 3 /* Ctrl-C */) {
            plan.aborted = true;
            break;
        }

        const bool is_conflict = (mp.classification.status == state::Status::Conflict);
        const bool is_blocked  = (mp.classification.status == state::Status::Blocked);

        if (key == 'h' || key == 'k') {
            if (cursor > 0) --cursor;
            continue;
        }
        if (key == 'l' || key == 'j' || key == '\n' || key == '\r') {
            ++cursor;
            continue;
        }
        if (key == ' ') {
            if (is_blocked) continue;                     // no toggle when forced-skip
            if (is_conflict) {
                cycle_conflict(mp);                       // stay on this screen for further cycling
            } else {
                toggle_binary(mp);
                ++cursor;                                  // auto-advance on binary toggle
            }
            continue;
        }
        // Anything else: ignore, redraw next iteration.
    }

    clear_screen();
    if (plan.aborted) {
        ui::section("Wizard aborted");
        ui::warn("install plan abandoned — no modules will run");
    }
    // Successful exit: leave the screen cleared; the caller (preview()
    // in normal flow) prints the next thing the user should look at.
    return plan;
}

namespace {

// Sentinel file for a Conflict-aware module. The dispatcher uses
// this to apply BackupThenTakeNew (copy current → .foxml-bak before
// the module runs) and to know whether KeepMine has anywhere to
// preserve. Modules without a sentinel here keep their
// conflict_decision recorded but unapplied — surfacing that gap is
// fine for v1, since the only Conflict-classifying modules we ship
// today have files we know about.
std::optional<std::filesystem::path>
conflict_sentinel(const std::string& slug, const Context& ctx) {
    if (slug == "render") {
        return ctx.config_home / "hypr" / "hyprland.conf";
    }
    if (slug == "mac_random") {
        return std::filesystem::path(
            "/etc/NetworkManager/conf.d/00-foxml-mac-random.conf");
    }
    return std::nullopt;
}

}  // namespace

void apply_conflict_decisions(Plan& plan, const Context& ctx) {
    for (auto& mp : plan.modules) {
        if (mp.action != Action::Conflict) continue;

        const auto sentinel = conflict_sentinel(mp.module->slug, ctx);
        if (!sentinel) {
            // No known per-module deploy path; we can't act on the
            // decision yet. Leave the action as Conflict (treated as
            // Run downstream) so the module still runs and the user's
            // choice is at least logged via the preview output.
            continue;
        }

        switch (mp.conflict_decision) {
            case conflict::Decision::KeepMine:
                // The cleanest way to "keep the user's file" with the
                // tools we have today: skip the module entirely so
                // nothing tries to overwrite. Trade-off — the rest of
                // the module's work is also skipped, which is fine for
                // file-only modules (render, mac_random) but would
                // surprise someone if applied to a module with side
                // effects beyond the sentinel. Acceptable v1 scope.
                mp.action = Action::Skip;
                break;

            case conflict::Decision::BackupThenTakeNew: {
                if (!std::filesystem::exists(*sentinel)) break;  // nothing to back up
                const std::filesystem::path bak =
                    sentinel->string() + ".foxml-bak";
                std::error_code ec;
                std::filesystem::copy_file(*sentinel, bak,
                    std::filesystem::copy_options::overwrite_existing, ec);
                if (ec) {
                    ui::warn("backup of " + sentinel->string()
                             + " to " + bak.string() + " failed: " + ec.message()
                             + " — module will run, but no .foxml-bak written");
                }
                // Module runs as normal; the deploy step will overwrite.
                break;
            }

            case conflict::Decision::TakeNew:
                // Nothing to do — the module's normal run writes the
                // new content over the user's file, which is exactly
                // what the user asked for.
                break;
        }
    }
}

bool preview(const Plan& plan, const Context& ctx) {
    std::size_t run = 0, skip = 0, conflict = 0;
    for (const auto& mp : plan.modules) {
        switch (mp.action) {
            case Action::Run:      ++run;      break;
            case Action::Skip:     ++skip;     break;
            case Action::Conflict: ++conflict; break;
        }
    }

    std::string header = "Install plan — "
        + std::to_string(run) + " to run, "
        + std::to_string(skip) + " to skip";
    if (conflict > 0) header += ", " + std::to_string(conflict) + " conflict";
    if (conflict > 1) header += "s";
    ui::section(header);

    // One row per module so the user sees the entire plan ahead of
    // commit. For Skip, the reason field carries the "why this is a
    // no-op" string from the classifier (already current / user
    // customized / blocked) which is the bit the user is verifying.
    for (const auto& mp : plan.modules) {
        const char* marker = "?";
        std::string tail;
        switch (mp.action) {
            case Action::Run:
                marker = "+";
                break;
            case Action::Skip:
                marker = "-";
                if (!mp.classification.reason.empty()) {
                    tail = "  (" + mp.classification.reason + ")";
                }
                break;
            case Action::Conflict:
                marker = "!";
                tail = "  [" + std::string(conflict::decision_name(mp.conflict_decision)) + "]";
                break;
        }
        std::printf("  %s %-20s %s%s\n",
                    marker, mp.module->slug, mp.module->description, tail.c_str());
    }
    std::printf("\n");

    return ui::ask_yn("Apply this plan?", /*default_yes=*/true, ctx.assume_yes);
}

}  // namespace fox_install::wizard
