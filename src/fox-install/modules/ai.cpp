// modules/ai.cpp — Ollama + OpenCode + aider install (no models).
//
// Mirrors install.sh's --ai block:
//   1. Install Ollama (AUR signature-verified via yay/paru, fallback to
//      curl|sh only if no AUR helper is present).
//   2. Ensure ollama.service is enabled and the HTTP endpoint is up.
//   3. Pull mxbai-embed-large (the embedding model libfox-intel depends
//      on for RAG; pulling it here so every fox-* AI tool can rely on
//      it being present).
//   4. Install OpenCode (AUR-first, same fallback).
//   5. Install aider (AUR-first, pipx fallback).
//   6. Smoke test the stack — embedding endpoint actually responds.
//
// Models module (--models) is separate so users can pull big stuff
// independently of getting ollama running.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <string>
#include <thread>
#include <chrono>

namespace fox_install {

namespace {

std::string aur_helper() {
    std::string out;
    if (sh::capture({"sh", "-c", "command -v yay"}, out) && !out.empty())  return "yay";
    if (sh::capture({"sh", "-c", "command -v paru"}, out) && !out.empty()) return "paru";
    return {};
}

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

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

void wait_for_http(const std::string& url, int max_attempts, int sleep_ms) {
    for (int i = 0; i < max_attempts; ++i) {
        if (sh::run({"curl", "-sf", "-m", "1", "-o", "/dev/null", url.c_str()}) == 0) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(sleep_ms));
    }
}

}  // namespace

void run_ai(Context& ctx) {
    ui::section("Installing AI tooling (Ollama + OpenCode + aider)");

    if (!sh::dry_run() && !sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // 1. Ollama
    if (have("ollama")) {
        ui::skipped("Ollama already installed");
    } else {
        ui::substep("installing Ollama");
        install_via_aur_or_script("ollama-bin",
            "https://ollama.com/install.sh", "sh");
    }

    // 2. Daemon up + HTTP endpoint reachable
    if (!sh::dry_run()) {
        std::string out;
        bool active = sh::capture({"systemctl", "is-active", "--quiet", "ollama"}, out);
        if (!active) {
            if (sh::systemctl_enable("ollama", /*user=*/false) == 0) {
                wait_for_http("http://127.0.0.1:11434/", 50, 200);
                ui::ok("ollama.service started");
            } else {
                ui::warn("could not enable ollama via systemd — start it manually");
            }
        } else {
            ui::skipped("ollama.service already active");
        }
    }

    // 3. Embedding model (libfox-intel RAG dep — used by findex/fask)
    {
        bool model_present = sh::run({"sh", "-c",
            "ollama list 2>/dev/null | grep -q mxbai-embed-large"}) == 0;
        if (model_present && !ctx.force_reapply) {
            ui::skipped("mxbai-embed-large already pulled");
        } else {
            ui::substep("pulling mxbai-embed-large (embedding model, ~670 MB)");
            for (int attempt = 1; attempt <= 3; ++attempt) {
                if (sh::run({"ollama", "pull", "mxbai-embed-large"}) == 0) break;
                if (attempt == 3) {
                    ui::warn("mxbai-embed-large pull failed after 3 attempts — retry: `ollama pull mxbai-embed-large`");
                    break;
                }
                ui::substep("retrying in 3s (attempt " + std::to_string(attempt + 1) + "/3)");
                std::this_thread::sleep_for(std::chrono::seconds(3));
            }
        }
    }

    // 4. OpenCode (chat-style CLI client that uses Ollama)
    if (have("opencode")) {
        ui::skipped("OpenCode already installed");
    } else {
        ui::substep("installing OpenCode");
        install_via_aur_or_script("opencode-bin",
            "https://opencode.ai/install", "bash");
    }

    // 5. aider — git-native pair programmer. Complements OpenCode for
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

    // 6. Smoke test — fail loudly if the stack is broken so the user
    // doesn't first discover it from a silently-failing fox-ask.
    if (!sh::dry_run()) {
        ui::substep("smoke testing AI stack");
        int tags = sh::run({"sh", "-c",
            "curl -sf -m 3 http://127.0.0.1:11434/api/tags >/dev/null"});
        if (tags != 0) {
            ui::warn("Ollama HTTP endpoint not reachable — RAG / fox-ask will not work");
        } else {
            int embed = sh::run({"sh", "-c",
                "curl -sf -m 15 http://127.0.0.1:11434/api/embeddings "
                "-d '{\"model\":\"mxbai-embed-large\",\"prompt\":\"smoke test\"}' "
                "| grep -q embedding"});
            if (embed != 0) {
                ui::warn("mxbai-embed-large embedding query failed — findex/fask will not work");
            } else {
                ui::ok("AI stack smoke test passed (embeddings + http both OK)");
            }
        }
    }

    ui::ok("AI tooling ready");
}

}  // namespace fox_install
