// modules/llama_server.cpp — llama.cpp's router as the local model server for coding agents.
//
// Installs Arch's llama-cpp + the ggml backend for the GPU (ggml-cuda on NVIDIA, ggml-vulkan on
// AMD/Intel, CPU-only otherwise), enables fox-llm-server.service — `fox-llm-serve run`: one URL
// (127.0.0.1:8080), the models named in the roles file, read straight from Ollama's store — and
// lets `fox-llm-update --sync` add the `llamacpp` provider to opencode + pi. Ollama stays: model
// downloads, embeddings, the fox-ai tools.
//
// Why not just Ollama: on the T1200 laptop (2026-10-13) the same 7B generated 54 % faster here on
// the same GPU, and llama.cpp has the low-VRAM features Ollama lacks (MoE experts in RAM with
// attention on the GPU, an expert cache, multi-token prediction, a model router).

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

    if (!idem::write_atomic(unit, SERVICE_BODY)) {
        ui::warn("could not write " + unit.string());
        return;
    }
    sh::run({"systemctl", "--user", "daemon-reload"});
    if (sh::run({"systemctl", "--user", "enable", "--now", "fox-llm-server.service"}) == 0) {
        ui::ok("fox-llm-server.service enabled — router on 127.0.0.1:8080 (models from the roles file)");
    } else {
        ui::warn("could not enable fox-llm-server.service via systemctl --user");
    }

    // Now that the unit is enabled, sync wires the llamacpp provider into opencode + pi.
    if (sh::run({"bash", sync_bin.string(), "--sync"}) == 0) {
        ui::ok("opencode + pi know the llamacpp provider");
    } else {
        ui::warn("fox-llm-update --sync failed — run it by hand");
    }
}

}  // namespace fox_install
