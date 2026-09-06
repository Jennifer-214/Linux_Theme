#include "state_manifest.hpp"

// nlohmann/json — vendored under src/fox-intel/.
#include "../../fox-common/json.hpp"

#include <openssl/evp.h>

#include <array>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace fox_install::state {

std::filesystem::path default_path() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    const char* home = std::getenv("HOME");
    fs::path base;
    if (xdg && *xdg) {
        base = xdg;
    } else if (home && *home) {
        base = fs::path(home) / ".config";
    } else {
        throw std::runtime_error("state_manifest: neither $XDG_CONFIG_HOME nor $HOME set");
    }
    return base / "foxml" / "install-state.json";
}

std::string now_iso8601() {
    using namespace std::chrono;
    const auto now = system_clock::now();
    const std::time_t t = system_clock::to_time_t(now);
    std::tm tm_utc{};
    gmtime_r(&t, &tm_utc);
    std::ostringstream oss;
    oss << std::put_time(&tm_utc, "%Y-%m-%dT%H:%M:%SZ");
    return oss.str();
}

Manifest read(const fs::path& path) {
    Manifest m;
    if (!fs::exists(path)) return m;

    std::ifstream f(path);
    if (!f) throw std::runtime_error("state_manifest: cannot open " + path.string());

    json j;
    try {
        f >> j;
    } catch (const std::exception& e) {
        throw std::runtime_error(std::string("state_manifest: parse error: ") + e.what());
    }

    if (j.contains("schema_version") && j["schema_version"].is_number_integer()) {
        m.schema_version = j["schema_version"].get<int>();
    }
    if (j.contains("fox_version") && j["fox_version"].is_string()) {
        m.fox_version = j["fox_version"].get<std::string>();
    }
    if (j.contains("modules") && j["modules"].is_object()) {
        for (auto it = j["modules"].begin(); it != j["modules"].end(); ++it) {
            ModuleState ms;
            const auto& v = it.value();
            if (v.contains("version") && v["version"].is_string())
                ms.version = v["version"].get<std::string>();
            if (v.contains("source_hash") && v["source_hash"].is_string())
                ms.source_hash = v["source_hash"].get<std::string>();
            if (v.contains("deployed_at") && v["deployed_at"].is_string())
                ms.deployed_at = v["deployed_at"].get<std::string>();
            m.modules[it.key()] = ms;
        }
    }

    return m;
}

void write(const fs::path& path, const Manifest& m) {
    fs::create_directories(path.parent_path());

    json j;
    j["schema_version"] = m.schema_version;
    j["fox_version"] = m.fox_version;
    j["modules"] = json::object();
    for (const auto& [name, ms] : m.modules) {
        j["modules"][name] = {
            {"version", ms.version},
            {"source_hash", ms.source_hash},
            {"deployed_at", ms.deployed_at},
        };
    }

    // Atomic write: tmp + rename. std::filesystem::rename is atomic on
    // POSIX when src and dst are on the same filesystem (which they
    // are — both under $HOME/.config).
    const fs::path tmp = path.string() + ".tmp";
    {
        std::ofstream f(tmp);
        if (!f) throw std::runtime_error("state_manifest: cannot open " + tmp.string());
        f << j.dump(2) << '\n';
        if (!f) throw std::runtime_error("state_manifest: write failed: " + tmp.string());
    }

    std::error_code ec;
    fs::rename(tmp, path, ec);
    if (ec) {
        fs::remove(tmp);  // best effort cleanup
        throw std::runtime_error("state_manifest: rename failed: " + ec.message());
    }
}

// SHA256 implementation using OpenSSL's EVP interface (the legacy
// SHA256_* functions are deprecated since OpenSSL 3.0).
namespace {

std::string sha256_hex(const unsigned char* data, std::size_t len) {
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
    unsigned int digest_len = 0;

    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (!ctx) throw std::runtime_error("state_manifest: EVP_MD_CTX_new failed");

    if (EVP_DigestInit_ex(ctx, EVP_sha256(), nullptr) != 1
            || EVP_DigestUpdate(ctx, data, len) != 1
            || EVP_DigestFinal_ex(ctx, digest.data(), &digest_len) != 1) {
        EVP_MD_CTX_free(ctx);
        throw std::runtime_error("state_manifest: SHA256 computation failed");
    }
    EVP_MD_CTX_free(ctx);

    std::ostringstream oss;
    oss << std::hex << std::setfill('0');
    for (unsigned int i = 0; i < digest_len; ++i) {
        oss << std::setw(2) << static_cast<int>(digest[i]);
    }
    return oss.str();
}

}  // namespace

std::string hash_file(const fs::path& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("hash_file: cannot open " + path.string());

    // Read whole file into memory. install-time files are configs
    // (kB range, not GB), so this is fine. If a gigantic file ever
    // shows up, switch to streaming via EVP_DigestUpdate in chunks.
    std::ostringstream buf;
    buf << f.rdbuf();
    const std::string contents = buf.str();
    return sha256_hex(
        reinterpret_cast<const unsigned char*>(contents.data()),
        contents.size()
    );
}

std::string hash_string(const std::string& s) {
    return sha256_hex(
        reinterpret_cast<const unsigned char*>(s.data()),
        s.size()
    );
}

}  // namespace fox_install::state
