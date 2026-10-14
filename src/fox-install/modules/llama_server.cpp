// modules/llama_server.cpp — llama.cpp's router as the default local model server for coding agents.
//
// Installs Arch's llama-cpp + the ggml backend for the GPU (ggml-cuda on NVIDIA, ggml-vulkan on
// AMD/Intel, CPU-only otherwise), opens Ollama's model store to you read-only, enables
// fox-llm-server.service — `fox-llm-serve run`: one URL (127.0.0.1:8080) serving the roles file's
// models and every other chat model in Ollama's store, read in place — and lets
// `fox-llm-update --sync` add the `llamacpp` provider to opencode + pi and move their local
// default onto it. Ollama stays: model downloads, embeddings, the title model, the fox-ai tools,
// and the models only it runs as built (Modelfile example chats, formats llama.cpp can't load).
//
// Why not just Ollama: on the T1200 laptop (2026-10-13) the same 7B generated 54 % faster here on
// the same GPU, and llama.cpp has the low-VRAM features Ollama lacks (MoE experts in RAM with
// attention on the GPU, an expert cache, multi-token prediction, a model router).

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include <pwd.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* SERVICE_BODY =
    "[Unit]\n"
    "Description=fox-llm-server — llama.cpp router for the local coding agents (fox-llm-serve)\n"
    "After=network.target\n"
    "\n"
    "[Service]\n"
    "ExecStart=%h/.local/bin/fox-llm-serve run\n"
    "Restart=on-failure\n"
    "RestartSec=10\n"
    "Nice=5\n"
    "\n"
    "[Install]\n"
    "WantedBy=default.target\n";

std::string login_name() {
    if (const char* u = std::getenv("USER"); u && *u) return u;
    if (const passwd* pw = ::getpwuid(::getuid())) return pw->pw_name;
    return {};
}

// The router runs as you and reads Ollama's store in place (no second copy of any model), but the
// ollama package keeps its home 0700. Read-only ACLs open the way down to the store and the store
// itself, and the default entry carries over to every blob Ollama writes later. (The ollama group
// would need a re-login.) Only a directory you can't already pass gets an entry. Verified on the
// T1200 laptop 2026-10-13 (by hand) and 2026-10-14 (the same command on a tree with files).
bool grant_store_access(const std::string& user, const fs::path& store) {
    if (user.empty()) return false;
    fs::path walk;
    for (const auto& part : store.parent_path()) {      // top down: a child is reachable once its parent is
        walk /= part;
        if (::access(walk.c_str(), X_OK) == 0) continue;
        if (sh::run({"sudo", "setfacl", "-m", "u:" + user + ":x", walk.string()}) != 0) return false;
    }
    if (sh::run({"sudo", "setfacl", "-R", "-m", "u:" + user + ":rX", "-m", "d:u:" + user + ":rX",
                 store.string()}) != 0) return false;
    return ::access((store / "manifests").c_str(), R_OK | X_OK) == 0;
}

std::string gpu_backend(const Context& ctx) {
    if (ctx.has_nvidia) return "ggml-cuda";                       // pulls cuda + nccl
    if (ctx.has_amd_gpu || ctx.has_intel_gpu) return "ggml-vulkan";
    return {};                                                     // ggml's CPU backend
}

}  // namespace

void run_llama_server(Context& ctx) {
    ui::section("llama.cpp model server (router for the local coding agents)");

    std::vector<std::string> pkgs = {"llama-cpp"};
    std::string backend = gpu_backend(ctx);
    if (!backend.empty()) pkgs.push_back(backend);
    fs::path unit = ctx.config_home / "systemd/user/fox-llm-server.service";
    fs::path sync_bin = ctx.home / ".local/bin/fox-llm-update";
    if (!fs::exists(sync_bin)) sync_bin = ctx.shared_dir / "bin/fox-llm-update";
    const char* models_env = std::getenv("OLLAMA_MODELS");
    fs::path store = (models_env && *models_env) ? fs::path(models_env)
                                                 : fs::path("/usr/share/ollama/.ollama/models");

    if (sh::dry_run()) {
        std::string list;
        for (auto& p : pkgs) list += (list.empty() ? "" : " ") + p;
        ui::substep("[dry-run] would install " + list + ", give " + login_name() + " read access (ACL) to " +
                    store.string() + ", write + enable " + unit.string() +
                    " (fox-llm-serve run on 127.0.0.1:8080), and run fox-llm-update --sync");
        return;
    }

    if (sh::pacman(pkgs) != 0) {
        ui::warn("pacman could not install llama-cpp" + (backend.empty() ? "" : " + " + backend) +
                 " — skipping the server");
        return;
    }
    ui::ok("llama-cpp installed" + (backend.empty() ? " (CPU backend)" : " with " + backend));

    // Before the router's first start, so its first preset already sees the models. Best-effort: the
    // server still installs without it, and the warning carries the two commands to run by hand.
    const std::string user = login_name();
    const std::string by_hand = "sudo setfacl -m u:" + user + ":x " + store.parent_path().parent_path().string() +
                                " && sudo setfacl -R -m u:" + user + ":rX -m d:u:" + user + ":rX " + store.string();
    if (!sh::sudo_warmup()) {
        ui::warn("sudo cache cold — Ollama's model store not opened to " + user +
                 "; llama.cpp serves nothing until: " + by_hand);
    } else if (sh::run({"sudo", "test", "-d", store.string()}) != 0) {
        ui::substep("no Ollama model store at " + store.string() +
                    " yet — rerun `fox-install --only llama_server` once the ai module has run");
    } else if (grant_store_access(user, store)) {
        ui::ok("Ollama's model store readable for " + user + " (read-only ACL, inherited by new models)");
    } else {
        ui::warn("could not open " + store.string() + " to " + user + " — llama.cpp serves nothing until: " + by_hand);
    }

    if (!idem::write_atomic(unit, SERVICE_BODY)) {
        ui::warn("could not write " + unit.string());
        return;
    }
    sh::run({"systemctl", "--user", "daemon-reload"});
    if (sh::run({"systemctl", "--user", "enable", "--now", "fox-llm-server.service"}) == 0) {
        ui::ok("fox-llm-server.service enabled — router on 127.0.0.1:8080 (the default local model server)");
    } else {
        ui::warn("could not enable fox-llm-server.service via systemctl --user");
    }

    // Now that the unit is enabled, sync wires the llamacpp provider into opencode + pi.
    if (sh::run({"bash", sync_bin.string(), "--sync"}) == 0) {
        ui::ok("opencode + pi use the llamacpp provider (Ollama stays listed as a fallback)");
    } else {
        ui::warn("fox-llm-update --sync failed — run it by hand");
    }
}

}  // namespace fox_install
