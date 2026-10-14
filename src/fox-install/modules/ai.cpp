// modules/ai.cpp — OpenCode + aider install (no models, no model server).
//
//   1. Install OpenCode (pacman's [extra] package first, AUR / upstream script fallback).
//   2. Install aider (AUR-first, pipx fallback).
//
// The models are the models module's (a background download queue, Hugging Face GGUFs), the server
// llama_server's (llama.cpp's router serves every model — chat and embeddings), pi fox_symdeps' wiring.
// Ollama was the server and the downloader until 2026-10; nothing installs or needs it now.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <string>

namespace fox_install {

namespace {

std::string aur_helper() {
    if (sh::have("yay"))  return "yay";
    if (sh::have("paru")) return "paru";
    return {};
}

bool have(const std::string& bin) { return sh::have(bin); }

void install_via_aur_or_script(const std::string& aur_pkg,
                               const std::string& fallback_url,
                               const std::string& fallback_interp) {
    std::string aur = aur_helper();
    if (!aur.empty()) {
        if (sh::run({aur, "-S", "--needed", "--noconfirm", aur_pkg}) == 0) return;
        ui::warn("AUR install of " + aur_pkg + " failed, falling back to upstream script");
    } else {
        ui::substep("no AUR helper on PATH — using upstream installer");
    }
    // Falling back to curl | <interp>.
    sh::run({"sh", "-c",
             "curl -fsSL " + fallback_url + " | " + fallback_interp});
}

}  // namespace

void run_ai(Context& /*ctx*/) {
    ui::section("Installing AI tooling (OpenCode + aider)");

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // 1. OpenCode (agentic coding CLI — local models through llama.cpp's router). The official [extra]
    // package first: the upstream `curl | bash` installer drops a second copy in
    // ~/.opencode/bin that shadows pacman's and never updates with the system.
    if (have("opencode")) {
        ui::skipped("OpenCode already installed");
    } else {
        ui::substep("installing OpenCode");
        if (sh::pacman({"opencode"}) != 0) {
            ui::warn("pacman install of opencode failed — trying AUR / upstream script");
            install_via_aur_or_script("opencode-bin",
                "https://opencode.ai/install", "bash");
        }
    }

    // 2. aider — git-native pair programmer. Complements OpenCode for
    // commit-per-edit workflows. Python tool, so AUR (aider-chat) first,
    // pipx fallback — no curl|sh path makes sense here.
    if (have("aider")) {
        ui::skipped("aider already installed");
    } else {
        ui::substep("installing aider-chat (pulls ~60 Python deps — 2-5 min)");
        std::string aur = aur_helper();
        bool ok = false;
        if (!aur.empty()) {
            if (sh::run({aur, "-S", "--needed", "--noconfirm", "aider-chat"}) == 0) {
                ok = true;
            } else {
                ui::warn("AUR aider-chat failed, trying pipx fallback");
            }
        }
        if (!ok) {
            // pipx is the canonical fallback. If it isn't on PATH, install
            // it ourselves rather than asking the user to do step-1-of-2 by
            // hand — the whole point of the fallback is to be self-sufficient.
            if (!have("pipx")) {
                ui::substep("installing python-pipx (required for aider fallback)");
                sh::pacman({"python-pipx"});
            }
            // aider transitively depends on scipy. On bleeding-edge Python
            // (e.g. 3.14) PyPI wheels aren't always available yet, so uv
            // falls back to source builds. scipy's source build needs a
            // Fortran compiler and a BLAS/LAPACK implementation — pre-pull
            // both so the build doesn't bomb mid-compile.
            ui::substep("ensuring scipy build deps (gcc-fortran + openblas)");
            sh::pacman({"gcc-fortran", "openblas"});
            if (have("pipx")) {
                ok = (sh::run({"pipx", "install", "aider-chat"}) == 0);
                if (ok) {
                    // Python 3.14 removed stdlib `audioop` (PEP 594).
                    // pydub (a transitive aider dep for voice mode) still
                    // imports it; pydub's `pyaudioop` fallback was never
                    // published to PyPI. `audioop-lts` is the LTS shim
                    // that provides `audioop` itself, so pydub's first
                    // import path succeeds. Harmless on older Pythons.
                    sh::run({"pipx", "inject", "aider-chat", "audioop-lts"});
                }
            }
            if (!ok) {
                ui::warn("aider not installed — `pacman -S python-pipx gcc-fortran openblas && pipx install aider-chat && pipx inject aider-chat audioop-lts`");
            }
        }
    }

    ui::ok("AI tooling ready");
}

}  // namespace fox_install
