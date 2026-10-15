// fox — top-level unified entry for FoxML workstation tools.
//
// Dispatches `fox <namespace> <subcommand> [args]` to the appropriate
// namespace binary (fox-ai, fox-sec, ...) via execvp. Registry of
// namespaces lives in dispatch.def, expanded by the X-macro below.
//
// Phase 1: dispatch.def is empty. `fox help` prints "no namespaces
// registered yet" — the skeleton exists, namespaces wire in later.

#include "dispatch.hpp"

#include <cerrno>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

#include <unistd.h>

namespace {

constexpr const char* kVersion = "0.1.0 (Phase 1 scaffolding)";

std::vector<fox_common::dispatch::Entry> build_registry() {
    std::vector<fox_common::dispatch::Entry> entries;
#define FOX_NAMESPACE(name, binary, description) \
    entries.push_back({#name, #binary, description});
#include "dispatch.def"
#undef FOX_NAMESPACE
    return entries;
}

void print_help(const std::vector<fox_common::dispatch::Entry>& registry) {
    fox_common::dispatch::print_help(
        "fox — unified entry for FoxML workstation tools.\n"
        "Usage: fox <namespace> <subcommand> [args]",
        registry
    );
    std::cout << "\nRun 'fox <namespace> help' for subcommands in that namespace.\n"
              << "The flat commands (fox vpn, fox backup, fox vault, ...) still work: 'fox help <command>' shows one.\n"
              << "Run 'fox --version' for version info.\n";
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

// A name `fox-<name>` can be built from and still be a PATH lookup: no slash, not an option.
bool plain_name(const std::string& s) {
    return !s.empty() && s[0] != '-' && s.find('/') == std::string::npos;
}

// The flat commands the tools' help texts name: `fox vpn`, `fox vault init`, `fox help dispatch`. The old bash fox,
// deployed as fox-legacy, defines what they mean (`fox vault` is its pass wrapper, not the compiled fox-vault), so it
// gets every argument first. Without it, `fox <name> ...` runs fox-<name> when leaf_ok. Returns only when neither
// runs, with the last errno.
int exec_flat(int argc, char** argv, bool leaf_ok) {
    std::vector<std::string> legacy{"fox-legacy"};
    for (int i = 1; i < argc; ++i) legacy.push_back(argv[i]);
    int err = try_exec(legacy);
    if (!leaf_ok || !plain_name(argv[1])) return err;
    std::vector<std::string> leaf{std::string("fox-") + argv[1]};
    for (int i = 2; i < argc; ++i) leaf.push_back(argv[i]);
    int leaf_err = try_exec(leaf);
    return leaf_err == ENOENT ? err : leaf_err;
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
        // `fox help <command>` is the old fox's per-command help; fall back to this one's.
        if (argc >= 3) exec_flat(argc, argv, /*leaf_ok=*/false);
        print_help(registry);
        return 0;
    }

    if (is_version_arg(argv[1])) {
        std::cout << "fox " << kVersion << "\n";
        return 0;
    }

    const std::string ns = argv[1];
    const auto* entry = fox_common::dispatch::find(registry, ns);
    if (!entry) {
        int err = exec_flat(argc, argv, /*leaf_ok=*/true);
        if (err != ENOENT) {
            std::cerr << "fox: cannot run fox-legacy or fox-" << ns << ": " << std::strerror(err) << '\n';
            return 126;
        }
        std::cerr << "fox: unknown namespace '" << ns << "'.\n"
                  << "Run 'fox help' to see available namespaces.\n";
        return 2;
    }

    // Hand off to the namespace's leaf binary. argv[0] for the leaf is
    // its own binary name; remaining args are everything after argv[1].
    std::vector<std::string> leaf_args;
    leaf_args.reserve(static_cast<std::size_t>(argc - 1));
    leaf_args.push_back(entry->binary);
    for (int i = 2; i < argc; ++i) leaf_args.push_back(argv[i]);

    return fox_common::dispatch::exec_leaf(entry->binary, leaf_args);
}
