#include "fox_intel.hpp"
#include <iostream>
#include <fstream>
#include <cmath>
#include <algorithm>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <chrono>
#include <fcntl.h>
#include <atomic>
#include <map>

static int g_curl_ref_count = 0;
static std::mutex g_curl_ref_mu;

FoxIntel::FoxIntel(std::string model) : default_model(model), accent_color("\033[1;32m") {
    const char* home = std::getenv("HOME");
    std::string home_str = home ? home : "";

    // 1. Load active AI model
    json opencode;
    if (!home_str.empty()) {
        std::ifstream f_opencode(home_str + "/.config/opencode/opencode.json");
        if (f_opencode.is_open()) {
            try { f_opencode >> opencode; } catch (...) { opencode = json(); }
        }
    }
    if (const char* env = std::getenv("FOXAI_MODEL"); env && *env) {
        if (!use_model(env, &opencode)) default_model = env;      // a bare name: Ollama's
    } else if (!home_str.empty()) {
        bool found = opencode.is_object() && opencode.contains("model") && opencode["model"].is_string()
                     && use_model(opencode["model"].get<std::string>(), &opencode);
        if (!found) {
            std::ifstream f_legacy(home_str + "/.config/foxml/ai-model.conf");
            std::string line;
            while (std::getline(f_legacy, line)) {
                if (line.empty() || line[0] == '#') continue;
                auto eq = line.find('=');
                if (eq == std::string::npos) continue;
                if (line.substr(0, eq) != "MODEL") continue;
                std::string v = line.substr(eq + 1);
                while (!v.empty() && (v.front() == ' '  || v.front() == '\t' ||
                                      v.front() == '"'  || v.front() == '\'')) v.erase(0, 1);
                while (!v.empty() && (v.back()  == ' '  || v.back()  == '\t' ||
                                      v.back()  == '\r' || v.back()  == '\n' ||
                                      v.back()  == '"'  || v.back()  == '\'')) v.pop_back();
                if (!v.empty()) { default_model = v; break; }
            }
        }
    }

    // 1b. Embeddings: the router while it serves models (opencode's `llamacpp` list isn't empty), else Ollama.
    try {
        const auto& lp = opencode.at("provider").at("llamacpp");
        if (lp.at("models").is_object() && !lp.at("models").empty()) {
            embed_base = "http://127.0.0.1:8080/v1";
            try { embed_base = lp.at("options").at("baseURL").get<std::string>(); } catch (...) {}
            while (!embed_base.empty() && embed_base.back() == '/') embed_base.pop_back();
        }
    } catch (...) {}

    // 2. Load theme colors
    if (!home_str.empty()) {
        std::ifstream f_colors(home_str + "/.config/foxml/ansi_colors.json");
        if (f_colors.is_open()) {
            try {
                json colors;
                f_colors >> colors;
                if (colors.contains("accent1")) {
                    accent_color = "\033[38;5;" + colors["accent1"].get<std::string>() + "m";
                }
            } catch (...) {}
        }
    }

    std::lock_guard<std::mutex> lk(g_curl_ref_mu);
    if (g_curl_ref_count == 0) curl_global_init(CURL_GLOBAL_DEFAULT);
    g_curl_ref_count++;
}

FoxIntel::~FoxIntel() {
    std::lock_guard<std::mutex> lk(g_curl_ref_mu);
    g_curl_ref_count--;
    if (g_curl_ref_count == 0) curl_global_cleanup();
}

// "<provider>/<model>" as opencode writes it. `ollama/…` → Ollama's own API; `llamacpp/…` and
// `llamacpp-turbo/…` → that llama.cpp router, OpenAI-style, at the baseURL opencode has for it
// (fox-llm-update --sync writes both). Anything else is a cloud model fox-ai can't run locally:
// false, and the next source decides.
bool FoxIntel::use_model(std::string ref, const json* opencode) {
    auto slash = ref.find('/');
    if (slash == std::string::npos) return false;
    std::string provider = ref.substr(0, slash), model = ref.substr(slash + 1);
    if (model.empty()) return false;
    if (provider == "ollama") {
        api_base.clear();
    } else if (provider == "llamacpp" || provider == "llamacpp-turbo") {
        api_base = provider == "llamacpp" ? "http://127.0.0.1:8080/v1" : "http://127.0.0.1:8081/v1";
        try {
            api_base = opencode->at("provider").at(provider).at("options").at("baseURL").get<std::string>();
        } catch (...) {}
        while (!api_base.empty() && api_base.back() == '/') api_base.pop_back();
    } else {
        return false;
    }
    default_model = model;
    return true;
}

