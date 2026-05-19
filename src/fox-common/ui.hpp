#ifndef FOX_INSTALL_UI_HPP
#define FOX_INSTALL_UI_HPP

// fox-install reusable UI primitives.
//
// Header for everything pacman-style printable: sections, substeps,
// ok/warn/err lines, the progress bar, and the column-aligned summary
// row. Mirrors the helpers in render.sh so output looks consistent
// across the bash and native code paths during the migration.

#include <string>

namespace fox_install::ui {

void init();                                  // detect TTY + color support
bool tty();                                   // are we writing to a real TTY?

void section(const std::string& title);       // ":: Title"
void substep(const std::string& msg);         // " -> msg"
void ok     (const std::string& msg);         // "  + msg"
void skipped(const std::string& msg);         // "  - msg" dimmed — "already configured" lines
void warn   (const std::string& msg);         // "warning: msg"
void err    (const std::string& msg);         // "error: msg"

// One-line, right-aligned progress bar. Re-call on the same line until
// done; finalize() emits the trailing newline.
void progress(std::size_t current, std::size_t total, const std::string& label);
void progress_finalize();

// Header-style step indicator for the module dispatcher. Prints one
// full line with a fixed-width bar, the count, and the module name.
// Unlike progress(), this terminates with \n and is meant to print
// once per module rather than animate.
void module_progress(std::size_t current, std::size_t total, const std::string& name);

// "  label                : value"  — used by the end-of-install summary.
void summary_row(const std::string& label, const std::string& value);

// Yes/no prompt. Reads a SINGLE character (no Enter required). Accepts
// y/Y → true, n/N → false, Enter → default, anything else → re-prompt
// (no echo, no buffer pollution). Returns `default_yes` under
// --yes / no-TTY / closed stdin.
bool ask_yn(const std::string& question, bool default_yes, bool assume_yes);

// Multi-choice prompt. `valid_chars` is the set of legal single-char
// responses (e.g. "012"); `default_c` must be in `valid_chars`. Reads
// one character; anything not in `valid_chars` is ignored (re-prompt).
// Enter picks `default_c`. Returns `default_c` under --yes / no-TTY.
char ask_choice(const std::string& question,
                const std::string& valid_chars,
                char default_c,
                bool assume_yes);

}  // namespace fox_install::ui

#endif
