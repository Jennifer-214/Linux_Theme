// modules/fox_aliases.hpp — the old fox-* command names, kept working as links after the 2026-11 rename.
// Each old name in ~/.local/bin becomes a relative symlink to its new name when that tool is installed: an old copy of
// our tool is replaced, a link of ours is re-pointed, anything else (a link to elsewhere, a folder) is left alone.
// Pure (paths in, counts out) so tests/test_fox_aliases pins it. Remove with the transition.
#pragma once

#include <filesystem>
#include <string>
#include <system_error>
#include <utility>

namespace desk_install {

inline constexpr std::pair<const char*, const char*> kFoxAliases[] = {
    {"fox", "desk"},
    {"fox-agent-parse", "agent-parse"},
    {"fox-ai", "desk-ai"},
    {"fox-ai-audit", "ai-audit"},
    {"fox-ai-bench", "ai-bench"},
    {"fox-ai-bouncer", "ai-bouncer"},
    {"fox-ai-cmd", "ai-cmd"},
    {"fox-ai-commit", "ai-commit"},
    {"fox-ai-default", "ai-default"},
    {"fox-aider", "desk-aider"},
    {"fox-ai-doctor", "ai-doctor"},
    {"fox-ai-explain", "ai-explain"},
    {"fox-ai-find", "ai-find"},
    {"fox-ai-history", "ai-history"},
    {"fox-ai-log", "ai-log"},
    {"fox-ai-oracle", "ai-oracle"},
    {"fox-ai-purge", "ai-purge"},
    {"fox-ai-quick", "ai-quick"},
    {"fox-ai-review", "ai-review"},
    {"fox-ai-snitch", "ai-snitch"},
    {"fox-ai-status", "ai-status"},
    {"fox-ai-strategy", "ai-strategy"},
    {"fox-ai-swap", "ai-swap"},
    {"fox-ai-test", "ai-test"},
    {"fox-ai-trace", "ai-trace"},
    {"fox-ai-watch", "ai-watch"},
    {"fox-allowlist", "desk-allowlist"},
    {"fox-arm", "desk-arm"},
    {"fox-ask", "desk-ask"},
    {"fox-audit", "desk-audit"},
    {"fox-audit-timer", "audit-timer"},
    {"fox-backup", "desk-backup"},
    {"fox-bar", "desk-bar"},
    {"fox-bouncer", "desk-bouncer"},
    {"fox-build-verify", "build-verify"},
    {"fox-cafe", "desk-cafe"},
    {"fox-cheatsheet", "desk-cheatsheet"},
    {"fox-claude-api", "claude-api"},
    {"fox-color", "desk-color"},
    {"fox-common", "desk-common"},
    {"fox-credits", "desk-credits"},
    {"fox-deadman", "desk-deadman"},
    {"fox-desktop-menu", "desktop-menu"},
    {"fox-dev", "desk-dev"},
    {"fox-develop", "desk-develop"},
    {"fox-dispatch", "desk-dispatch"},
    {"fox-distro-build", "distro-build"},
    {"fox-distro-flash", "distro-flash"},
    {"fox-distro-guide", "distro-guide"},
    {"fox-dnssec", "desk-dnssec"},
    {"fox-dns-shield", "desk-dns-shield"},
    {"fox-doctor", "desk-doctor"},
    {"fox-drawer", "desk-drawer"},
    {"fox-eza", "desk-eza"},
    {"fox-fingerprint", "desk-fingerprint"},
    {"fox-firewall", "desk-firewall"},
    {"fox-generate-module", "generate-module"},
    {"fox-gen-keybinds", "gen-keybinds"},
    {"fox-harden", "desk-harden"},
    {"fox-health", "desk-health"},
    {"fox-hl", "desk-hl"},
    {"fox-honey", "desk-honey"},
    {"fox-honeypot", "desk-honeypot"},
    {"fox-hw-info", "hw-info"},
    {"fox-init", "desk-init"},
    {"fox-install", "desk-install"},
    {"fox-intel", "desk-intel"},
    {"fox-jail", "desk-jail"},
    {"fox-knock", "desk-knock"},
    {"fox-legacy", "desk-legacy"},
    {"fox-llm-discover", "llm-discover"},
    {"fox-llm-grade", "llm-grade"},
    {"fox-llm-run", "llm-run"},
    {"fox-llm-serve", "llm-serve"},
    {"fox-llm-update", "llm-update"},
    {"fox-lock", "desk-lock"},
    {"fox-lock-panel", "lock-panel"},
    {"fox-mac", "desk-mac"},
    {"fox-mako", "desk-mako"},
    {"fox-menu", "desk-menu"},
    {"fox-monitor", "desk-monitor"},
    {"fox-new-project", "new-project"},
    {"fox-notifications", "desk-notifications"},
    {"fox-nvidia-state", "nvidia-state"},
    {"fox-offline", "desk-offline"},
    {"fox-overwatch", "desk-overwatch"},
    {"fox-pass", "desk-pass"},
    {"fox-password-copy", "desk-password-copy"},
    {"fox-picker", "desk-picker"},
    {"fox-ports", "desk-ports"},
    {"fox-proximity", "desk-proximity"},
    {"fox-pulse", "desk-pulse"},
    {"fox-render", "desk-render"},
    {"fox-rollback", "desk-rollback"},
    {"fox-sandbox", "desk-sandbox"},
    {"fox-sec", "desk-sec"},
    {"fox-sec-dashboard", "sec-dashboard"},
    {"fox-sec-health", "sec-health"},
    {"fox-sentry-audit", "desk-sentry-audit"},
    {"fox-snitch", "desk-snitch"},
    {"fox-spa", "desk-spa"},
    {"fox-sys", "desk-sys"},
    {"fox-tail", "desk-tail"},
    {"fox-template-lint", "template-lint"},
    {"fox-test", "desk-test"},
    {"fox-theme", "desk-theme"},
    {"fox-theme-check", "theme-check"},
    {"fox-theme-tweak", "theme-tweak"},
    {"fox-tripwire", "desk-tripwire"},
    {"fox-uninstall", "desk-uninstall"},
    {"fox-usb", "desk-usb"},
    {"fox-vault", "desk-vault"},
    {"fox-vpn", "desk-vpn"},
    {"fox-wallpaper", "desk-wallpaper"},
    {"fox-word-count", "word-count"},
    {"fox-work", "desk-work"},
    {"fox-work-notice", "work-notice"},
    {"fox-render-fast", "desk-render-fast"},
};

struct AliasCounts { int linked = 0, kept = 0, left = 0; };

inline AliasCounts lay_fox_aliases(const std::filesystem::path& bin, bool dry) {
    namespace fs = std::filesystem;
    AliasCounts n;
    for (const auto& [old_name, new_name] : kFoxAliases) {
        std::error_code ec;
        const fs::path link = bin / old_name, target = bin / new_name;
        if (!fs::exists(target, ec)) continue;                       // that tool is not installed here
        const auto st = fs::symlink_status(link, ec);
        if (fs::is_symlink(st)) {
            const auto points = fs::read_symlink(link, ec);
            if (points == fs::path(new_name)) { ++n.kept; continue; }
            // Ours are relative names in the same folder; a link that goes anywhere else is someone's own.
            if (points.has_parent_path()) { ++n.left; continue; }
        } else if (fs::exists(st) && !fs::is_regular_file(st)) {
            ++n.left; continue;                                       // a folder or a device: not ours
        }
        if (!dry) {
            const fs::path tmp = bin / ("." + std::string(old_name) + ".alias-tmp");
            fs::remove(tmp, ec);
            fs::create_symlink(new_name, tmp, ec);
            if (ec) { ++n.left; continue; }
            fs::rename(tmp, link, ec);
            if (ec) { fs::remove(tmp, ec); ++n.left; continue; }
        }
        ++n.linked;
    }
    return n;
}

}  // namespace desk_install
