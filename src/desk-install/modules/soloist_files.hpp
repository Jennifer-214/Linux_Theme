// modules/soloist_files.hpp — where Soloist keeps its saved API key, and making that folder private.
// Soloist writes the folder 755 and the key 644; the soloist module tightens both.

#pragma once

#include <filesystem>
#include <system_error>

namespace desk_install::soloist {

inline const char* const BIN = "/usr/local/bin/soloist";
inline const char* const UNIT = "soloist.service";

// Soloist's own default outside systemd: $XDG_DATA_HOME/soloist, else ~/.local/share/soloist.
inline std::filesystem::path data_dir(const std::filesystem::path& home, const char* xdg_data_home) {
    if (xdg_data_home && *xdg_data_home) return std::filesystem::path(xdg_data_home) / "soloist";
    return home / ".local/share/soloist";
}

inline std::filesystem::path key_file(const std::filesystem::path& data) { return data / "credentials/api_key"; }

inline bool key_saved(const std::filesystem::path& data) {
    std::error_code ec;
    return std::filesystem::is_regular_file(key_file(data), ec) && std::filesystem::file_size(key_file(data), ec) > 0;
}

// The folder and credentials/ become 700, the key 600. Returns false when one of them could not be changed.
inline bool make_private(const std::filesystem::path& data) {
    namespace fs = std::filesystem;
    const auto dir = fs::perms::owner_all;
    const auto file = fs::perms::owner_read | fs::perms::owner_write;
    bool ok = true;
    std::error_code ec;
    for (const auto& path : {data, data / "credentials"}) {
        if (!fs::is_directory(path, ec)) continue;
        fs::permissions(path, dir, fs::perm_options::replace, ec);
        ok = ok && !ec;
    }
    if (fs::is_regular_file(key_file(data), ec)) {
        fs::permissions(key_file(data), file, fs::perm_options::replace, ec);
        ok = ok && !ec;
    }
    return ok;
}

}  // namespace desk_install::soloist
