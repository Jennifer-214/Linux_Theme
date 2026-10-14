// src/fox-ai-swap/fox-ai-swap.cpp — Unified AI model hotswapper.
//
// Detects hardware tier and updates ~/.config/opencode/opencode.json — the model opencode and the fox-ai
// tools use. Models are "provider/model" on the local server that runs them: llama.cpp's router (the
// default server) or Ollama, read from the lists fox-llm-update --sync keeps in that file.

#include "../fox-common/json.hpp"
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

// tmp + rename: opencode never reads a half-written config, and a failed
// write leaves the old one in place.
static bool save_config(const fs::path& path, const std::string& body) {
    fs::path tmp = path;
    tmp += ".swap-tmp";
    {
        std::ofstream o(tmp);
        o << body;
        o.close();
        if (!o) { std::error_code ec; fs::remove(tmp, ec); return false; }
    }
    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) { fs::remove(tmp, ec); return false; }
    return true;
}

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

// The local servers opencode knows, the default one first.
static const std::vector<std::string> LOCAL_PROVIDERS = {"llamacpp", "llamacpp-turbo", "ollama"};

// A router's root URL (its /models/unload lives beside /v1, not under it).
static std::string router_root(const json& config, const std::string& provider) {
    std::string base = provider == "llamacpp" ? "http://127.0.0.1:8080/v1" : "http://127.0.0.1:8081/v1";
    try { base = config.at("provider").at(provider).at("options").at("baseURL").get<std::string>(); } catch (...) {}
    while (!base.empty() && base.back() == '/') base.pop_back();
    if (base.size() >= 3 && base.compare(base.size() - 3, 3, "/v1") == 0) base.resize(base.size() - 3);
    return base;
}

// Free the old model's memory in the background — the user doesn't need to wait for it, the swap feels
// instant. A llama.cpp model is unloaded through its router (POST /models/unload), an Ollama one with
// `ollama stop`. Fork+exec instead of system() so the model name never enters shell parsing — names
// come from JSON config files which a user could craft with shell metacharacters.
void unload_model(const std::string& ref, const json& config) {
    auto slash = ref.find('/');
    if (slash == std::string::npos) return;
    std::string provider = ref.substr(0, slash), model = ref.substr(slash + 1);
    std::vector<std::string> argv;
    if (provider == "ollama") {
        argv = {"ollama", "stop", model};
    } else if (provider == "llamacpp" || provider == "llamacpp-turbo") {
        argv = {"curl", "-s", "-m", "10", "-X", "POST", router_root(config, provider) + "/models/unload",
                "-H", "Content-Type: application/json", "-d", json{{"model", model}}.dump()};
    } else {
        return;                                        // a cloud model: nothing local to free
    }
    pid_t pid = ::fork();
    if (pid == 0) {
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            ::dup2(devnull, STDOUT_FILENO);
            ::dup2(devnull, STDERR_FILENO);
            ::close(devnull);
        }
        std::vector<char*> args;
        for (auto& a : argv) args.push_back(a.data());
        args.push_back(nullptr);
        ::execvp(args[0], args.data());
        ::_exit(127);
    }
}

std::vector<std::string> ollama_list() {
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

// Every local model as "provider/model", llama.cpp's first — the lists fox-llm-update --sync keeps in
// opencode.json (each model once, under the server that runs it). No lists yet: what Ollama holds.
std::vector<std::string> local_models(const json& config) {
    std::vector<std::string> out;
    for (const auto& p : LOCAL_PROVIDERS) {
        try {
            for (const auto& el : config.at("provider").at(p).at("models").items()) out.push_back(p + "/" + el.key());
        } catch (...) {}
    }
    if (out.empty()) {
        for (const auto& m : ollama_list()) out.push_back("ollama/" + m);
    }
    return out;
}

// A name → "provider/name" on the local server that runs it (a bare "name" is "name:latest", as on
// Ollama). A name no local server lists keeps the old behaviour: Ollama, or a Hugging Face ref as is.
std::string qualify(const std::string& target, const std::vector<std::string>& local) {
    for (const auto& p : LOCAL_PROVIDERS) if (target.rfind(p + "/", 0) == 0) return target;
    for (const auto& ref : local) {
        std::string model = ref.substr(ref.find('/') + 1);
        if (model == target || model == target + ":latest") return ref;
    }
    if (target.rfind("hf.co/", 0) == 0 || target.rfind("huggingface.co/", 0) == 0) return target;
    return "ollama/" + target;
}

static std::string server_of(const std::string& ref) {
    if (ref.rfind("llamacpp-turbo/", 0) == 0) return "llama.cpp TurboQuant";
    if (ref.rfind("llamacpp/", 0) == 0) return "llama.cpp";
    if (ref.rfind("ollama/", 0) == 0) return "Ollama";
    return "?";
}

// Write the new default and free the old model's memory (unless it is the same one).
static int switch_to(const std::string& ref, const std::string& current, json& config, const fs::path& path,
                     const std::string& lead) {
    config["model"] = ref;
    if (!save_config(path, config.dump(2))) {
        std::cerr << "  ! could not write " << path << std::endl;
        return 1;
    }
    if (current != ref) unload_model(current, config);
    std::cout << lead << "\033[1;32m  + Global AI model switched to: " << ref << " (" << server_of(ref) << ")\033[0m" << std::endl;
    return 0;
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
    auto local = local_models(config);

    if (argc > 1) {
        std::string target = argv[1];
        // If it looks like a size tag (e.g. 7b), expand it to the default qwen2.5-coder family
        if (target == "1.5b" || target == "3b" || target == "7b" || target == "14b" || target == "32b" || target == "70b") {
            target = "qwen2.5-coder:" + target;
        }
        return switch_to(qualify(target, local), current, config, config_path, "");
    }

    print_header();
    std::cout << "Hardware: \033[1m" << ram << "GB RAM\033[0m (Tier: \033[1;33m" << tier << "\033[0m)" << std::endl;
    std::cout << "Current:  \033[1;32m" << current << "\033[0m (" << server_of(current) << ")\n" << std::endl;

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
        std::string ref = qualify(tier_options[i].tag, local);
        bool have = std::find(local.begin(), local.end(), ref) != local.end();
        std::cout << "  [" << (i + 1) << "] " << std::left << std::setw(25) << tier_options[i].label << " (" << tier_options[i].tag
                  << (have ? ", " + server_of(ref) : ", \033[2mnot installed\033[0m") << ")" << std::endl;
    }
    std::cout << "  [a] \033[3mShow all installed models\033[0m" << std::endl;
    std::cout << "  [m] \033[3mEnter model name manually\033[0m" << std::endl;
    std::cout << "\nChoice: ";

    std::string choice;
    if (!(std::cin >> choice)) return 0;

    std::string target_model;
    if (choice == "a" || choice == "A") {
        const auto& all = local;
        if (all.empty()) {
            std::cout << "No models found. Pull some with 'ollama pull' first." << std::endl;
            return 0;
        }
        std::cout << "\n\033[1mInstalled Models:\033[0m" << std::endl;
        for (size_t i = 0; i < all.size(); ++i) {
            std::cout << "  [" << (i + 1) << "] " << std::left << std::setw(48) << all[i].substr(all[i].find('/') + 1)
                      << "\033[2m" << server_of(all[i]) << "\033[0m" << std::endl;
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
        return switch_to(qualify(target_model, local), current, config, config_path, "\n");
    }

    return 0;
}
