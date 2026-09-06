#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include "../fox-common/json.hpp"

using json = nlohmann::json;

// Fast Pango escaping in C++
std::string pango_escape(const std::string& data) {
    std::string buffer;
    buffer.reserve(data.size());
    for (size_t pos = 0; pos != data.size(); ++pos) {
        switch (data[pos]) {
            case '&':  buffer.append("&amp;");       break;
            case '\"': buffer.append("&quot;");      break;
            case '\'': buffer.append("&apos;");      break;
            case '<':  buffer.append("&lt;");        break;
            case '>':  buffer.append("&gt;");        break;
            default:   buffer.append(1, data[pos]); break;
        }
    }
    return buffer;
}

int main(int argc, char** argv) {
    std::ios_base::sync_with_stdio(false);
    std::cin.tie(NULL);

    if (argc < 2) {
        std::cerr << "Usage: fox-agent-parse <jsonl_file>\n";
        return 1;
    }

    std::ifstream file(argv[1]);
    if (!file) {
        return 0;
    }

    std::string line;
    while (std::getline(file, line)) {
        if (line.empty()) {
            std::cout << "\t\t\t\t\n";
            continue;
        }
        try {
            auto j = json::parse(line);
            // Output tab-separated ESCAPED values
            std::cout << pango_escape(j.value("source", "")) << '\t'
                      << pango_escape(j.value("event", "")) << '\t'
                      << pango_escape(j.value("project", "?")) << '\t'
                      << pango_escape(j.value("tmux", "")) << '\t'
                      << pango_escape(j.value("message", "")) << '\n';
        } catch (...) {
            std::cout << "\t\t\t\t\n";
        }
    }

    return 0;
}