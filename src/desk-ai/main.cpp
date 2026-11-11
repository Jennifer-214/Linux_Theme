// desk-ai — namespace dispatcher for AI-augmented tools.
//
// Invoked by `desk ai <subcommand> [args]` after the top-level fox
// binary recognizes the `ai` namespace. Looks up `<subcommand>` in
// dispatch.def (X-macro expanded below) and execvp's the leaf binary
// (e.g., ai-doctor) with remaining args.
//
// Can also be run directly as `desk-ai <subcommand>` for parity with
// the unified entry — useful for scripts and bypass.

#include "dispatch.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr const char* kVersion = "0.1.0 (Phase 2)";

std::vector<desk_common::dispatch::Entry> build_registry() {
    std::vector<desk_common::dispatch::Entry> entries;
#define DESK_SUBCMD(name, binary, description) \
    entries.push_back({#name, #binary, description});
#include "dispatch.def"
#undef DESK_SUBCMD
    return entries;
}

void print_help(const std::vector<desk_common::dispatch::Entry>& registry) {
    desk_common::dispatch::print_help(
        "desk-ai — AI-augmented tools.\n"
        "Usage: desk ai <subcommand> [args]    (or directly: desk-ai <subcommand>)",
        registry
    );
    std::cout << "\nRun 'desk ai <subcommand> --help' for tool-specific help.\n";
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
        std::cout << "desk-ai " << kVersion << "\n";
        return 0;
    }

    const std::string sub = argv[1];
    const auto* entry = desk_common::dispatch::find(registry, sub);
    if (!entry) {
        std::cerr << "desk-ai: unknown subcommand '" << sub << "'.\n"
                  << "Run 'desk ai help' to see available subcommands.\n";
        return 2;
    }

    std::vector<std::string> leaf_args;
    leaf_args.reserve(static_cast<std::size_t>(argc - 1));
    leaf_args.push_back(entry->binary);
    for (int i = 2; i < argc; ++i) leaf_args.push_back(argv[i]);

    return desk_common::dispatch::exec_leaf(entry->binary, leaf_args);
}
