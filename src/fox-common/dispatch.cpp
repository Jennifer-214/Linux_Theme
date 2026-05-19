#include "dispatch.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <unistd.h>

namespace fox_common::dispatch {

void print_help(const std::string& title, const std::vector<Entry>& entries) {
    std::cout << title << "\n\n";

    if (entries.empty()) {
        std::cout << "  (no entries registered yet)\n";
        return;
    }

    // Right-pad names to the longest, leave 2 spaces, then description.
    std::size_t name_width = 0;
    for (const auto& e : entries) {
        name_width = std::max(name_width, e.name.size());
    }

    for (const auto& e : entries) {
        std::cout << "  " << e.name;
        for (std::size_t i = e.name.size(); i < name_width; ++i) std::cout << ' ';
        std::cout << "  " << e.description << '\n';
    }
}

const Entry* find(const std::vector<Entry>& entries, const std::string& name) {
    for (const auto& e : entries) {
        if (e.name == name) return &e;
    }
    return nullptr;
}

int exec_leaf(const std::string& binary, const std::vector<std::string>& args) {
    // Build a vector of char* pointing into our std::string storage. argv
    // for execvp must be null-terminated, so we append nullptr at the end.
    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& a : args) {
        argv.push_back(const_cast<char*>(a.c_str()));
    }
    argv.push_back(nullptr);

    execvp(binary.c_str(), argv.data());

    // execvp returns only on failure.
    int err = errno;
    std::cerr << "fox: failed to exec '" << binary << "': "
              << std::strerror(err) << '\n';
    return 127;
}

}  // namespace fox_common::dispatch
