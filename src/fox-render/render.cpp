#include "render.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>
#include <unistd.h>
#include <sys/stat.h>

namespace fs = std::filesystem;

namespace fox_render {

std::string apply_substitutions(
    const std::string& src,
    const std::unordered_map<std::string, std::string>& table)
{
    std::string out;
    // Cap the reserve to avoid a wraparound on size_t near SIZE_MAX,
    // and avoid pessimistic over-allocation for huge templates.
    constexpr size_t MAX_RESERVE = static_cast<size_t>(256) << 20;  // 256 MiB
    size_t hint = src.size() + (src.size() >> 4);
    if (hint < src.size() || hint > MAX_RESERVE) hint = MAX_RESERVE;
    out.reserve(hint);

    const size_t n = src.size();
    size_t i = 0;
    while (i < n) {
        // Fast scan to the next `{{`.
        size_t open = src.find("{{", i);
        if (open == std::string::npos) {
            out.append(src, i, std::string::npos);
            break;
        }
        out.append(src, i, open - i);

        size_t close = src.find("}}", open + 2);
        if (close == std::string::npos) {
            // Unterminated marker — pass through verbatim.
            out.append(src, open, std::string::npos);
            break;
        }
        // Reject markers containing whitespace or another `{` (matches the
        // sed behaviour: only literal `{{IDENT}}` was a placeholder).
        bool ok = true;
        for (size_t k = open + 2; k < close; ++k) {
            char c = src[k];
            if (c == ' ' || c == '\t' || c == '\n' || c == '{') { ok = false; break; }
        }
        if (!ok) {
            // Emit only the first `{` and retry from the next char. Lets
            // overlapping cases like `%F{{{KEY}}}` resolve the inner
            // `{{KEY}}` exactly the way sed does.
            out.push_back(src[open]);
            i = open + 1;
            continue;
        }

        std::string key(src, open, close + 2 - open);
        auto it = table.find(key);
        if (it != table.end()) {
            out.append(it->second);
        } else {
            // Unknown placeholder → pass through unchanged (legacy parity).
            out.append(key);
        }
        i = close + 2;
    }
    return out;
}

namespace {

std::string slurp(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Atomic write: tmp file alongside dest, then rename. Preserves source mode.
bool atomic_write(const fs::path& dest, const std::string& body,
                  fs::perms src_perms) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);

    fs::path tmp = dest;
    tmp += ".foxren.tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(body.data(), static_cast<std::streamsize>(body.size()));
        if (!out) return false;
    }
    fs::permissions(tmp, src_perms, fs::perm_options::replace, ec);
    fs::rename(tmp, dest, ec);
    if (ec) {
        fs::remove(tmp, ec);
        return false;
    }
    return true;
}

void draw_progress(size_t done, size_t total) {
    if (total == 0) return;
    static const int width = 30;
    int pct = static_cast<int>((done * 100) / total);
    int filled = static_cast<int>((done * width) / total);
    std::string bar(filled, '#');
    bar.append(width - filled, '-');
    std::fprintf(stderr, "\r:: Rendering templates [%s] %3d%% (%zu/%zu)",
                 bar.c_str(), pct, done, total);
    std::fflush(stderr);
}

}  // namespace

size_t render_tree(
    const std::string& template_dir,
    const std::string& output_dir,
    const std::unordered_map<std::string, std::string>& table,
    bool show_progress)
{
    fs::path tdir(template_dir);
    fs::path odir(output_dir);

    // skip_permission_denied prevents bailout on an unreadable subdir.
    // We do NOT pass follow_directory_symlink, so a symlink loop in the
    // template tree can't trap us in an infinite walk.
    std::vector<fs::path> files;
    std::error_code walk_ec;
    auto opts = fs::directory_options::skip_permission_denied;
    for (auto it = fs::recursive_directory_iterator(tdir, opts, walk_ec);
         it != fs::recursive_directory_iterator(); it.increment(walk_ec)) {
        if (walk_ec) continue;
        if (it->is_symlink()) continue;            // never follow symlinks
        if (it->is_regular_file()) files.push_back(it->path());
    }
    if (files.empty()) return 0;

    const size_t total = files.size();
    std::atomic<size_t> done{0};
    std::mutex progress_mtx;

    auto worker = [&](size_t start, size_t step) {
        for (size_t i = start; i < total; i += step) {
            const fs::path& src = files[i];
            fs::path rel = fs::relative(src, tdir);
            fs::path dst = odir / rel;

            std::string body = slurp(src);
            std::string out  = apply_substitutions(body, table);
            std::error_code perm_ec;
            auto perms = fs::status(src, perm_ec).permissions();
            if (perm_ec) {
                // status() failed — don't fall through to umask-default
                // (which might produce 0644 / world-readable). Pick a
                // safe user-only mode and let downstream tools relax it
                // explicitly if they want broader access.
                perms = fs::perms::owner_read | fs::perms::owner_write;
            }
            atomic_write(dst, out, perms);

            size_t now = done.fetch_add(1, std::memory_order_relaxed) + 1;
            if (show_progress) {
                std::lock_guard<std::mutex> g(progress_mtx);
                draw_progress(now, total);
            }
        }
    };

    unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 4;
    if (hw > total) hw = static_cast<unsigned>(total);

    std::vector<std::future<void>> futs;
    futs.reserve(hw);
    for (unsigned t = 0; t < hw; ++t) {
        futs.push_back(std::async(std::launch::async, worker, t, hw));
    }
    for (auto& f : futs) f.get();
    if (show_progress) std::fputc('\n', stderr);

    return total;
}

}  // namespace fox_render
