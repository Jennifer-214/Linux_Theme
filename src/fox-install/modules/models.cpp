// modules/models.cpp — pull a tier-appropriate Ollama model stack.
//
// install.sh has its own bash hardware tiering in fox-hw-info; we
// inline a minimal RAM+VRAM tier picker here so the C++ orchestrator
// doesn't shell out to a bash helper. Logic intentionally matches
// install.sh's case "$TIER" block so users get the same model set.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <string>
#include <sys/statvfs.h>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

// MemTotal (KB) → GB, ceiling.
int read_ram_gb() {
    std::ifstream f("/proc/meminfo");
    std::string key;
    long kb = 0;
    while (f >> key) {
        if (key == "MemTotal:") { f >> kb; break; }
    }
    return static_cast<int>((kb + 1024L * 1024L - 1) / (1024L * 1024L));
}

// Best-effort: parse `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits`.
// Returns 0 when nvidia-smi isn't present (CPU-only / AMD / Intel).
int read_vram_gb() {
    std::string out;
    if (!sh::capture({"nvidia-smi", "--query-gpu=memory.total",
                      "--format=csv,noheader,nounits"}, out)) return 0;
    long mb = std::strtol(out.c_str(), nullptr, 10);
    return static_cast<int>((mb + 1023) / 1024);
}

const char* pick_tier(int ram_gb, int vram_gb) {
    // Same thresholds as install.sh / fox-hw-info.
    if (ram_gb >= 32 && vram_gb >= 16) return "pro";
    if (ram_gb >= 16 && vram_gb >= 8)  return "standard";
    return "lite";
}

std::vector<std::string> models_for(const std::string& tier) {
    if (tier == "lite") {
        return {"qwen2.5:3b", "qwen2.5-coder:1.5b",
                "qwen2.5-coder:3b", "qwen2.5-coder:7b"};
    }
    if (tier == "standard") {
        return {"qwen2.5:7b", "qwen2.5-coder:7b",
                "qwen2.5-coder:14b", "qwen2.5-coder:32b"};
    }
    return {"qwen2.5:14b", "qwen2.5-coder:14b", "qwen2.5-coder:32b"};
}

std::vector<std::string> discover_custom_models(const Context& ctx) {
    std::vector<std::string> out;
    std::vector<fs::path> candidates;

    // 1. ~/.config/foxml/models.private (one-off local overrides)
    candidates.push_back(ctx.config_home / "foxml" / "models.private");

    // 2. ~/code/*/foxml-models.txt (private repository discovery)
    fs::path code_dir = ctx.home / "code";
    std::error_code ec;
    if (fs::is_directory(code_dir, ec)) {
        for (const auto& entry : fs::directory_iterator(code_dir, ec)) {
            if (entry.is_directory()) {
                candidates.push_back(entry.path() / "foxml-models.txt");
            }
        }
    }

    // 3. ~/code/custom_models/*.txt (bulk model registration)
    fs::path custom_dir = code_dir / "custom_models";
    if (fs::is_directory(custom_dir, ec)) {
        for (const auto& entry : fs::directory_iterator(custom_dir, ec)) {
            if (entry.is_regular_file() && entry.path().extension() == ".txt") {
                candidates.push_back(entry.path());
            }
        }
    }

    for (const auto& p : candidates) {
        if (!fs::exists(p, ec)) continue;
        std::ifstream f(p);
        std::string line;
        while (std::getline(f, line)) {
            // Trim whitespace
            line.erase(0, line.find_first_not_of(" \t\r\n"));
            auto last = line.find_last_not_of(" \t\r\n");
            if (last != std::string::npos) line.erase(last + 1);

            if (line.empty() || line[0] == '#') continue;
            out.push_back(line);
        }
    }
    return out;
}

}  // namespace

// Returns $HOME free space in GB, or -1 if statvfs fails.
long home_free_gb(const Context& ctx) {
    struct statvfs vfs{};
    if (::statvfs(ctx.home.c_str(), &vfs) != 0) return -1;
    return static_cast<long>((vfs.f_bavail * vfs.f_bsize) / (1024L * 1024L * 1024L));
}

void run_models(Context& ctx) {
    ui::section("Pulling Ollama model stack");

    // Disk-space gate: bash auto-disabled --models when $HOME had less
    // than 25 GB free (qwen2.5-coder:32b alone is ~20 GB, plus the
    // chat sibling and intermediate sizes). Skip cleanly with a clear
    // message rather than letting `ollama pull` half-finish and leave
    // a partial model on disk.
    long free_gb = home_free_gb(ctx);
    if (free_gb >= 0 && free_gb < 25) {
        ui::warn("$HOME has only " + std::to_string(free_gb) +
                 " GB free — models module needs 25+ GB. Skipping.");
        ui::substep("free space then re-run: fox-install --only models");
        return;
    }

    int ram  = read_ram_gb();
    int vram = read_vram_gb();
    std::string tier = pick_tier(ram, vram);
    ui::ok("RAM: " + std::to_string(ram) + "GB, VRAM: " +
           std::to_string(vram) + "GB — tier: " + tier);

    auto models = models_for(tier);
    // Embedding model (mxbai-embed-large) is pulled by the `ai` module —
    // it's a hard dep of fox-intel / findex / fask, so it lives there
    // alongside Ollama itself rather than being duplicated here.
    auto custom = discover_custom_models(ctx);
    if (!custom.empty()) {
        ui::ok("discovered " + std::to_string(custom.size()) + " custom models");
        models.insert(models.end(), custom.begin(), custom.end());
    }

    // Uniquify
    std::sort(models.begin(), models.end());
    models.erase(std::unique(models.begin(), models.end()), models.end());

    for (const auto& m : models) {
        std::string target = m;
        // Fix common typos/aliases for known community "unlocked" models.
        if (target == "hermes-3:8b") target = "hermes3:8b";

        // Ollama strictly requires lowercase for model names/tags. Hugging Face
        // (hf.co/) paths are case-insensitive for the download, so we can
        // safely lowercase the entire string to satisfy Ollama's regex.
        std::string pull_target = target;
        std::transform(pull_target.begin(), pull_target.end(), pull_target.begin(),
                       [](unsigned char c){ return std::tolower(c); });

        bool has_namespace = (target.find('/') != std::string::npos);
        bool has_host = (target.find("hf.co/") == 0 || target.find("huggingface.co/") == 0);

        // Ollama's auth realm check rejects `hf.co/...` because the
        // manifest server redirects to `huggingface.co`. Use the long
        // form so the original host matches the auth realm.
        std::string hf_target;
        if (has_host) {
            hf_target = pull_target;
            if (hf_target.rfind("hf.co/", 0) == 0) {
                hf_target.replace(0, 6, "huggingface.co/");
            }
        } else if (has_namespace) {
            hf_target = "huggingface.co/" + pull_target;
        }

        bool success = false;
        std::string attempted;
        if (!has_namespace && !has_host) {
            attempted = pull_target;
            ui::substep("pulling " + attempted);
            if (sh::run({"ollama", "pull", attempted}) == 0) success = true;
        } else {
            attempted = hf_target;
            ui::substep("pulling from Hugging Face: " + attempted);
            if (sh::run({"ollama", "pull", attempted}) == 0) success = true;
        }

        if (!success) {
            ui::warn("pull failed: " + target +
                     " — retry with `ollama pull " + attempted + "`");
        }
    }
    ui::ok(std::to_string(models.size()) + " models requested");
}

}  // namespace fox_install
