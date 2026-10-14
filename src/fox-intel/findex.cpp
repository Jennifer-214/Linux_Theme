// findex — build a chunked semantic index of the current directory.
//
// Schema (per row, written as .foxml_index.json array):
//   {path, chunk_id, line_start, line_end, vector, mtime, model}
//
// Chunks are chunk_lines long with overlap_lines overlap so a function
// straddling a chunk boundary still appears whole in at least one chunk.
// The model name is stored alongside each vector — re-running findex
// after the embedding model changes (or after the schema changed)
// triggers a full rebuild instead of mixing incompatible vectors.

#include "fox_intel.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <future>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr long MAX_FILE_BYTES = 2L * 1024 * 1024;  // skip > 2 MB

// Extensions worth embedding. Add freely; cost is per-file.
const std::set<std::string> EXTENSIONS = {
    ".md", ".sh", ".bash", ".zsh", ".conf", ".cfg", ".ini",
    ".lua", ".css", ".json", ".yaml", ".yml", ".toml",
    ".cpp", ".cc", ".cxx", ".c", ".h", ".hpp", ".hh",
    ".py", ".rs", ".go", ".ts", ".tsx", ".js", ".jsx",
    ".txt", ".sql", ".proto"
};

// Path fragments that always indicate generated / vendored / build output.
bool is_excluded(const std::string& path) {
    static const std::vector<std::string> patterns = {
        "/.git/", "/.hg/", "/.svn/",
        "/build/", "/target/", "/dist/", "/out/",
        "/node_modules/", "/.venv/", "/venv/", "/__pycache__/",
        "/.cache/", "/.cargo/", "/rendered/", "/distro/",
        "json.hpp", ".foxml_index.json"
    };
    for (const auto& p : patterns) {
        if (path.find(p) != std::string::npos) return true;
    }
    // Hidden files at top level (./.something) but allow nested .config etc.
    if (path.size() >= 3 && path[0] == '.' && path[1] == '/' && path[2] == '.') return true;
    return false;
}

struct Chunk {
    std::string path;
    int chunk_id;
    int line_start;
    int line_end;
    long long mtime;
    std::string text;  // populated lazily; not stored in index
};

std::vector<Chunk> chunk_file(const std::string& path, long long mtime, int chunk_lines, int overlap_lines) {
    std::vector<Chunk> chunks;
    std::ifstream f(path);
    if (!f) return chunks;

    std::vector<std::string> buffer;
    std::string line;
    int line_no = 0;
    int chunk_start_line = 1;
    int chunk_id = 0;

    auto flush = [&](bool final) {
        if (buffer.empty()) return;
        std::ostringstream joined;
        for (const auto& l : buffer) joined << l << '\n';
        chunks.push_back({path, chunk_id++, chunk_start_line, line_no,
                          mtime, joined.str()});
        if (!final && (int)buffer.size() > overlap_lines) {
            // Keep last overlap_lines for the next chunk.
            buffer.erase(buffer.begin(), buffer.end() - overlap_lines);
            chunk_start_line = line_no - overlap_lines + 1;
        } else {
            buffer.clear();
        }
    };

    while (std::getline(f, line)) {
        ++line_no;
        buffer.push_back(line);
        if ((int)buffer.size() >= chunk_lines) flush(false);
    }
    flush(true);
    return chunks;
}

struct CacheKey {
    std::string path;
    int chunk_id;
    bool operator<(const CacheKey& o) const {
        if (path != o.path) return path < o.path;
        return chunk_id < o.chunk_id;
    }
};

void show_help(const std::string& accent, const std::string& reset) {
    std::cout << accent << "findex" << reset << " — Build a semantic index of your project\n\n"
              << "Usage: findex [options]\n\n"
              << "Options:\n"
              << "  -s, --size <int>      Lines per chunk (default: 100)\n"
              << "  -o, --overlap <int>   Line overlap between chunks (default: 10)\n"
              << "  -t, --threads <int>   Max worker threads (default: 8)\n"
              << "  -m, --model <string>  Embedding model (default: mxbai-embed-large)\n"
              << "  -h, --help            Show this help\n\n"
              << "Fine-Tuning Tips:\n"
              << "  • " << accent << "Granularity:" << reset << " Smaller sizes (30-50) are best for finding specific functions\n"
              << "    or variables. Larger sizes (150-200) preserve more context for logic flow.\n"
              << "  • " << accent << "Overlap:" << reset << " Keep at ~10-20% of your chunk size. This ensures logic\n"
              << "    spanning across a chunk boundary is still captured as a whole unit.\n"
              << "  • " << accent << "Models:" << reset << " 'mxbai-embed-large' is state-of-the-art for retrieval.\n"
              << "    'nomic-embed-text' is faster and works well for simple keyword-like lookup.\n"
              << "  • " << accent << "Rebuilding:" << reset << " Re-running with a different model triggers a full rebuild.\n"
              << "    Incremental updates (mtime-based) are used if the model remains the same.\n";
}

}  // namespace

