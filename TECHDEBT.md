# Technical Debt - FoxML Installation Logic

This document tracks identified areas for improvement, consolidation, and cleanup within the installation pipeline (`bootstrap.sh`, `install.sh`, and `src/fox-install/`).

## High Priority: Consolidation & Redundancy

- **Triple-Checked Logic:** Disk space verification and hardware detection (NVIDIA) are currently implemented in `bootstrap.sh`, `install.sh`, and the C++ `preflight`/`detect` modules.
  - *Goal:* Centralize all environment discovery in the C++ orchestrator; wrappers should only check for build dependencies.
- **Bash/C++ Mirroring:** `mappings.sh` still contains logic that has been ported to C++ (e.g., Firefox profile discovery, JSON merging).
  - *Goal:* Decommission legacy bash logic once the C++ path is confirmed 100% stable across all edge cases.
- **Sudo Keepalive:** Multiple background loops in Bash scripts managing the sudo cache.
  - *Goal:* Standardize on a single keepalive mechanism.

## Architectural Improvements

- **Shell Escaping in C++:** Frequent use of `sh::run({"sh", "-c", "..."})` to handle pipes and redirection.
  - *Goal:* Refactor `sh::run` to handle piping natively or move more logic into C++ filesystem/stream operations to avoid shell overhead and escaping risks.
- **Bulk Deploy "Ghosts":** `specials.cpp` copies directories (scripts/bin) but never prunes old files. Renamed or removed scripts persist in the user's `~/.local/bin` indefinitely.
  - *Goal:* Implement a manifest-based or "sync" style deploy that removes files no longer present in the repository.
- **Hardcoded Dependencies:** The base package list in `deps.cpp` is a static vector.
  - *Goal:* Move package lists to a sidecar JSON or YAML file to allow updates without recompilation.
- **Updates-pill list cache is dual-written:** both `clock.sh` and `updates.sh` write `$XDG_RUNTIME_DIR/foxml-waybar/updates.list`, but only `updates.sh`'s `fresh()` consults `pacman.log` mtime — `clock.sh`'s does not. Right after an upgrade the tooltip's cached package list can lag by up to one refresh cycle (the count is correct; the list is stale). The click menu always re-runs `checkupdates`, so it's never stale. Surfaced 2026-05-31 with the updates-pill menu rework.
  - *Goal:* single writer for the list cache, or make `clock.sh`'s `fresh()` also invalidate on `pacman.log` mtime.

## UX & Interactivity

- **Inconsistent Prompts:** While major prompts use `read -n 1`, some deeper configuration wizards might still rely on older `read` patterns.
  - *Goal:* Audit all modules for consistent single-key input usage.
- **Single-flag runs auto-commit headlessly:** In the state-driven path, passing one module flag (e.g. `fox-install --keybind-docs`) selects that module, but `detect` also auto-enables every detected hardware module (GPU, fprint), and with no TTY the *commit this plan?* prompt defaults to *yes* and proceeds — so a one-module invocation silently runs the whole auto-enabled set. Harmless in practice (interactive runs show the preview/gate; headless, `sudo` blocks the root writes) and hit at most ~once per install. Surfaced 2026-05-31 while testing the `keybind_docs` module.
  - *Goal:* under no TTY, default the commit prompt to **abort / preview-only** unless `--full` / `--yes` is given; optionally add a true `--only X` that runs strictly the named module(s) without the hardware auto-enable.

## Maintenance Notes

- **Date of Audit:** 2026-05-14
- **Status:** "If it ain't broke, don't fix it" — these are tracked for future refactors but not currently impacting installation success.
