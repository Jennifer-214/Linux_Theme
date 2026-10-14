// fox-ask — one-shot terminal Q&A with the local model.
//
//   fox-ask "what's the syntax for a bash trap"
//   fox-ask explain rcu in one paragraph
//   echo "..." | fox-ask              # reads stdin if no args
//
// Streams the answer to stdout. Model comes from FoxIntel's resolution
// chain (FOXAI_MODEL env > opencode.json > foxml/ai-model.conf).

#include "../fox-intel/fox_intel.hpp"

#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>

int main(int argc, char* argv[]) {
    std::string prompt;
    for (int i = 1; i < argc; ++i) {
        if (i > 1) prompt += ' ';
        prompt += argv[i];
    }
    if (prompt.empty() && !isatty(STDIN_FILENO)) {
        std::stringstream ss;
        ss << std::cin.rdbuf();
        prompt = ss.str();
    }
    if (prompt.empty()) {
        std::cerr << "usage: fox-ask \"<question>\"   (or pipe via stdin)\n";
        return 1;
    }

    FoxIntel intel;
    if (!intel.ensure_server_running()) return 1;

    std::cout << intel.color_accent() << "[Thinking...]" << intel.color_reset() << std::endl;
    intel.ask(prompt, true);
    std::cout << std::endl;
    return 0;
}
