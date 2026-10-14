// modules/llama_server.cpp — llama.cpp's router: the one local model server, for the coding agents and
// every fox-ai tool.
//
// Installs Arch's llama-cpp + the ggml backend for the GPU (ggml-cuda on NVIDIA, ggml-vulkan on
// AMD/Intel, CPU-only otherwise), enables fox-llm-server.service — `fox-llm-serve run`: one URL
// (127.0.0.1:8080) serving the roles file's models and every other downloaded one, chat and
// embeddings alike (the models module's queue downloads them from Hugging Face) — and lets
// `fox-llm-update --sync` add the `llamacpp` provider to opencode + pi and point their local default
// at it.
//
// Why llama.cpp: on the T1200 laptop (2026-10-13) the same 7B generated 54 % faster here than on
// Ollama on the same GPU, and llama.cpp has the low-VRAM features Ollama lacks (MoE experts in RAM
// with attention on the GPU, multi-token prediction, a model router). Ollama served everything until
// 2026-10; a machine that still has it is told how to remove it.

#include "../core/context.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <string>
#include <vector>

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

// Ollama's packages, when a machine still has them from before llama.cpp served everything.
std::string ollama_packages() {
    std::string out, pkgs;
    sh::capture({"sh", "-c", "pacman -Qq 2>/dev/null | grep -E '^ollama(-|$)'"}, out);
    for (size_t at = 0; at < out.size();) {
        size_t nl = out.find('\n', at);
        std::string pkg = out.substr(at, nl == std::string::npos ? std::string::npos : nl - at);
        if (!pkg.empty()) pkgs += (pkgs.empty() ? "" : " ") + pkg;
        if (nl == std::string::npos) break;
        at = nl + 1;
    }
    return pkgs;
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

    if (sh::dry_run()) {
        std::string list;
        for (auto& p : pkgs) list += (list.empty() ? "" : " ") + p;
        ui::substep("[dry-run] would install " + list + ", write + enable " + unit.string() +
                    " (fox-llm-serve run on 127.0.0.1:8080), and run fox-llm-update --sync");
        return;
    }

    if (sh::pacman(pkgs) != 0) {
        ui::warn("pacman could not install llama-cpp" + (backend.empty() ? "" : " + " + backend) +
                 " — skipping the server");
        return;
    }
    ui::ok("llama-cpp installed" + (backend.empty() ? " (CPU backend)" : " with " + backend));

    // Your roles live in your private custom_models repo (cloned by `github`, earlier). Link the old
    // path to them — tools that read only ~/.config/foxml/llm/roles.conf (the fox-symdeps explain cards)
    // see yours too. A real file there is a one-machine override: left alone.
    {
        fs::path mine = ctx.home / "code/custom_models/roles.conf";
        fs::path old = ctx.config_home / "foxml/llm/roles.conf";
        std::error_code ec;
        if (fs::exists(mine, ec) && !fs::exists(fs::symlink_status(old, ec))) {
            fs::create_directories(old.parent_path(), ec);
            fs::create_symlink(mine, old, ec);
            if (ec) ui::warn("could not link " + old.string() + " → " + mine.string() + ": " + ec.message());
            else ui::ok("roles: " + old.string() + " → your custom_models/roles.conf");
        }
    }

    // Ollama from before llama.cpp served everything: nothing uses it or its models any more. Removing a
    // package and its downloads is the user's call — said, not done.
    if (std::string pkgs = ollama_packages(); !pkgs.empty()) {
        ui::warn("Ollama is still installed, and nothing uses it now (llama.cpp serves every model; downloads "
                 "come from Hugging Face). To free its disk: sudo systemctl disable --now ollama && sudo pacman -Rns " +
                 pkgs + " && sudo rm -rf /usr/share/ollama");
    }

    if (!idem::write_atomic(unit, SERVICE_BODY)) {
        ui::warn("could not write " + unit.string());
        return;
    }
    sh::run({"systemctl", "--user", "daemon-reload"});
    // An update: `enable --now` leaves a running router on the old launcher (its flags, e.g. how many
    // models it keeps) — restart it so this install's version runs.
    const bool was_running = sh::run({"systemctl", "--user", "is-active", "--quiet", "fox-llm-server.service"}) == 0;
    if (sh::run({"systemctl", "--user", "enable", "--now", "fox-llm-server.service"}) == 0) {
        if (was_running) sh::run({"systemctl", "--user", "restart", "fox-llm-server.service"});
        ui::ok(std::string("fox-llm-server.service ") + (was_running ? "restarted" : "enabled") +
               " — router on 127.0.0.1:8080 (the default local model server)");
    } else {
        ui::warn("could not enable fox-llm-server.service via systemctl --user");
    }

    // Now that the unit is enabled, sync wires the llamacpp provider into opencode + pi.
    if (sh::run({"bash", sync_bin.string(), "--sync"}) == 0) {
        ui::ok("opencode + pi use the llamacpp provider");
    } else {
        ui::warn("fox-llm-update --sync failed — run it by hand");
    }
}

}  // namespace fox_install
