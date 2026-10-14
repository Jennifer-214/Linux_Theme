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
    // model: "" picks it as fox-llm-run does — FOXAI_MODEL, fox-ai-default's (ai-model.conf), opencode's
    // local default, else the roles file's quick model.
    FoxIntel(std::string model = "");
    ~FoxIntel();

    // Core LLM interaction
    std::string ask(const std::string& prompt, bool stream = false);
    
    // Embedding generation (uses model name, defaults to mxbai-embed-large). Text longer than the
    // model takes is cut to its first tokens plus its end token.
    std::vector<float> get_embedding(const std::string& text, const std::string& model = "");
    
    // Similarity calculation
    static double cosine_similarity(const std::vector<float>& v1, const std::vector<float>& v2);

    // Server state: wakes llama.cpp's router (a user service, no sudo) and waits until it answers;
    // is the model served (downloaded)? Each says why when not.
    bool ensure_server_running();
    bool ensure_model_present(const std::string& model_name);

    // Color helpers
    std::string color_accent();
    std::string color_dim();
    std::string color_reset();

private:
    std::string default_model;
    std::string accent_color;
    // The OpenAI-compatible base URL of the llama.cpp router serving the model (fox-llm-serve: the main
    // one on :8080, the TurboQuant one on :8081), and its user unit.
    std::string api_base = "http://127.0.0.1:8080/v1";
    std::string router_unit = "fox-llm-server";
    // Embeddings: the main router, which serves the embedding models.
    std::string embed_base = "http://127.0.0.1:8080/v1";

    std::vector<float> embed_llama(const std::string& text, const std::string& model);

    bool use_model(std::string ref, const json* opencode);
    std::string ask_openai(const std::string& prompt, bool stream);

    static size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* userp);
    static size_t SseCallback(void* contents, size_t size, size_t nmemb, void* userp);
};

// Utilities for safe process execution (no shell)
namespace FoxUtils {
    int run_cmd(std::initializer_list<const char*> argv, bool silent = false);
}

#endif