std::string FoxIntel::color_accent() { return accent_color; }
std::string FoxIntel::color_dim() { return "\033[2m"; }
std::string FoxIntel::color_reset() { return "\033[0m"; }

size_t FoxIntel::WriteCallback(void* contents, size_t size, size_t nmemb, std::string* userp) {
    userp->append((char*)contents, size * nmemb);
    return size * nmemb;
}

size_t FoxIntel::StreamCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    std::string chunk((char*)contents, size * nmemb);
    try {
        auto j = json::parse(chunk);
        if (j.contains("response")) {
            std::cout << j["response"].get<std::string>() << std::flush;
        }
    } catch (...) {}
    return size * nmemb;
}

// One server-sent-events line from an OpenAI-style stream: print the answer's next piece. A thinking
// model's reasoning (delta.reasoning_content) is not printed. A line that isn't an event is the
// server's error body (HTTP 4xx/5xx) — say so instead of printing nothing.
static void print_sse_line(std::string line) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) return;
    if (line.rfind("data:", 0) != 0) {
        try {
            auto j = json::parse(line);
            if (j.contains("error")) {
                const auto& e = j["error"];
                std::cerr << "fox-intel: " << (e.is_object() && e.contains("message") ? e["message"].get<std::string>()
                                                                                   : e.dump()) << std::endl;
            }
        } catch (...) {}
        return;
    }
    std::string payload = line.substr(5);
    if (!payload.empty() && payload[0] == ' ') payload.erase(0, 1);
    if (payload == "[DONE]") return;
    try {
        auto j = json::parse(payload);
        if (!j.contains("choices") || j["choices"].empty()) return;
        const auto& delta = j["choices"][0]["delta"];
        if (delta.contains("content") && delta["content"].is_string())
            std::cout << delta["content"].get<std::string>() << std::flush;
    } catch (...) {}
}

// A network chunk can end mid-line: keep the tail until its newline arrives.
size_t FoxIntel::SseCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    auto* pending = static_cast<std::string*>(userp);
    pending->append(static_cast<char*>(contents), size * nmemb);
    for (size_t nl; (nl = pending->find('\n')) != std::string::npos; ) {
        print_sse_line(pending->substr(0, nl));
        pending->erase(0, nl + 1);
    }
    return size * nmemb;
}

// POST a JSON body; the response body lands in `out`. Returns the HTTP status, or -1 when the request
// never got an answer.
static long post_json(const std::string& url, const json& body, std::string& out) {
    CURL* curl = curl_easy_init();
    if (!curl) return -1;
    std::string json_str = body.dump();
    struct curl_slist* headers = curl_slist_append(NULL, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_str.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION,
                     +[](void* p, size_t s, size_t n, std::string* o) { o->append((char*)p, s * n); return s * n; });
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &out);
    long code = -1;
    if (curl_easy_perform(curl) == CURLE_OK) curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return code;
}

// One complaint per process: findex embeds hundreds of chunks, and a broken server would say so each time.
static void embed_failed(const std::string& why) {
    static std::atomic<bool> said{false};
    if (!said.exchange(true)) std::cerr << "fox-intel: embeddings failed: " << why << std::endl;
}

// Most tokens a model embeds at once, learned from the router's "too large … batch size: N" answer —
// shared by findex's parallel workers.
static std::mutex g_limit_mu;
static std::map<std::string, int> g_embed_limit;

std::vector<float> FoxIntel::get_embedding(const std::string& text, const std::string& model) {
    std::string model_name = model.empty() ? "mxbai-embed-large" : model;
    return embed_base.empty() ? embed_ollama(text, model_name) : embed_llama(text, model_name);
}

