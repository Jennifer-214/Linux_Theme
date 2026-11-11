// desk-sec — namespace dispatcher for security tools.
//
// Invoked by `desk sec <subcommand> [args]` after the top-level fox
// binary recognizes the `sec` namespace. Mirrors desk-ai/main.cpp
// modulo the registry source and naming.
//
// Also runnable directly as `desk-sec <subcommand>` for script use.

#include "dispatch.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr const char* kVersion = "0.1.0 (Phase 3)";

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
        "desk-sec — security tools.\n"
        "Usage: desk sec <subcommand> [args]    (or directly: desk-sec <subcommand>)",
        registry
    );
    std::cout << "\nRun 'desk sec <subcommand> --help' for tool-specific help.\n";
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
        std::cout << "desk-sec " << kVersion << "\n";
        return 0;
    }

    const std::string sub = argv[1];
    const auto* entry = desk_common::dispatch::find(registry, sub);
    if (!entry) {
        std::cerr << "desk-sec: unknown subcommand '" << sub << "'.\n"
                  << "Run 'desk sec help' to see available subcommands.\n";
        return 2;
    }

    std::vector<std::string> leaf_args;
    leaf_args.reserve(static_cast<std::size_t>(argc - 1));
    leaf_args.push_back(entry->binary);
    for (int i = 2; i < argc; ++i) leaf_args.push_back(argv[i]);

    return desk_common::dispatch::exec_leaf(entry->binary, leaf_args);
}
