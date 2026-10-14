// fask — semantic Q&A over the .foxml_index.json chunk index.
//
//   fask "where is the per-core risk seqlock built"
//
// Loads the chunked index, cosine-ranks chunks against the query
// embedding, opens each top-K file and reads only that chunk's line
// range (not the whole file or a prefix), concats into a context
// block, and streams the model's answer.

#include "fox_intel.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int TOP_K = 8;
constexpr int MAX_CONTEXT_BYTES = 24000;  // safety bound on prompt size

// Read lines [from, to] (1-based inclusive) of path. Returns "" on miss.
std::string read_range(const std::string& path, int from, int to) {
    std::ifstream f(path);
    if (!f) return "";
    std::string line;
    std::ostringstream out;
    int n = 0;
    while (std::getline(f, line)) {
        ++n;
        if (n >= from && n <= to) out << line << '\n';
        if (n > to) break;
    }
    return out.str();
}

}  // namespace

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "usage: fask \"question\"\n";
        return 1;
    }
    std::string query = argv[1];
    for (int i = 2; i < argc; ++i) { query += ' '; query += argv[i]; }

    FoxIntel intel;
    if (!intel.ensure_server_running()) return 1;

    std::filesystem::path idx_dir = std::filesystem::current_path();
    bool found = false;
    while (true) {
        if (std::filesystem::exists(idx_dir / ".foxml_index.json")) {
            found = true;
            break;
        }
        if (idx_dir == idx_dir.root_path()) break;
        idx_dir = idx_dir.parent_path();
    }

    if (!found) {
        std::cerr << "Index not found in current or parent directories. Run 'findex' first.\n";
        return 1;
    }

    // Paths in the index are relative to the directory where findex was run.
    std::filesystem::current_path(idx_dir);
    std::ifstream f_in(".foxml_index.json");
    if (!f_in) {
        std::cerr << "Failed to open .foxml_index.json\n";
        return 1;
    }
    json idx;
    try { idx = json::parse(f_in); }
    catch (...) { std::cerr << "Index file is corrupt.\n"; return 1; }

    if (!idx.is_array() || idx.empty()) {
        std::cerr << "Index is empty. Run 'findex' first.\n";
        return 1;
    }

    std::string model = "mxbai-embed-large";
    if (idx[0].contains("model")) {
        model = idx[0]["model"].get<std::string>();
    }

    auto qvec = intel.get_embedding(query, model);
    if (qvec.empty()) { std::cerr << "Embedding failed.\n"; return 1; }

    struct Match {
        std::string path;
        int line_start, line_end;
        double score;
    };
    std::vector<Match> matches;
    matches.reserve(idx.size());
    for (auto& e : idx) {
        if (!e.contains("vector") || !e.contains("line_start")) continue;
        double s = FoxIntel::cosine_similarity(
            qvec, e["vector"].get<std::vector<float>>());
        matches.push_back({e["path"], e["line_start"], e["line_end"], s});
    }
    std::sort(matches.begin(), matches.end(),
              [](const Match& a, const Match& b) { return a.score > b.score; });

    std::string context = "Context from the project:\n";
    int included = 0;
    for (const auto& m : matches) {
        if (included >= TOP_K) break;
        std::string chunk = read_range(m.path, m.line_start, m.line_end);
        if (chunk.empty()) continue;
        std::ostringstream hdr;
        hdr << "--- " << m.path << " (lines " << m.line_start << "-"
            << m.line_end << "; score=" << m.score << ") ---\n";
        if ((int)(context.size() + hdr.str().size() + chunk.size())
            > MAX_CONTEXT_BYTES) break;
        context += hdr.str();
        context += chunk;
        context += "\n";
        ++included;
    }

    std::string prompt = context + "\nQuestion: " + query + "\nAnswer:";
    std::cout << intel.color_accent() << "[Thinking...]"
              << intel.color_reset() << std::endl;
    intel.ask(prompt, true);
    std::cout << std::endl;
    return 0;
}
