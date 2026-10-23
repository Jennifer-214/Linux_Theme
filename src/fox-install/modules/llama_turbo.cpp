// modules/llama_turbo.cpp — the TurboQuant llama.cpp fork, built from source as a second engine.
//
// Arch packages mainline llama.cpp (the llama_server module); this fork has no package, so it is
// built at the commit pinned in shared/llm/llama-turbo.pin into ~/.local/opt/llama.cpp-turbo.
// Its turbo KV cache compresses V ~4x and, on the T1200 laptop (2026-10-13), generated ~10-15 %
// faster than mainline 8k deep into a context — while reading prompts ~2.5x slower. So it serves
// only the roles that name `llama-turbo` (fox-llm-serve --engine turbo, :8081); its unit is
// enabled only while a role does.
//
// Backends: CUDA on NVIDIA (arch from the GPU, every FA KV combination so q8_0/turbo mixes have
// GPU kernels); CPU-only machines get the CPU build; AMD/Intel are skipped — the fork's turbo
// kernels are CUDA/HIP/Metal/CPU, not Vulkan. An existing checkout is never reset or rebuilt
// unless it is at another commit and clean.

#include "../core/context.hpp"
#include "../core/git_clone_sh.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

constexpr const char* SERVICE_BODY =
    "[Unit]\n"
    "Description=fox-llm-server-turbo — TurboQuant llama.cpp router for llama-turbo roles (fox-llm-serve)\n"
    "After=network.target\n"
    "\n"
    "[Service]\n"
    "ExecStart=%h/.local/bin/fox-llm-serve --engine turbo run\n"
    "Restart=on-failure\n"
    "RestartSec=10\n"
    "Nice=5\n"
    "\n"
    "[Install]\n"
    "WantedBy=default.target\n";

// "key value" lines; '#' comments.
std::map<std::string, std::string> read_pin(const fs::path& p) {
    std::map<std::string, std::string> kv;
    std::ifstream f(p);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ls(line);
        std::string k, v;
        if (ls >> k >> v) kv[k] = v;
    }
    return kv;
}

std::string capture_trim(const std::vector<std::string>& argv) {
    std::string out;
    if (!sh::capture(argv, out)) return {};
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
    return out;
}

// "7.5" → "75". NVML can be down after a driver update while CUDA works; then build for the
// common consumer generations instead (Turing → Blackwell).
std::string cuda_arch() {
    std::string cap = capture_trim({"nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"});
    cap = cap.substr(0, cap.find('\n'));
    std::string digits;
    for (char c : cap) if (c >= '0' && c <= '9') digits += c;
    return digits.size() >= 2 ? digits : "75;86;89;120";
}

bool roles_use_turbo(const Context& ctx) {
    // The first roles file that exists decides, as in fox-llm-serve: this machine's, then yours in the
    // private custom_models repo, then the shipped default.
    for (const fs::path& p : {ctx.config_home / "foxml/llm/roles.conf", ctx.home / "code/custom_models/roles.conf",
                              ctx.config_home / "foxml/llm/roles.default"}) {
        std::ifstream f(p);
        if (!f) continue;
        std::string line;
        while (std::getline(f, line)) {
            std::istringstream ls(line);
            std::string role, model, server;
            if (ls >> role >> model >> server && role[0] != '#' && server == "llama-turbo") return true;
        }
        return false;                                   // the first file found wins
    }
    return false;
}

}  // namespace

