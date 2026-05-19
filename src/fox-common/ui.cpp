#include "ui.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

namespace fox_install::ui {

namespace {

bool g_tty    = false;
bool g_color  = false;

// SGR escapes (only emitted when g_color is true).
constexpr const char* C_RESET = "\033[0m";
constexpr const char* C_BOLD  = "\033[1m";
constexpr const char* C_DIM   = "\033[2m";
constexpr const char* C_RED   = "\033[31m";
constexpr const char* C_GRN   = "\033[32m";
constexpr const char* C_YLW   = "\033[33m";
constexpr const char* C_CYN   = "\033[36m";

const char* c(const char* code) { return g_color ? code : ""; }

int terminal_cols() {
    winsize ws{};
    if (::ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
        return ws.ws_col;
    }
    const char* env = std::getenv("COLUMNS");
    if (env) return std::atoi(env);
    return 80;
}

}  // namespace

void init() {
    g_tty = ::isatty(STDOUT_FILENO);
    const char* term = std::getenv("TERM");
    g_color = g_tty && term && std::strcmp(term, "dumb") != 0;
}

bool tty() { return g_tty; }

void section(const std::string& title) {
    std::printf("%s%s::%s %s%s%s\n",
        c(C_BOLD), c(C_CYN), c(C_RESET),
        c(C_BOLD), title.c_str(), c(C_RESET));
}

void substep(const std::string& msg) {
    std::printf(" %s->%s %s\n", c(C_BOLD), c(C_RESET), msg.c_str());
}

void ok(const std::string& msg) {
    std::printf("  %s+%s %s\n", c(C_GRN), c(C_RESET), msg.c_str());
}

void skipped(const std::string& msg) {
    std::printf("  %s-%s %s%s%s\n",
                c(C_DIM), c(C_RESET),
                c(C_DIM), msg.c_str(), c(C_RESET));
}

void warn(const std::string& msg) {
    std::fprintf(stderr, "%swarning:%s %s\n", c(C_YLW), c(C_RESET), msg.c_str());
}

void err(const std::string& msg) {
    std::fprintf(stderr, "%serror:%s %s\n", c(C_RED), c(C_RESET), msg.c_str());
}

void progress(std::size_t current, std::size_t total, const std::string& label) {
    if (total == 0) return;
    constexpr int bar_w = 30;
    int pct    = static_cast<int>((current * 100) / total);
    int filled = static_cast<int>((current * bar_w) / total);
    if (pct > 100) pct = 100;
    if (filled > bar_w) filled = bar_w;

    std::string bar(filled, '#');
    bar.append(bar_w - filled, '-');

    char tail[80];
    int  tail_len = std::snprintf(tail, sizeof(tail), " [%s] %3d%% (%zu/%zu)",
                                  bar.c_str(), pct, current, total);
    int cols = terminal_cols();
    int label_w = cols - 3 - tail_len;        // "::: " prefix = 3
    if (label_w < 10) label_w = 10;
    std::printf("\r:: %-*s%s", label_w, label.c_str(), tail);
    std::fflush(stdout);
}

void progress_finalize() {
    std::putchar('\n');
    std::fflush(stdout);
}

void module_progress(std::size_t current, std::size_t total, const std::string& name) {
    if (total == 0) return;
    constexpr int bar_w = 30;
    int pct    = static_cast<int>((current * 100) / total);
    int filled = static_cast<int>((current * bar_w) / total);
    if (pct > 100) pct = 100;
    if (filled > bar_w) filled = bar_w;

    std::string bar(filled, '#');
    bar.append(bar_w - filled, '-');
    std::printf("\n%s::%s [%s%s%s] %s%zu/%zu%s %s(%d%%)%s %s%s%s\n",
        c(C_BOLD), c(C_RESET),
        c(C_CYN), bar.c_str(), c(C_RESET),
        c(C_BOLD), current, total, c(C_RESET),
        c(C_DIM), pct, c(C_RESET),
        c(C_BOLD), name.c_str(), c(C_RESET));
}

void summary_row(const std::string& label, const std::string& value) {
    std::printf("  %s%-22s%s : %s\n",
        c(C_DIM), label.c_str(), c(C_RESET), value.c_str());
}

namespace {

// RAII helper: put STDIN into cbreak (non-canonical, no echo) for the
// duration of one prompt, then restore the original termios. Restore
// even on early return / exception. Falls through silently to "no-op"
// when stdin isn't a TTY — caller already gates on isatty().
class CbreakMode {
public:
    CbreakMode() {
        if (::tcgetattr(STDIN_FILENO, &old_) != 0) return;
        struct termios n = old_;
        n.c_lflag &= ~(ICANON | ECHO);
        n.c_cc[VMIN]  = 1;          // read returns after 1 byte
        n.c_cc[VTIME] = 0;          // no inter-char timeout
        if (::tcsetattr(STDIN_FILENO, TCSANOW, &n) == 0) active_ = true;
    }
    ~CbreakMode() {
        if (active_) ::tcsetattr(STDIN_FILENO, TCSANOW, &old_);
    }
    CbreakMode(const CbreakMode&)            = delete;
    CbreakMode& operator=(const CbreakMode&) = delete;
private:
    struct termios old_{};
    bool active_ = false;
};

// Read one byte. Returns 0 on EOF / read error.
char read_one_char() {
    char c = 0;
    ssize_t n = ::read(STDIN_FILENO, &c, 1);
    return n == 1 ? c : 0;
}

}  // namespace

bool ask_yn(const std::string& question, bool default_yes, bool assume_yes) {
    if (assume_yes || !::isatty(STDIN_FILENO)) return default_yes;
    std::printf("%s [%s] ", question.c_str(), default_yes ? "Y/n" : "y/N");
    std::fflush(stdout);

    CbreakMode raw;
    bool result = default_yes;
    for (;;) {
        char c = read_one_char();
        if (c == 0) break;                                    // EOF / closed stdin
        if (c == '\n' || c == '\r') { result = default_yes; break; }
        if (c == 'y' || c == 'Y')    { result = true;        break; }
        if (c == 'n' || c == 'N')    { result = false;       break; }
        if (c == 3 /* Ctrl-C */)     { std::printf("^C\n"); std::exit(130); }
        // Anything else: ignore + re-loop (guards against typos / arrow
        // keys / accidental key bumps).
    }
    // Echo the resolved choice ourselves since ECHO was off.
    std::printf("%c\n", result ? 'y' : 'n');
    return result;
}

char ask_choice(const std::string& question,
                const std::string& valid_chars,
                char default_c,
                bool assume_yes) {
    if (assume_yes || !::isatty(STDIN_FILENO)) return default_c;
    if (valid_chars.find(default_c) == std::string::npos) {
        // Caller bug — silently return default anyway rather than loop forever.
        return default_c;
    }
    std::printf("%s ", question.c_str());
    std::fflush(stdout);

    CbreakMode raw;
    char result = default_c;
    for (;;) {
        char c = read_one_char();
        if (c == 0) break;
        if (c == '\n' || c == '\r') { result = default_c; break; }
        if (c == 3 /* Ctrl-C */)    { std::printf("^C\n"); std::exit(130); }
        if (valid_chars.find(c) != std::string::npos) { result = c; break; }
        // Anything else: ignore + keep waiting.
    }
    std::printf("%c\n", result);
    return result;
}

}  // namespace fox_install::ui