// Ollama's /api/embed, which cuts text longer than the model takes (the old /api/embeddings returns
// "input length exceeds the context length" instead — since Ollama 0.40, findex lost every long chunk).
std::vector<float> FoxIntel::embed_ollama(const std::string& text, const std::string& model) {
    std::string out;
    long code = post_json("http://localhost:11434/api/embed", {{"model", model}, {"input", text}}, out);
    try {
        auto j = json::parse(out);
        if (code == 200) return j.at("embeddings").at(0).get<std::vector<float>>();
        embed_failed(j.value("error", out));
    } catch (...) { embed_failed(code < 0 ? "Ollama did not answer" : out.substr(0, 200)); }
    return {};
}

// The llama.cpp router's /v1/embeddings. It refuses text longer than the model takes, so that text is
// tokenized (the router's /tokenize, same model) and cut to the first N-1 tokens plus the end token —
// vectors identical to Ollama's cut (cosine 1.00000 on 100-line chunks, 2026-10-14), so indexes built
// through Ollama stay valid.
std::vector<float> FoxIntel::embed_llama(const std::string& text, const std::string& model) {
    auto vector_of = [](const std::string& body) -> std::vector<float> {
        auto j = json::parse(body);
        return j.at("data").at(0).at("embedding").get<std::vector<float>>();
    };
    int limit = 0;
    {
        std::lock_guard<std::mutex> lk(g_limit_mu);
        auto it = g_embed_limit.find(model);
        if (it != g_embed_limit.end()) limit = it->second;
    }
    std::string out;
    if (limit == 0) {                                  // limit not known yet: try the text as it is
        long code = post_json(embed_base + "/embeddings", {{"model", model}, {"input", text}}, out);
        try {
            if (code == 200) return vector_of(out);
            std::string msg = json::parse(out).at("error").at("message").get<std::string>();
            auto at = msg.find("batch size: ");
            if (at == std::string::npos) { embed_failed(msg); return {}; }
            limit = std::stoi(msg.substr(at + 12));
            std::lock_guard<std::mutex> lk(g_limit_mu);
            g_embed_limit[model] = limit;
        } catch (...) {
            embed_failed(code < 0 ? embed_base + " did not answer" : out.substr(0, 200));
            return {};
        }
    }
    std::string root = embed_base;                     // /tokenize lives beside /v1, not under it
    if (root.size() >= 3 && root.compare(root.size() - 3, 3, "/v1") == 0) root.resize(root.size() - 3);
    try {
        out.clear();
        if (post_json(root + "/tokenize", {{"model", model}, {"content", text}, {"add_special", true}}, out) != 200) {
            embed_failed(out.substr(0, 200));
            return {};
        }
        auto tokens = json::parse(out).at("tokens").get<std::vector<long>>();
        if (limit > 1 && tokens.size() > static_cast<size_t>(limit)) {
            long end_token = tokens.back();
            tokens.resize(limit - 1);
            tokens.push_back(end_token);
        }
        out.clear();
        if (post_json(embed_base + "/embeddings", {{"model", model}, {"input", tokens}}, out) == 200)
            return vector_of(out);
        embed_failed(out.substr(0, 200));
    } catch (...) { embed_failed(out.substr(0, 200)); }
    return {};
}

std::string FoxIntel::ask(const std::string& prompt, bool stream) {
    if (!api_base.empty()) return ask_openai(prompt, stream);
    std::string readBuffer;
    CURL* curl = curl_easy_init();
    if(curl) {
        json body = {{"model", default_model}, {"prompt", prompt}, {"stream", stream}};
        std::string json_str = body.dump();
        struct curl_slist* headers = curl_slist_append(NULL, "Content-Type: application/json");

        curl_easy_setopt(curl, CURLOPT_URL, "http://localhost:11434/api/generate");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_str.c_str());
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        
        if (stream) {
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, StreamCallback);
        } else {
            curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
            curl_easy_setopt(curl, CURLOPT_WRITEDATA, &readBuffer);
        }

        if(curl_easy_perform(curl) == CURLE_OK && !stream) {
            try {
                auto j = json::parse(readBuffer);
                if (j.contains("response")) {
                    readBuffer = j["response"].get<std::string>();
                }
            } catch (...) {}
        }
        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
    }
    if (stream) return "";
    return readBuffer;
}

