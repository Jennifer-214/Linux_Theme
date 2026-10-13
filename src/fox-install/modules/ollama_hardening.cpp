// modules/ollama_hardening.cpp — systemd sandbox for ollama.service.
//
// Mirrors mappings.sh::install_ollama_hardening. Critical now that
// libfox-intel + fox-ai-doctor are live: a prompt-injected model that
// tries to read $HOME/.ssh gets blocked by ProtectHome=read-only.
//
// Auto-tuned per host:
//   * ReadWritePaths includes only directories that actually exist
//     (a missing dir makes systemd's namespace setup fail with
//     status=226/NAMESPACE and silently brick the service).
//   * PrivateDevices toggles based on GPU presence — true is strongest
//     but strips /dev/nvidia* and /dev/dri/*, killing GPU inference.
//
// Second drop-in, foxml-context.conf: OLLAMA_CONTEXT_LENGTH tiered by RAM and
// OLLAMA_KEEP_ALIVE=10m. Coding agents send ~15k-token prompts (opencode's system
// prompt + tools alone) that ollama's default window silently truncates, and an
// agent's dozens of requests per task would otherwise reload the model each time.
// An existing foxml-context.conf that sets both is left alone — it may be hand-tuned.
//
// Auto-reverts what it wrote if ollama fails to start after applying
// (catches misconfigured directives without leaving the service dead).

#include <cstdlib>
#include <unistd.h>
#include "../core/context.hpp"
#include "../core/hardware.hpp"
#include "../core/idempotency.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool unit_exists(const std::string& unit) {
    std::string out;
    sh::capture({"systemctl", "list-unit-files", "--no-legend"}, out);
    return out.find(unit) != std::string::npos;
}

bool systemctl_active(const std::string& u) {
    return sh::run({"systemctl", "is-active", "--quiet", u}) == 0;
}

bool dir_exists(const fs::path& p) {
    std::error_code ec;
    return fs::is_directory(p, ec) && !ec;
}

std::string context_body(int ram_gb) {
    int window = ram_gb >= 32 ? 32768 : ram_gb >= 16 ? 16384 : 8192;
    return "# foxml-managed — model context window + keep-alive for coding agents.\n"
           "# Revert: sudo rm /etc/systemd/system/ollama.service.d/foxml-context.conf\n"
           "[Service]\n"
           "Environment=\"OLLAMA_CONTEXT_LENGTH=" + std::to_string(window) + "\"\n"
           "Environment=\"OLLAMA_KEEP_ALIVE=10m\"\n";
}

bool context_configured(const fs::path& p) {
    std::string body = idem::read_file(p);
    return body.find("OLLAMA_CONTEXT_LENGTH") != std::string::npos &&
           body.find("OLLAMA_KEEP_ALIVE") != std::string::npos;
}

// Root-owned 0644 file via `sudo install`. mkstemp avoids a /tmp symlink-race
// against a predictable name.
bool install_root_file(const fs::path& dst, const std::string& body) {
    char tmpl[] = "/tmp/foxin-ollama-XXXXXX";
    int fd = ::mkstemp(tmpl);
    if (fd < 0) {
        ui::err("could not create temp file for " + dst.filename().string());
        return false;
    }
    ssize_t w = ::write(fd, body.data(), body.size());
    ::close(fd);
    if (w != static_cast<ssize_t>(body.size())) {
        ui::err("short write to tempfile for " + dst.filename().string());
        ::unlink(tmpl);
        return false;
    }
    int rc = sh::run({"sudo", "install", "-m", "0644", "-o", "root", "-g", "root",
                      tmpl, dst.string()});
    ::unlink(tmpl);
    if (rc != 0) {
        ui::err("could not install " + dst.string());
        return false;
    }
    return true;
}

}  // namespace

