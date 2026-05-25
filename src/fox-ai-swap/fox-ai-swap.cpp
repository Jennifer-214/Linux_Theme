// src/fox-ai-swap/fox-ai-swap.cpp — Unified AI model hotswapper.
//
// Detects hardware tier and updates ~/.config/opencode/opencode.json.
// Now with "Show All Models" and improved hardware detection.

#include "../fox-intel/json.hpp"
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <filesystem>
#include <cstdlib>
#include <algorithm>
#include <iomanip>
#include <fcntl.h>
#include <sys/wait.h>
#include <unistd.h>

using json = nlohmann::json;
namespace fs = std::filesystem;

struct ModelOption {
    std::string label;
    std::string tag;
};

// Hardware detection (matches fox-hw-info logic)
long read_ram_gb() {
    std::ifstream f("/proc/meminfo");
    std::string key;
    long kb = 0;
    while (f >> key) {
        if (key == "MemTotal:") { f >> kb; break; }
    }
    return (kb + 1024L * 1024L - 1) / (1024L * 1024L);
}

// nvidia-smi cold-start blocks 1-3s on Optimus laptops, which was the
// entire reason fox-ai-swap appeared to hang before the menu printed.
// Tier is computed from RAM only (line below); VRAM was display-only.
// Stub kept so the existing call sites still compile but never block.
int read_vram_gb() { return 0; }

void unload_model(const std::string& name) {
    if (name.empty() || name == "(unset)") return;
    // Background the stop — the user doesn't need to wait for the old
    // model's VRAM to drain before getting their prompt back. Ollama
    // handles the unload on its own time; the swap feels instant.
    // Fork+exec instead of system() so the model name never enters
    // shell parsing — names come from JSON config files which a user
    // could craft with shell metacharacters.
    pid_t pid = ::fork();
    if (pid == 0) {
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            ::dup2(devnull, STDOUT_FILENO);
            ::dup2(devnull, STDERR_FILENO);
            ::close(devnull);
        }
        ::execlp("ollama", "ollama", "stop", name.c_str(), nullptr);
        ::_exit(127);
    }
}

std::vector<std::string> get_installed_models() {
    std::vector<std::string> models;
    FILE* pipe = popen("ollama list 2>/dev/null", "r");
    if (!pipe) return models;
    char buffer[512];
    bool first = true;
    while (fgets(buffer, sizeof(buffer), pipe)) {
        if (first) { first = false; continue; } // skip header
        std::string line = buffer;
        auto space = line.find(' ');
        if (space != std::string::npos) {
            models.push_back(line.substr(0, space));
        }
    }
    pclose(pipe);
    return models;
}

void print_header() {
    std::cout << "\033[1;36m╭──────────────────────────────────────────────────╮\033[0m" << std::endl;
    std::cout << "\033[1;36m│          FoxML AI Model Switcher (C++)           │\033[0m" << std::endl;
    std::cout << "\033[1;36m╰──────────────────────────────────────────────────╯\033[0m" << std::endl;
}