// The same question to a llama.cpp router (OpenAI-compatible /chat/completions). Not streaming: the
// answer, or the raw body when it isn't one (an error stays visible, as on the Ollama path).
std::string FoxIntel::ask_openai(const std::string& prompt, bool stream) {
    std::string readBuffer, pending;
    CURL* curl = curl_easy_init();
    if (!curl) return "";
    json body = {{"model", default_model}, {"stream", stream},
                 {"messages", json::array({{{"role", "user"}, {"content", prompt}}})}};
    std::string json_str = body.dump();
    std::string url = api_base + "/chat/completions";
    struct curl_slist* headers = curl_slist_append(NULL, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_str.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    if (stream) {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, SseCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &pending);
    } else {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &readBuffer);
    }
    CURLcode rc = curl_easy_perform(curl);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    if (rc != CURLE_OK) {
        std::cerr << "fox-intel: " << url << ": " << curl_easy_strerror(rc) << std::endl;
        return "";
    }
    if (stream) {
        print_sse_line(pending);                     // a body without a final newline
        return "";
    }
    try {
        auto j = json::parse(readBuffer);
        if (j.contains("choices") && !j["choices"].empty())
            return j["choices"][0]["message"]["content"].get<std::string>();
    } catch (...) {}
    return readBuffer;
}

double FoxIntel::cosine_similarity(const std::vector<float>& v1, const std::vector<float>& v2) {
    double dot = 0.0, norm_a = 0.0, norm_b = 0.0;
    size_t n = std::min(v1.size(), v2.size());
    for (size_t i = 0; i < n; ++i) {
        dot += v1[i] * v2[i];
        norm_a += v1[i] * v1[i];
        norm_b += v2[i] * v2[i];
    }
    return (norm_a > 0 && norm_b > 0) ? dot / (sqrt(norm_a) * sqrt(norm_b)) : 0.0;
}

bool FoxIntel::ensure_ollama_running() {
    // Silent check (redirect stdout/stderr to /dev/null)
    if (FoxUtils::run_cmd({"ollama", "list"}, true) != 0) {
        std::cout << color_accent() << "[Fox Brain is asleep. Waking up...]" << color_reset() << std::endl;
        FoxUtils::run_cmd({"sudo", "systemctl", "start", "ollama"});
        std::this_thread::sleep_for(std::chrono::seconds(2));
        return FoxUtils::run_cmd({"ollama", "list"}, true) == 0;
    }
    return true;
}

bool FoxIntel::ensure_model_present(const std::string& model_name) {
    // A llama.cpp router serves what is already on disk: nothing to pull for the model it answers with.
    if (!api_base.empty() && model_name == default_model) return true;
    if (!FoxUtils::has_model(model_name.c_str())) {
        std::cout << "Model " << model_name << " not found. Pulling now..." << std::endl;
        return FoxUtils::run_cmd({"ollama", "pull", model_name.c_str()}) == 0;
    }
    return true;
}

int FoxUtils::run_cmd(std::initializer_list<const char*> argv, bool silent) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (silent) {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                close(devnull);
            }
        }
        std::vector<const char*> args(argv.begin(), argv.end());
        args.push_back(nullptr);
        execvp(args[0], const_cast<char* const*>(args.data()));
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

bool FoxUtils::has_model(const char* pattern) {
    int pipefd[2];
    if (pipe(pipefd) < 0) return false;
    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        return false;
    }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execlp("ollama", "ollama", "list", (char*)nullptr);
        _exit(127);
    }
    close(pipefd[1]);
    FILE* f = fdopen(pipefd[0], "r");
    bool found = false;
    if (f) {
        char buf[4096];
        while (fgets(buf, sizeof(buf), f)) {
            if (strstr(buf, pattern)) { found = true; break; }
        }
        fclose(f);
    } else {
        close(pipefd[0]);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return found;
}
