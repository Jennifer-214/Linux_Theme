// modules/models.cpp — pull the RAM-tiered Ollama model stack.
//
// The list lives in shared/llm/core-models.txt, shared with fox-llm-update's
// daily refresh so first install and the timer pull the same set. Tier is
// RAM-only: the agent models are ~3B-active MoE that run on the CPU, so VRAM
// no longer gates them. Also installs fox-llm-update.timer.

#include "../core/context.hpp"
#include "../core/hardware.hpp"
#include "../core/idempotency.hpp"
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

const char* pick_tier(int ram_gb) {
    if (ram_gb >= 32) return "large";
    if (ram_gb >= 16) return "medium";
    return "small";
}

// Free space each tier needs before pulling (largest set + headroom).
long tier_min_free_gb(const std::string& tier) {
    if (tier == "large")  return 60;
    if (tier == "medium") return 30;
    return 15;
}

// Lines under "# tier: <tier>" and "# tier: all" in core-models.txt.
std::vector<std::string> models_for(const fs::path& list, const std::string& tier) {
    std::vector<std::string> out;
    std::ifstream f(list);
    std::string line, block;
    while (std::getline(f, line)) {
        line.erase(0, line.find_first_not_of(" \t\r\n"));
        auto last = line.find_last_not_of(" \t\r\n");
        if (last != std::string::npos) line.erase(last + 1);
        if (line.rfind("# tier:", 0) == 0) {
            block = line.substr(7);
            block.erase(0, block.find_first_not_of(' '));
            continue;
        }
        if (line.empty() || line[0] == '#') continue;
        if (block == tier || block == "all") out.push_back(line);
    }
    return out;
}

constexpr const char* UPDATE_SERVICE_BODY =
    "[Unit]\n"
    "Description=fox-llm-update — refresh local models, notify on tool updates\n"
    "After=network-online.target\n"
    "\n"
    "[Service]\n"
    "Type=oneshot\n"
    "ExecStart=%h/.local/bin/fox-llm-update --auto\n"
    "Nice=10\n"
    "IOSchedulingClass=idle\n";

constexpr const char* UPDATE_TIMER_BODY =
    "[Unit]\n"
    "Description=Run fox-llm-update daily (downloads wait for a fast network)\n"
    "\n"
    "[Timer]\n"
    "OnCalendar=daily\n"
    "RandomizedDelaySec=30min\n"
    "Persistent=true\n"
    "\n"
    "[Install]\n"
    "WantedBy=timers.target\n";

void install_update_timer(const Context& ctx) {
    fs::path dir = ctx.config_home / "systemd/user";
    if (!idem::write_atomic(dir / "fox-llm-update.service", UPDATE_SERVICE_BODY) ||
        !idem::write_atomic(dir / "fox-llm-update.timer", UPDATE_TIMER_BODY)) {
        ui::warn("could not write fox-llm-update units under " + dir.string());
        return;
    }
    sh::run({"systemctl", "--user", "daemon-reload"});
    if (sh::run({"systemctl", "--user", "enable", "--now", "fox-llm-update.timer"}) == 0) {
        ui::ok("fox-llm-update.timer enabled (daily model refresh + update notices)");
    } else {
        ui::warn("could not enable fox-llm-update.timer via systemctl --user");
    }
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
    int ram  = hw::ram_gb();
    std::string tier = pick_tier(ram);
    ui::ok("RAM: " + std::to_string(ram) + "GB, VRAM: " +
           std::to_string(hw::vram_gb()) + "GB — tier: " + tier);

    long free_gb = home_free_gb(ctx);
    long need_gb = tier_min_free_gb(tier);
    if (free_gb >= 0 && free_gb < need_gb) {
        ui::warn("$HOME has only " + std::to_string(free_gb) + " GB free — the " + tier +
                 " tier needs " + std::to_string(need_gb) + "+ GB. Skipping.");
        ui::substep("free space then re-run: fox-install --only models");
        return;
    }

    fs::path list = ctx.shared_dir / "llm/core-models.txt";
    auto models = models_for(list, tier);
    if (models.empty()) ui::warn("no models read from " + list.string());
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
        if (has_host) {
            attempted = hf_target;
            ui::substep("pulling from Hugging Face: " + attempted);
            if (sh::run({"ollama", "pull", attempted}) == 0) success = true;
        } else {
            attempted = pull_target;
            ui::substep("pulling " + attempted);
            if (sh::run({"ollama", "pull", attempted}) == 0) success = true;
            // A namespaced ref is usually a community model on the Ollama registry
            // (huihui_ai/…); only when the registry has no such model is it tried
            // as a Hugging Face GGUF repo.
            if (!success && has_namespace) {
                attempted = hf_target;
                ui::substep("not on the Ollama registry — trying Hugging Face: " + attempted);
                if (sh::run({"ollama", "pull", attempted}) == 0) success = true;
            }
        }

        if (!success) {
            ui::warn("pull failed: " + target +
                     " — retry with `ollama pull " + attempted + "`");
        }
    }
    ui::ok(std::to_string(models.size()) + " models requested");

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write + enable fox-llm-update.{service,timer}");
        return;
    }
    install_update_timer(ctx);
}

}  // namespace fox_install
