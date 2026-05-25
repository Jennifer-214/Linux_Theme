// fox-sec-health — `fox sec health` CLI entry point.
//
// Surfaces the foxml-health library on the command line. Three output
// modes:
//   --quiet      : no output, exit code only (for scripts/cron)
//   default      : one line per check
//   --verbose    : detail + fix-hint for every non-pass
//
// Exit code policy (from fox_health::worst_exit):
//   0  green
//   1  warnings / low-severity fails
//   2  one or more critical fails
//   3  one or more high-severity fails

#include "../fox-health/health.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

void usage() {
    std::printf(
        "usage: fox sec health [--quiet] [--verbose]\n"
        "                      [--only PREFIX[,PREFIX...]] [--exclude PREFIX[,PREFIX...]]\n"
        "                      [--no-runtime] [--no-slow]\n"
        "\n"
        "  --quiet      exit code only, no output\n"
        "  --verbose    show detail + fix hint for every non-pass\n"
        "  --only A,B   limit to check-id prefixes (e.g. --only A,B for boot+auth only)\n"
        "  --exclude X  skip check-id prefixes\n"
        "  --no-runtime skip checks needing a live graphical session\n"
        "  --no-slow    skip checks bounded by network/disk (pacman -Qkk, arch-audit)\n"
        "\n"
        "exit codes: 0=ok  1=warn  2=critical  3=high\n");
}

std::vector<std::string> split_csv(const char* s) {
    std::vector<std::string> out;
    std::string cur;
    for (const char* p = s; *p; ++p) {
        if (*p == ',') { if (!cur.empty()) out.push_back(cur); cur.clear(); }
        else cur.push_back(*p);
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

const char* status_glyph(fox_health::Status s) {
    using S = fox_health::Status;
    bool tty = ::isatty(STDOUT_FILENO);
    switch (s) {
        case S::Pass: return tty ? "\033[32m✓\033[0m" : "ok  ";
        case S::Warn: return tty ? "\033[33m!\033[0m   "    : "warn";
        case S::Fail: return tty ? "\033[31m✗\033[0m" : "fail";
        case S::Skip: return tty ? "\033[2m-\033[0m   "    : "skip";
    }
    return "?";
}

}  // namespace

int main(int argc, char** argv) {
    bool quiet = false, verbose = false;
    fox_health::CheckOptions opts;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help")             { usage(); return 0; }
        else if (a == "--quiet" || a == "-q")        quiet = true;
        else if (a == "--verbose" || a == "-v")      verbose = true;
        else if (a == "--no-runtime")                opts.include_runtime = false;
        else if (a == "--no-slow")                   opts.include_slow = false;
        else if (a == "--only" && i + 1 < argc)      opts.only    = split_csv(argv[++i]);
        else if (a == "--exclude" && i + 1 < argc)   opts.exclude = split_csv(argv[++i]);
        else {
            std::fprintf(stderr, "fox sec health: unknown argument: %s\n", a.c_str());
            usage();
            return 64;
        }
    }

    auto results = fox_health::run_all(opts);
    int exit_code = fox_health::worst_exit(results);

    if (!quiet) {
        for (const auto& r : results) {
            std::printf("%s [%s] %s — %s\n",
                status_glyph(r.status),
                fox_health::severity_name(r.severity),
                r.id.c_str(),
                r.title.c_str());
            if (verbose || r.status == fox_health::Status::Fail) {
                if (!r.detail.empty()) {
                    // Indent each line.
                    size_t start = 0;
                    while (start < r.detail.size()) {
                        size_t nl = r.detail.find('\n', start);
                        if (nl == std::string::npos) nl = r.detail.size();
                        std::printf("    %.*s\n",
                            static_cast<int>(nl - start), r.detail.c_str() + start);
                        start = nl + 1;
                    }
                }
                if (!r.fix_hint.empty()) {
                    std::printf("    fix: %s\n", r.fix_hint.c_str());
                }
            }
        }
    }
    return exit_code;
}