void run_llama_turbo(Context& ctx) {
    ui::section("TurboQuant llama.cpp fork (second engine, built from source)");

    if (ctx.has_amd_gpu || ctx.has_intel_gpu) {
        if (!ctx.has_nvidia) {
            ui::skipped("the fork's turbo KV kernels are CUDA/HIP/Metal/CPU only — not built on this GPU");
            return;
        }
    }
    auto pin = read_pin(ctx.shared_dir / "llm/llama-turbo.pin");
    if (pin["repo"].empty() || pin["commit"].empty()) {
        ui::warn("shared/llm/llama-turbo.pin is missing repo/commit — skipped");
        return;
    }
    fs::path src = ctx.home / ".local/opt/llama.cpp-turbo";
    const bool cuda = ctx.has_nvidia;
    fs::path build = src / (cuda ? "build-cuda" : "build-cpu");
    fs::path unit = ctx.config_home / "systemd/user/fox-llm-server-turbo.service";
    fs::path sync_bin = ctx.home / ".local/bin/fox-llm-update";
    if (!fs::exists(sync_bin)) sync_bin = ctx.shared_dir / "bin/fox-llm-update";

    if (sh::dry_run()) {
        ui::substep("[dry-run] would build " + pin["repo"] + " @ " + pin["commit"].substr(0, 10) + " (" +
                    (cuda ? "CUDA" : "CPU") + ") into " + build.string() + ", write " + unit.string() +
                    " (enabled only while a role names llama-turbo), and run fox-llm-update --sync");
        return;
    }

    std::error_code ec;
    std::string head;
    const auto runner = git_clone::sh_runner();
    if (!git_clone::valid_checkout(runner, src)) {   // absent, or a clone that dropped part-way (core/git_clone.hpp)
        const auto res = git_clone::ensure(runner, pin["repo"], src, {"--depth", "1", "--branch", pin["branch"]});
        if (res.outcome == git_clone::Outcome::Failed || res.outcome == git_clone::Outcome::NotARepo) {
            ui::warn(pin["repo"] + " → " + src.string() + ": " + git_clone::describe(res.outcome) + " — skipped");
            return;
        }
    }
    head = capture_trim({"git", "-C", src.string(), "rev-parse", "HEAD"});
    if (head != pin["commit"]) {
        if (!capture_trim({"git", "-C", src.string(), "status", "--porcelain"}).empty()) {
            ui::warn(src.string() + " has local changes and is not at the pinned commit — left as is");
            return;
        }
        if (sh::run({"git", "-C", src.string(), "fetch", "--quiet", "--depth", "1", "origin", pin["commit"]}) != 0 ||
            sh::run({"git", "-C", src.string(), "checkout", "--quiet", pin["commit"]}) != 0) {
            ui::warn("could not check out the pinned commit " + pin["commit"].substr(0, 10) + " — skipped");
            return;
        }
        fs::remove_all(build, ec);                        // a stale build of another commit
    }

    if (fs::exists(build / "bin/llama-server", ec)) {
        ui::skipped("TurboQuant build already at the pinned commit (" + pin["commit"].substr(0, 10) + ")");
    } else {
        // CUDA's nvcc writes temporaries to $TMPDIR; /tmp may be noexec (noexec_tmp), so use the cache.
        fs::path tmp = ctx.home / ".cache/nvcc-tmp";
        fs::create_directories(tmp, ec);
        std::vector<std::string> cfg = {"env", "TMPDIR=" + tmp.string(), "PATH=/opt/cuda/bin:/usr/bin:/bin",
            "cmake", "-S", src.string(), "-B", build.string(), "-DCMAKE_BUILD_TYPE=Release",
            "-DGGML_NATIVE=ON", "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF"};
        if (cuda) {
            cfg.insert(cfg.end(), {"-DGGML_CUDA=ON", "-DGGML_CUDA_FA_ALL_QUANTS=ON",
                                   "-DCMAKE_CUDA_ARCHITECTURES=" + cuda_arch(),
                                   "-DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc"});
        }
        ui::substep(std::string("building (") + (cuda ? "CUDA — 20-40 min" : "CPU — a few min") + ")");
        std::vector<std::string> bld = {"env", "TMPDIR=" + tmp.string(), "PATH=/opt/cuda/bin:/usr/bin:/bin",
            "cmake", "--build", build.string(), "-j", "--target", "llama-server", "llama-bench", "llama-cli"};
        if (sh::run(cfg) != 0 || sh::run(bld) != 0) {
            ui::warn("TurboQuant build failed — mainline (llama_server) is unaffected");
            return;
        }
        ui::ok("TurboQuant fork built (" + pin["commit"].substr(0, 10) + ")");
    }

    if (!idem::write_atomic(unit, SERVICE_BODY)) {
        ui::warn("could not write " + unit.string());
        return;
    }
    sh::run({"systemctl", "--user", "daemon-reload"});
    if (roles_use_turbo(ctx)) {
        // An update restarts a running router so the new launcher (and a new build) takes over.
        const bool was_running =
            sh::run({"systemctl", "--user", "is-active", "--quiet", "fox-llm-server-turbo.service"}) == 0;
        if (sh::run({"systemctl", "--user", "enable", "--now", "fox-llm-server-turbo.service"}) == 0) {
            if (was_running) sh::run({"systemctl", "--user", "restart", "fox-llm-server-turbo.service"});
            ui::ok(std::string("fox-llm-server-turbo.service ") + (was_running ? "restarted" : "enabled") +
                   " — router on 127.0.0.1:8081");
        } else {
            ui::warn("could not enable fox-llm-server-turbo.service");
        }
    } else {
        ui::skipped("no role names llama-turbo — unit installed, not enabled "
                    "(set a role's server to llama-turbo, then: systemctl --user enable --now fox-llm-server-turbo)");
    }
    if (sh::run({"bash", sync_bin.string(), "--sync"}) != 0) ui::warn("fox-llm-update --sync failed — run it by hand");
}

}  // namespace fox_install