void run_ollama_hardening(Context& ctx) {
    ui::section("Ollama systemd hardening drop-in");

    if (!unit_exists("ollama.service")) {
        ui::ok("ollama.service not present — skipping");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/systemd/system/ollama.service.d/"
                    "foxml-hardening.conf + foxml-context.conf (unless already set), "
                    "daemon-reload, restart ollama, and auto-revert if restart fails");
        return;
    }

    if (!sh::sudo_warmup()) {
        ui::err("sudo cache cold — `sudo -v` first");
        return;
    }

    // Compute dynamic ReadWritePaths — only include dirs that exist.
    std::vector<std::string> rw_candidates = {
        "/usr/share/ollama", "/var/lib/ollama"
    };
    if (const char* env = std::getenv("OLLAMA_MODELS"); env && *env) {
        rw_candidates.emplace_back(env);
    }
    std::string rw_paths;
    for (auto& p : rw_candidates) {
        if (dir_exists(p)) { rw_paths += p + " "; }
    }
    if (!rw_paths.empty() && rw_paths.back() == ' ') rw_paths.pop_back();

    // GPU detection.
    bool has_nvidia = false, has_other_gpu = false;
    {
        std::error_code ec;
        for (auto& e : fs::directory_iterator("/dev", ec)) {
            if (e.path().filename().string().rfind("nvidia", 0) == 0) {
                has_nvidia = true;
                break;
            }
        }
    }
    if (!has_nvidia) has_other_gpu = dir_exists("/dev/dri");

    std::string has_gpu = has_nvidia ? "nvidia"
                        : has_other_gpu ? "amd-or-intel"
                                         : "no";
    bool private_devices = (has_gpu == "no");

    std::ostringstream body;
    body << "# foxml-managed — systemd sandbox for ollama.service.\n"
            "# Revert: sudo rm /etc/systemd/system/ollama.service.d/foxml-hardening.conf\n"
            "#\n"
            "# Auto-tuned for this machine:\n"
            "#   GPU:              " << has_gpu << "\n"
            "#   ReadWritePaths:   " << (rw_paths.empty() ? "<none — ollama will use defaults>" : rw_paths) << "\n"
            "#   PrivateDevices:   " << (private_devices ? "true" : "false")
                                     << "  (false on GPU systems so /dev/nvidia* are visible)\n"
            "[Service]\n"
            "NoNewPrivileges=true\n"
            "ProtectHome=read-only\n"
            "ProtectSystem=strict\n"
            "PrivateTmp=true\n"
            "PrivateDevices=" << (private_devices ? "true" : "false") << "\n"
            "ProtectKernelTunables=true\n"
            "ProtectKernelModules=true\n"
            "ProtectKernelLogs=true\n"
            "ProtectControlGroups=true\n"
            "ProtectClock=true\n"
            "RestrictNamespaces=true\n"
            "RestrictRealtime=true\n"
            "LockPersonality=true\n"
            "MemoryDenyWriteExecute=false\n"
            "SystemCallArchitectures=native\n";
    if (has_nvidia) {
        body << "DeviceAllow=/dev/nvidia0 rw\n"
                "DeviceAllow=/dev/nvidiactl rw\n"
                "DeviceAllow=/dev/nvidia-modeset rw\n"
                "DeviceAllow=/dev/nvidia-uvm rw\n"
                "DeviceAllow=/dev/nvidia-uvm-tools rw\n";
    } else if (has_other_gpu) {
        body << "DeviceAllow=char-drm rw\n";
    }
    body << "ReadWritePaths=" << rw_paths << "\n";

    fs::path drop_in_dir = "/etc/systemd/system/ollama.service.d";
    fs::path drop_in     = drop_in_dir / "foxml-hardening.conf";

    fs::path context_in  = drop_in_dir / "foxml-context.conf";
    bool want_hardening  = !idem::up_to_date(drop_in, body.str(), ctx.force_reapply);
    bool want_context    = !context_configured(context_in);

    if (!want_hardening && !want_context) {
        ui::skipped("ollama drop-ins already up to date (GPU: " + has_gpu + ")");
        return;
    }

    if (sh::run({"sudo", "install", "-d", drop_in_dir.string()}) != 0) {
        ui::err("sudo install -d failed");
        return;
    }
    std::vector<fs::path> written;
    if (want_hardening) {
        if (!install_root_file(drop_in, body.str())) return;
        written.push_back(drop_in);
    }
    if (want_context) {
        if (install_root_file(context_in, context_body(hw::ram_gb()))) written.push_back(context_in);
    }
    if (written.empty()) return;
    sh::run({"sh", "-c", "sudo systemctl daemon-reload >/dev/null 2>&1 || true"});

    if (!systemctl_active("ollama")) {
        ui::ok("ollama drop-ins installed (will apply on next start; tuned for " +
               has_gpu + " GPU)");
        return;
    }

    if (sh::run({"sh", "-c", "sudo systemctl restart ollama >/dev/null 2>&1"}) != 0) {
        ui::warn("restart failed — leaving drop-ins in place");
        return;
    }
    std::this_thread::sleep_for(std::chrono::seconds(2));
    if (systemctl_active("ollama")) {
        if (want_hardening) {
            ui::ok("ollama hardened + restarted (PrivateDevices=" +
                   std::string(private_devices ? "true" : "false") + ", " +
                   (rw_paths.empty() ? "default RW" : rw_paths + " RW") + ")");
        }
        if (want_context) ui::ok("ollama context window + keep-alive set (foxml-context.conf)");
    } else {
        ui::warn("ollama failed to start after the drop-ins — auto-reverting them");
        for (auto& f : written) sh::run({"sudo", "rm", "-f", f.string()});
        sh::run({"sh", "-c", "sudo systemctl daemon-reload >/dev/null 2>&1 || true"});
        sh::run({"sh", "-c", "sudo systemctl restart ollama >/dev/null 2>&1 || true"});
        ui::substep("investigate with: systemctl status ollama -l");
    }
}

}  // namespace fox_install
