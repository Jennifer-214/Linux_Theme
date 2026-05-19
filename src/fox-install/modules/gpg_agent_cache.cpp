// modules/gpg_agent_cache.cpp — extend gpg-agent's cached-passphrase TTL.
//
// 10-minute default makes auto-signing commits re-prompt mid-session.
// Default override: 3600s (1h). Set FOXML_GPG_CACHE_TTL=<seconds> to
// customise. No-op for users who don't sign with GPG. Mirrors
// mappings.sh::install_gpg_agent_cache.

#include "../core/context.hpp"
#include "../../fox-common/shell.hpp"
#include "../../fox-common/ui.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

namespace fs = std::filesystem;

namespace fox_install {

namespace {

bool have(const std::string& bin) {
    std::string out;
    return sh::capture({"sh", "-c", "command -v " + bin}, out) && !out.empty();
}

std::string git_config(const std::string& key) {
    std::string out;
    if (!sh::capture({"git", "config", "--global", "--get", key}, out)) return {};
    while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
    return out;
}

bool has_gpg_secret_keys() {
    std::string out;
    sh::capture({"gpg", "--list-secret-keys", "--with-colons"}, out);
    return out.find("\nsec:") != std::string::npos ||
           out.rfind("sec:", 0) == 0;
}

}  // namespace

void run_gpg_agent_cache(Context& ctx) {
    ui::section("gpg-agent passphrase cache TTL");

    if (!have("gpg")) {
        ui::ok("gpg not installed, skipping");
        return;
    }
    if (sh::dry_run()) {
        ui::substep("[dry-run] would write ~/.gnupg/gpg-agent.conf with "
                    "default-cache-ttl / max-cache-ttl");
        return;
    }
    if (git_config("commit.gpgsign") != "true" && !has_gpg_secret_keys()) {
        ui::ok("commit.gpgsign=false and no GPG secret keys, skipping");
        return;
    }

    const char* override_env = std::getenv("FOXML_GPG_CACHE_TTL");
    std::string ttl = (override_env && *override_env) ? override_env : "3600";

    fs::path gnupg = ctx.home / ".gnupg";
    fs::path conf  = gnupg / "gpg-agent.conf";
    fs::create_directories(gnupg);
    fs::permissions(gnupg, fs::perms::owner_all, fs::perm_options::replace);

    if (!fs::exists(conf)) {
        std::ofstream o(conf);
        o << "# Cache the signing-key passphrase so agent commits don't re-prompt every\n"
             "# 10 minutes (gpg-agent default). Override at install time with\n"
             "# FOXML_GPG_CACHE_TTL=<seconds>; current value: " << ttl << "s.\n"
             "default-cache-ttl " << ttl << "\n"
             "max-cache-ttl "     << ttl << "\n";
        fs::permissions(conf,
            fs::perms::owner_read | fs::perms::owner_write,
            fs::perm_options::replace);
        ui::ok("gpg-agent cache TTL → " + ttl + "s (new ~/.gnupg/gpg-agent.conf)");
    } else {
        std::ifstream f(conf);
        std::string body((std::istreambuf_iterator<char>(f)),
                          std::istreambuf_iterator<char>());
        bool touched = false;
        std::ofstream o(conf, std::ios::app);
        if (body.find("default-cache-ttl") == std::string::npos) {
            o << "default-cache-ttl " << ttl << "\n";
            touched = true;
        }
        if (body.find("max-cache-ttl") == std::string::npos) {
            o << "max-cache-ttl " << ttl << "\n";
            touched = true;
        }
        if (touched) ui::ok("gpg-agent cache TTL → " + ttl + "s (appended)");
        else         ui::skipped("gpg-agent.conf already has cache TTLs — leaving as-is");
    }

    sh::run({"sh", "-c", "gpgconf --reload gpg-agent 2>/dev/null || true"});
}

}  // namespace fox_install
