// fox — top-level unified entry for FoxML workstation tools.
//
// Dispatches `fox <namespace> <subcommand> [args]` to the appropriate
// namespace binary (fox-ai, fox-sec, ...) via execvp. Registry of
// namespaces lives in dispatch.def, expanded by the X-macro below.
//
// Phase 1: dispatch.def is empty. `fox help` prints "no namespaces
// registered yet" — the skeleton exists, namespaces wire in later.

#include "dispatch.hpp"

#include <iostream>
#include <string>
#include <vector>

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
              << "Run 'fox --version' for version info.\n";
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
