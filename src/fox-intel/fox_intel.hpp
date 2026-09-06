#ifndef FOX_INTEL_HPP
#define FOX_INTEL_HPP

#include <string>
#include <vector>
#include "../fox-common/json.hpp"
#include <curl/curl.h>
#include <mutex>

using json = nlohmann::json;

class FoxIntel {
public:
    FoxIntel(std::string model = "qwen2.5-coder:7b");
    ~FoxIntel();

    // Core LLM interaction
    std::string ask(const std::string& prompt, bool stream = false);
    
    // Embedding generation (uses model name, defaults to mxbai-embed-large)
    std::vector<float> get_embedding(const std::string& text, const std::string& model = "");
    
    // Similarity calculation
    static double cosine_similarity(const std::vector<float>& v1, const std::vector<float>& v2);

    // Ollama state management
    bool ensure_ollama_running();
    bool ensure_model_present(const std::string& model_name);

    // Color helpers
    std::string color_accent();
    std::string color_dim();
    std::string color_reset();

private:
    std::string default_model;
    std::string accent_color;

    static size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* userp);
    static size_t StreamCallback(void* contents, size_t size, size_t nmemb, void* userp);
};

// Utilities for safe process execution (no shell)
namespace FoxUtils {
    int run_cmd(std::initializer_list<const char*> argv, bool silent = false);
    bool has_model(const char* pattern);
}

#endif
