// fox-ai — namespace dispatcher for AI-augmented tools.
//
// Invoked by `fox ai <subcommand> [args]` after the top-level fox
// binary recognizes the `ai` namespace. Looks up `<subcommand>` in
// dispatch.def (X-macro expanded below) and execvp's the leaf binary
// (e.g., fox-ai-doctor) with remaining args.
//
// Can also be run directly as `fox-ai <subcommand>` for parity with
// the unified entry — useful for scripts and bypass.

#include "dispatch.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr const char* kVersion = "0.1.0 (Phase 2)";

std::vector<fox_common::dispatch::Entry> build_registry() {
    std::vector<fox_common::dispatch::Entry> entries;
#define FOX_SUBCMD(name, binary, description) \
    entries.push_back({#name, #binary, description});
#include "dispatch.def"
#undef FOX_SUBCMD
    return entries;
}

void print_help(const std::vector<fox_common::dispatch::Entry>& registry) {
    fox_common::dispatch::print_help(
        "fox-ai — AI-augmented tools.\n"
        "Usage: fox ai <subcommand> [args]    (or directly: fox-ai <subcommand>)",
        registry
    );
    std::cout << "\nRun 'fox ai <subcommand> --help' for tool-specific help.\n";
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
        std::cout << "fox-ai " << kVersion << "\n";
        return 0;
    }

    const std::string sub = argv[1];
    const auto* entry = fox_common::dispatch::find(registry, sub);
    if (!entry) {
        std::cerr << "fox-ai: unknown subcommand '" << sub << "'.\n"
                  << "Run 'fox ai help' to see available subcommands.\n";
        return 2;
    }

    std::vector<std::string> leaf_args;
    leaf_args.reserve(static_cast<std::size_t>(argc - 1));
    leaf_args.push_back(entry->binary);
    for (int i = 2; i < argc; ++i) leaf_args.push_back(argv[i]);

    return fox_common::dispatch::exec_leaf(entry->binary, leaf_args);
}