int main(int argc, char** argv) {
    const char* home_env = std::getenv("HOME");
    if (!home_env) return 1;
    fs::path config_path = fs::path(home_env) / ".config/opencode/opencode.json";

    if (!fs::exists(config_path)) {
        std::cerr << "Error: OpenCode config not found at " << config_path << std::endl;
        return 1;
    }

    long ram = read_ram_gb();
    (void)read_vram_gb();  // stubbed — see top of file
    // Lite: < 16GB RAM
    // Standard: 16-32GB RAM
    // Pro: > 32GB RAM
    std::string tier = (ram > 32) ? "pro" : (ram >= 16) ? "standard" : "lite";

    json config;
    try { 
        std::ifstream f(config_path); 
        f >> config; 
    } catch (const std::exception& e) { 
        std::cerr << "Error parsing config: " << e.what() << std::endl;
        return 1; 
    }

    std::string current = config.value("model", "(unset)");
    if (current.find("ollama/") == 0) current = current.substr(7);

    if (argc > 1) {
        std::string target = argv[1];
        // If it looks like a size tag (e.g. 7b), expand it to the default qwen2.5-coder family
        if (target == "1.5b" || target == "3b" || target == "7b" || target == "14b" || target == "32b" || target == "70b") {
            target = "qwen2.5-coder:" + target;
        }
        
        // Ensure ollama/ prefix if no provider is specified
        // OpenCode requires provider/model-name. We only support ollama locally.
        if (target.find("ollama/") != 0 && target.find("hf.co/") != 0 && target.find("huggingface.co/") != 0) {
            target = "ollama/" + target;
        }
        
        config["model"] = target;
        std::ofstream o(config_path); o << config.dump(2);
        unload_model(current);
        std::cout << "\033[1;32m  + Global AI model switched to: " << target << "\033[0m" << std::endl;
        return 0;
    }

    print_header();
    std::cout << "Hardware: \033[1m" << ram << "GB RAM\033[0m (Tier: \033[1;33m" << tier << "\033[0m)" << std::endl;
    std::cout << "Current:  \033[1;32m" << current << "\033[0m\n" << std::endl;

    std::vector<ModelOption> tier_options;
    if (tier == "lite") {
        tier_options = {{"1.5b (Safe)", "qwen2.5-coder:1.5b"}, {"3b (Balanced)", "qwen2.5-coder:3b"}, {"7b (Heavy)", "qwen2.5-coder:7b"}};
    } else if (tier == "standard") {
        tier_options = {{"7b (Fast)", "qwen2.5-coder:7b"}, {"14b (Balanced)", "qwen2.5-coder:14b"}, {"32b (Expert)", "qwen2.5-coder:32b"}};
    } else {
        tier_options = {{"14b (Fast)", "qwen2.5-coder:14b"}, {"32b (Balanced)", "qwen2.5-coder:32b"}, {"70b (Expert)", "qwen2.5-coder:70b"}};
    }

    std::cout << "\033[1mTier Recommendations:\033[0m" << std::endl;
    for (size_t i = 0; i < tier_options.size(); ++i) {
        std::cout << "  [" << (i + 1) << "] " << std::left << std::setw(25) << tier_options[i].label << " (" << tier_options[i].tag << ")" << std::endl;
    }
    std::cout << "  [a] \033[3mShow all installed models\033[0m" << std::endl;
    std::cout << "  [m] \033[3mEnter model name manually\033[0m" << std::endl;
    std::cout << "\nChoice: ";

    std::string choice;
    if (!(std::cin >> choice)) return 0;

    std::string target_model;
    if (choice == "a" || choice == "A") {
        auto all = get_installed_models();
        if (all.empty()) {
            std::cout << "No models found. Pull some with 'ollama pull' first." << std::endl;
            return 0;
        }
        std::cout << "\n\033[1mInstalled Models:\033[0m" << std::endl;
        for (size_t i = 0; i < all.size(); ++i) {
            std::cout << "  [" << (i + 1) << "] " << all[i] << std::endl;
        }
        std::cout << "Choice: ";
        int idx; 
        if (std::cin >> idx && idx > 0 && idx <= (int)all.size()) {
            target_model = all[idx-1];
        }
    } else if (choice == "m" || choice == "M") {
        std::cout << "Enter model (e.g. llama3): ";
        std::cin >> target_model;
    } else {
        int idx = std::atoi(choice.c_str());
        if (idx > 0 && idx <= (int)tier_options.size()) {
            target_model = tier_options[idx-1].tag;
        }
    }

    if (!target_model.empty()) {
        if (target_model.find("ollama/") != 0 && target_model.find("hf.co/") != 0 && target_model.find("huggingface.co/") != 0) {
            target_model = "ollama/" + target_model;
        }
        config["model"] = target_model;
        std::ofstream o(config_path); o << config.dump(2);
        unload_model(current);
        std::cout << "\n\033[1;32m  + Global AI model switched to: " << target_model << "\033[0m" << std::endl;
    }

    return 0;
}
