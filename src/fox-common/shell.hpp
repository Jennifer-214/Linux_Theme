#ifndef FOX_INSTALL_SHELL_HPP
#define FOX_INSTALL_SHELL_HPP

// Subprocess helpers. Every module talks to the system through these
// rather than calling system()/popen() directly, so:
//   • there's one place to enable dry-run logging
//   • sudo prompting is centralized (timeout, retry, lockout-safety)
//   • we never invoke a shell unless explicitly needed (less injection
//     surface than a popen("foo " + user_input))
//   • child-process stderr can be routed to a log file (see
//     set_stderr_log) so module errors don't scroll past during a
//     long install — the dispatcher tails the log on failure.

#include <filesystem>
#include <initializer_list>
#include <string>
#include <vector>

namespace fox_install::sh {

// Set by main() to short-circuit any side-effecting call. Reads survive.
void set_dry_run(bool on);
bool dry_run();

// Optional log sink for forked-child stderr. When set, every sh::run
// / sh::capture child process redirects its stderr to this file via
// dup2() before execvp() — the parent process's stderr is untouched,
// so ui::warn / ui::err from inside modules keep hitting the terminal.
// Pass an empty path to clear (default — child stderr inherits the
// terminal, current behavior).
void set_stderr_log(const std::filesystem::path& path);
const std::filesystem::path& stderr_log();

// Append a free-form section marker to the stderr log. Used by the
// install dispatcher to delimit one module's stderr output from the
// next so "tail the log on failure" can find the right slice. No-op
// when stderr_log is empty.
void log_section(const std::string& title);

// Read the last N lines from the stderr log. Returns an empty vector
// when the log is empty/unset/unreadable. Used by the dispatcher to
// surface the most-recent child errors after a module throws.
std::vector<std::string> tail_log(std::size_t lines);

// Runs argv, inheriting stdio. Returns the child's exit code (or -1 on
// fork/exec failure). No shell. Use this as the primitive for everything.
int run(std::initializer_list<const char*> argv);
int run(const std::vector<std::string>& argv);

// Runs argv, capturing stdout. Returns true on exit code 0.
bool capture(const std::vector<std::string>& argv, std::string& out);

// pacman -S --needed --noconfirm <pkgs...>
int pacman(std::initializer_list<const char*> pkgs);
int pacman(const std::vector<std::string>& pkgs);

// systemctl wrappers (--user when user=true)
int systemctl_enable(const std::string& unit, bool user);
int systemctl_start (const std::string& unit, bool user);
int systemctl_daemon_reload(bool user);

// `sudo -v` warm-up + cached check. Returns true if sudo is usable.
// Modules call this before any sudo-needing block so a cold cache
// can't silently kill the install mid-section.
bool sudo_warmup();

}  // namespace fox_install::sh

#endif
