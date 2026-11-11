// desk — top-level unified entry for Linux_Theme workstation tools.
//
// Dispatches `desk <namespace> <subcommand> [args]` to the appropriate
// namespace binary (desk-ai, desk-sec, ...) via execvp. Registry of
// namespaces lives in dispatch.def, expanded by the X-macro below.
//
// Phase 1: dispatch.def is empty. `desk help` prints "no namespaces
// registered yet" — the skeleton exists, namespaces wire in later.

#include "dispatch.hpp"

#include <cstdlib>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include <unistd.h>

namespace {

constexpr const char* kVersion = "0.1.0 (Phase 1 scaffolding)";

std::vector<desk_common::dispatch::Entry> build_registry() {
    std::vector<desk_common::dispatch::Entry> entries;
#define DESK_NAMESPACE(name, binary, description) \
    entries.push_back({#name, #binary, description});
#include "dispatch.def"
#undef DESK_NAMESPACE
    return entries;
}

void print_help(const std::vector<desk_common::dispatch::Entry>& registry) {
    desk_common::dispatch::print_help(
        "desk — unified entry for Linux_Theme workstation tools.\n"
        "Usage: desk <namespace> <subcommand> [args]",
        registry
    );
    std::cout << "\nRun 'desk <namespace> help' for subcommands in that namespace.\n"
              << "The flat commands (desk vpn, desk backup, desk vault, ...) still work: 'desk help <command>' shows one.\n"
              << "Run 'desk --version' for version info.\n";
}

// Runs args[0] from PATH with args (execvp: a name without a slash is looked up in PATH). Returns only when it
// can't, with errno.
int try_exec(const std::vector<std::string>& args) {
    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
    argv.push_back(nullptr);
    execvp(argv[0], argv.data());
    return errno;
}

// A name `desk-<name>` can be built from and still be a PATH lookup: no slash, not an option.
bool plain_name(const std::string& s) {
    return !s.empty() && s[0] != '-' && s.find('/') == std::string::npos;
}

// The flat commands the tools' help texts name: `desk vpn`, `desk vault init`, `desk help dispatch`. The old bash fox,
// deployed as desk-legacy, defines what they mean (`desk vault` is its pass wrapper, not the compiled desk-vault), so it
// gets every argument first. Without it, `desk <name> ...` runs desk-<name>, else the plain <name> (the tools that
// lost their prefix: `desk word-count`), when leaf_ok. Returns only when none runs, with the last errno.
int exec_flat(int argc, char** argv, bool leaf_ok) {
    std::vector<std::string> legacy{"desk-legacy"};
    for (int i = 1; i < argc; ++i) legacy.push_back(argv[i]);
    int err = try_exec(legacy);
    if (!leaf_ok || !plain_name(argv[1])) return err;
    // The plain name only as one of your own tools in ~/.local/bin, never a system command (`desk tail`).
    const char* home = std::getenv("HOME");
    const std::string own = home ? std::string(home) + "/.local/bin/" + argv[1] : std::string();
    for (const std::string& name : {std::string("desk-") + argv[1], own}) {
        if (name.empty()) continue;
        std::vector<std::string> leaf{name};
        for (int i = 2; i < argc; ++i) leaf.push_back(argv[i]);
        const int leaf_err = try_exec(leaf);
        if (leaf_err != ENOENT) return leaf_err;
    }
    return err;
}

bool is_help_arg(const std::string& a) {
    return a == "help" || a == "--help" || a == "-h";
}

bool is_version_arg(const std::string& a) {
    return a == "--version" || a == "-V";
}

}  // namespace

int main(int argc, char** argv) {
    auto registry = build_registry();

    if (argc < 2 || is_help_arg(argv[1])) {
        // `desk help <command>` is the old fox's per-command help; fall back to this one's.
        if (argc >= 3) exec_flat(argc, argv, /*leaf_ok=*/false);
        print_help(registry);
        return 0;
    }

    if (is_version_arg(argv[1])) {
        std::cout << "desk " << kVersion << "\n";
        return 0;
    }

    const std::string ns = argv[1];
    const auto* entry = desk_common::dispatch::find(registry, ns);
    if (!entry) {
        int err = exec_flat(argc, argv, /*leaf_ok=*/true);
        if (err != ENOENT) {
            std::cerr << "desk: cannot run desk-legacy or desk-" << ns << ": " << std::strerror(err) << '\n';
            return 126;
        }
        std::cerr << "desk: unknown namespace '" << ns << "'.\n"
                  << "Run 'desk help' to see available namespaces.\n";
        return 2;
    }

    // Hand off to the namespace's leaf binary. argv[0] for the leaf is
    // its own binary name; remaining args are everything after argv[1].
    std::vector<std::string> leaf_args;
    leaf_args.reserve(static_cast<std::size_t>(argc - 1));
    leaf_args.push_back(entry->binary);
    for (int i = 2; i < argc; ++i) leaf_args.push_back(argv[i]);

    return desk_common::dispatch::exec_leaf(entry->binary, leaf_args);
}
