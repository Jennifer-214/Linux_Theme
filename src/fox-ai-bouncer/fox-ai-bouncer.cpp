// fox-ai-bouncer — classify USBGuard-blocked devices.
//
// Pairs with fox-bouncer (the user systemd unit that alerts on USBGuard
// BLOCK events). When a device gets denied, this binary captures the
// device descriptor + current USBGuard policy and asks the model:
// "is this a normal accident (charging cable, wrong mode) or a
// malicious HID attack (Rubber Ducky, BadUSB, USBKill)?"
//
// Usage:
//   fox-ai-bouncer                    # classify the most recent block
//   fox-ai-bouncer <device-id>        # classify a specific device

#include "../fox-intel/fox_intel.hpp"

#include <cerrno>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace {

bool capture(const std::vector<const char*>& argv, std::string& out) {
    int p[2];
    if (::pipe(p) < 0) return false;
    pid_t pid = ::fork();
    if (pid < 0) { ::close(p[0]); ::close(p[1]); return false; }
    if (pid == 0) {
        ::close(p[0]);
        ::dup2(p[1], STDOUT_FILENO);
        ::dup2(p[1], STDERR_FILENO);
        ::close(p[1]);
        std::vector<const char*> v(argv);
        v.push_back(nullptr);
        ::execvp(v[0], const_cast<char* const*>(v.data()));
        ::_exit(127);
    }
    ::close(p[1]);
    char buf[4096];
    for (;;) {
        ssize_t n = ::read(p[0], buf, sizeof(buf));
        if (n > 0) out.append(buf, static_cast<size_t>(n));
        else if (n == 0) break;
        else if (errno != EINTR) break;
    }
    ::close(p[0]);
    int status = 0;
    while (::waitpid(pid, &status, 0) < 0) if (errno != EINTR) return false;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

std::string trim_tail(std::string s, size_t limit) {
    if (s.size() > limit) {
        s = s.substr(0, limit);
        s += "\n(... truncated)\n";
    }
    return s;
}

}  // namespace

int main(int argc, char** argv) {
    std::string model;
    std::string device_id;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "-h" || a == "--help") {
            std::printf("Usage: fox-ai-bouncer [--model <name>] [<device-id>]\n\n"
                "Classifies a USBGuard-blocked device as benign (charging cable\n"
                "in wrong mode, etc.) or hostile (HID attack, BadUSB, USBKill).\n"
                "Default targets the most recent BLOCK in journalctl.\n");
            return 0;
        }
        if (a == "--model" && i + 1 < argc) { model = argv[++i]; continue; }
        if (!a.empty() && a[0] != '-') device_id = a;
    }

    FoxIntel ai = model.empty() ? FoxIntel{} : FoxIntel{model};
    if (!ai.ensure_ollama_running()) {
        std::fprintf(stderr, "fox-ai-bouncer: Ollama daemon unavailable\n");
        return 1;
    }

    std::cout << "\033[1;32m[fox-ai-bouncer: collecting evidence...]\033[0m\n";

    std::ostringstream ctx;

    // Most recent USBGuard BLOCK events from journalctl. We don't filter
    // by device-id here because the bash bouncer already has the IDs;
    // we just want all recent blocks for the model to reason over.
    std::string j;
    capture({"journalctl", "-u", "usbguard", "--since", "-30min",
             "--no-pager", "-q"}, j);
    ctx << "=== journalctl -u usbguard (last 30 min) ===\n"
        << trim_tail(j, 4000) << "\n";

    if (!device_id.empty()) {
        ctx << "=== Target device id ===\n" << device_id << "\n";
        // Capture full usbguard listing once, then filter in-process —
        // never let device_id (argv[1], untrusted user input) enter a
        // shell command line via concatenation.
        std::string all;
        capture({"sudo", "usbguard", "list-devices"}, all);
        std::string desc;
        std::istringstream is(all);
        std::string line;
        while (std::getline(is, line)) {
            if (line.find(device_id) != std::string::npos) {
                desc += line + "\n";
            }
        }
        if (!desc.empty()) {
            ctx << "=== USBGuard device descriptor ===\n" << desc << "\n";
        }
    }

    // Current USBGuard policy — context for what's allowed already.
    std::string policy;
    capture({"sh", "-c", "sudo usbguard list-rules 2>/dev/null | head -30"}, policy);
    if (!policy.empty()) {
        ctx << "=== USBGuard allowed-rules (head) ===\n"
            << trim_tail(policy, 2000) << "\n";
    }

    if (ctx.str().size() < 30) {
        std::cout << "\033[1;33m[no USBGuard activity in last 30 min]\033[0m\n";
        return 0;
    }

    std::string prompt =
        "You are evaluating a USBGuard BLOCK event on an Arch laptop. "
        "Based on the evidence below, classify the event:\n"
        "  - BENIGN: charging cable in data-mode by accident, peripheral re-plug, etc.\n"
        "  - SUSPICIOUS: HID class on an unexpected device, mass-storage with autorun, etc.\n"
        "  - HOSTILE: Rubber Ducky / BadUSB / USBKill signature.\n"
        "Give the classification on one line, then the reasoning in 2-3 sentences, "
        "then the exact command to either allow the device or escalate. No markdown.\n\n"
        + ctx.str();

    std::cout << "\033[1;32m[asking the model...]\033[0m\n\n";
    ai.ask(prompt, /*stream=*/true);
    std::cout << "\n";
    return 0;
}
