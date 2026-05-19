// dispatch.hpp — registry + execvp helper for hierarchical fox CLI.
//
// Used by the top-level `fox` binary (knows about namespaces) and by
// every namespace-specific dispatcher (`fox-ai`, `fox-sec`, etc.) that
// knows about its own subcommands. Same Entry shape at both levels.
//
// Each dispatcher owns its registry as a std::vector<Entry>, typically
// constructed from an X-macro dispatch.def file at compile time.
//
// Pattern:
//   1. dispatcher binary parses argv[1] as the subcommand name
//   2. find() the matching Entry
//   3. exec_leaf() to hand off to that leaf binary with the remaining args
//   4. on no-match / help-request, print_help() the registry

#pragma once

#include <string>
#include <vector>

namespace fox_common::dispatch {

struct Entry {
    std::string name;         // user-facing name ("ai", "doctor")
    std::string binary;       // leaf binary to exec ("fox-ai", "fox-ai-doctor")
    std::string description;  // one-line description for --help / help output
};

// Print the registry as an aligned `<name>  description` list to stdout.
// `title` is used as the header (e.g., "fox — namespaces" or "fox ai — subcommands").
void print_help(const std::string& title, const std::vector<Entry>& entries);

// Find an entry by name. Returns nullptr if not found.
const Entry* find(const std::vector<Entry>& entries, const std::string& name);

// Execute the leaf binary via execvp, replacing the current process.
// `args` is passed as argv to the child (args[0] should be the binary name).
// Returns only on error (e.g., binary not on $PATH). On success, never returns.
int exec_leaf(const std::string& binary, const std::vector<std::string>& args);

}  // namespace fox_common::dispatch
