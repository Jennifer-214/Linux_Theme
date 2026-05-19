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
// Auto-reverts the drop-in if ollama fails to start after applying
// (catches misconfigured directives without leaving the service dead).

#include "../core/context.hpp"
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

}  // namespace

void run_ollama_hardening(Context& ctx) {
    ui::section("Ollama systemd hardening drop-in");

    if (!unit_exists("ollama.service")) {
        ui::ok("ollama.service not present — skipping");
        return;
    }

    if (sh::dry_run()) {
        ui::substep("[dry-run] would write /etc/systemd/system/ollama.service.d/"
                    "foxml-hardening.conf, daemon-reload, restart ollama, "
                    "and auto-revert if restart fails");
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

    if (idem::up_to_date(drop_in, body.str(), ctx.force_reapply)) {
        ui::skipped("ollama hardening drop-in already up to date (GPU: " + has_gpu + ")");
        return;
    }

    if (sh::run({"sudo", "install", "-d", drop_in_dir.string()}) != 0) {
        ui::err("sudo install -d failed");
        return;
    }
    fs::path tmp = "/tmp/foxin-ollama.conf.tmp";
    {
        std::ofstream o(tmp);
        o << body.str();
    }
    int rc = sh::run({"sudo", "install", "-m", "0644", "-o", "root", "-g", "root",
                      tmp.string(), drop_in.string()});
    fs::remove(tmp);
    if (rc != 0) {
        ui::err("could not install " + drop_in.string());
        return;
    }
    sh::run({"sh", "-c", "sudo systemctl daemon-reload >/dev/null 2>&1 || true"});

    if (!systemctl_active("ollama")) {
        ui::ok("hardening drop-in installed (will apply on next start; tuned for " +
               has_gpu + " GPU)");
        return;
    }

    if (sh::run({"sh", "-c", "sudo systemctl restart ollama >/dev/null 2>&1"}) != 0) {
        ui::warn("restart failed — leaving drop-in in place");
        return;
    }
    std::this_thread::sleep_for(std::chrono::seconds(2));
    if (systemctl_active("ollama")) {
        ui::ok("ollama hardened + restarted (PrivateDevices=" +
               std::string(private_devices ? "true" : "false") + ", " +
               (rw_paths.empty() ? "default RW" : rw_paths + " RW") + ")");
    } else {
        ui::warn("ollama failed to start after hardening — auto-reverting drop-in");
        sh::run({"sudo", "rm", "-f", drop_in.string()});
        sh::run({"sh", "-c", "sudo systemctl daemon-reload >/dev/null 2>&1 || true"});
        sh::run({"sh", "-c", "sudo systemctl restart ollama >/dev/null 2>&1 || true"});
        ui::substep("investigate with: systemctl status ollama -l");
    }
}

}  // namespace fox_install