int main(int argc, char* argv[]) {
    int chunk_lines = 100;
    int overlap_lines = 10;
    int max_threads = 8;
    std::string model = "mxbai-embed-large";

    FoxIntel intel;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-h" || arg == "--help") {
            show_help(intel.color_accent(), intel.color_reset());
            return 0;
        } else if ((arg == "-s" || arg == "--size") && i + 1 < argc) {
            chunk_lines = std::stoi(argv[++i]);
        } else if ((arg == "-o" || arg == "--overlap") && i + 1 < argc) {
            overlap_lines = std::stoi(argv[++i]);
        } else if ((arg == "-t" || arg == "--threads") && i + 1 < argc) {
            max_threads = std::stoi(argv[++i]);
        } else if ((arg == "-m" || arg == "--model") && i + 1 < argc) {
            model = argv[++i];
        } else {
            std::cerr << "Unknown option: " << arg << "\nUse --help for usage.\n";
            return 1;
        }
    }

    auto t0 = std::chrono::steady_clock::now();
    if (!intel.ensure_server_running()) return 1;
    if (!intel.ensure_model_present(model)) {
        std::cerr << "Embed model '" << model
                  << "' is not downloaded yet.\n";
        return 1;
    }

    // Load existing index — but only entries that match the current model.
    // Any mismatch (old schema, old model) is treated as cache-miss.
    std::map<CacheKey, json> cache;
    std::ifstream f_in(".foxml_index.json");
    if (f_in.is_open()) {
        try {
            json old = json::parse(f_in);
            for (auto& e : old) {
                if (!e.contains("model") || e["model"] != model) continue;
                if (!e.contains("chunk_id")) continue;
                cache[{e["path"], e["chunk_id"]}] = e;
            }
        } catch (...) {}
        std::cout << "Reusing " << cache.size() << " cached embeddings\n";
    }

    std::cout << "Indexing " << fs::current_path() << " ("
              << model << ", " << chunk_lines << "-line chunks, "
              << overlap_lines << "-line overlap)\n";

    std::vector<Chunk> tasks;
    int files_seen = 0, files_skipped_size = 0, files_indexed = 0;

    for (const auto& entry : fs::recursive_directory_iterator(
             ".", fs::directory_options::skip_permission_denied)) {
        if (!entry.is_regular_file()) continue;
        std::string path = entry.path().string();
        if (is_excluded(path)) continue;
        if (!EXTENSIONS.count(entry.path().extension().string())) continue;

        ++files_seen;
        std::error_code ec;
        auto sz = fs::file_size(entry.path(), ec);
        if (!ec && (long)sz > MAX_FILE_BYTES) { ++files_skipped_size; continue; }
        if (!ec && sz == 0) continue;

        long long mtime = std::chrono::duration_cast<std::chrono::seconds>(
            entry.last_write_time().time_since_epoch()).count();

        auto chunks = chunk_file(path, mtime, chunk_lines, overlap_lines);
        for (auto& c : chunks) tasks.push_back(std::move(c));
        if (!chunks.empty()) ++files_indexed;
    }

    std::cout << "Files: " << files_seen << " seen, " << files_indexed
              << " indexable, " << files_skipped_size << " skipped (>2MB), "
              << tasks.size() << " chunks total\n";

    // Worker pool: bounded async fan-out.
    std::mutex out_mu;
    json new_index = json::array();
    std::vector<std::future<void>> workers;
    std::atomic<int> done{0}, hit{0}, miss{0};

    auto submit = [&](const Chunk& c) {
        workers.push_back(std::async(std::launch::async, [&, c, model]() {
            // Cache hit: mtime + chunk_id match → reuse vector.
            auto it = cache.find({c.path, c.chunk_id});
            if (it != cache.end() && it->second["mtime"] == c.mtime &&
                it->second["line_start"] == c.line_start &&
                it->second["line_end"]   == c.line_end) {
                std::lock_guard<std::mutex> lk(out_mu);
                new_index.push_back(it->second);
                ++hit; ++done;
                return;
            }
            auto vec = intel.get_embedding(c.text, model);
            if (!vec.empty()) {
                std::lock_guard<std::mutex> lk(out_mu);
                new_index.push_back({
                    {"path",       c.path},
                    {"chunk_id",   c.chunk_id},
                    {"line_start", c.line_start},
                    {"line_end",   c.line_end},
                    {"mtime",      c.mtime},
                    {"model",      model},
                    {"vector",     vec},
                });
            }
            ++miss; ++done;
        }));
    };

    auto drain_one = [&]() {
        workers.front().wait();
        workers.erase(workers.begin());
    };

    int progress_total = tasks.size();
    auto print_progress = [&](int current) {
        int pct = (int)(current * 100 / std::max(1, progress_total));
        std::cout << "\r  " << pct << "% (" << done.load() << "/"
                  << progress_total << "  hit=" << hit.load()
                  << " miss=" << miss.load() << ")" << std::flush;
    };

    for (size_t i = 0; i < tasks.size(); ++i) {
        if ((int)workers.size() >= max_threads) {
            drain_one();
            print_progress(done.load());
        }
        submit(tasks[i]);
    }
    while (!workers.empty()) {
        drain_one();
        print_progress(done.load());
    }
    std::cout << "\n";

    std::ofstream out(".foxml_index.json");
    out << new_index.dump() << '\n';

    auto t1 = std::chrono::steady_clock::now();
    auto secs = std::chrono::duration_cast<std::chrono::seconds>(t1 - t0).count();
    std::cout << "Done in " << secs << "s\n";
    return 0;
}
