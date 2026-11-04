// modules/cursor_recolor.hpp — derive a palette-coloured cursor set from a
// downloaded one. Upstream sets ship fixed colours, so a theme that needs its
// own ink names a base set + colours in CURSOR_RECOLOR:
//     base-theme:src_fill:src_outline:fill:outline   (or "none")
// Every pixel of those sets is a blend of two inks, so recolouring is a
// projection onto the old fill↔outline line, repainted along the new one.

#ifndef FOX_INSTALL_MODULES_CURSOR_RECOLOR_HPP
#define FOX_INSTALL_MODULES_CURSOR_RECOLOR_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <system_error>
#include <vector>

namespace fox_install::cursor_recolor {

namespace fs = std::filesystem;

inline constexpr const char* STAMP = ".foxml-recolor";

struct Rgb {
    double c[3];
};

struct Recolor {
    std::string raw;  // the token, stored as the stamp
    std::string base;
    Rgb src_fill, src_outline, fill, outline;
};

inline std::optional<Rgb> parse_hex(const std::string& h) {
    if (h.size() != 6) return std::nullopt;
    Rgb out{};
    for (int i = 0; i < 3; ++i) {
        int v = 0;
        for (int k = 0; k < 2; ++k) {
            const char ch = h[static_cast<size_t>(i * 2 + k)];
            int d;
            if (ch >= '0' && ch <= '9') d = ch - '0';
            else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
            else return std::nullopt;
            v = v * 16 + d;
        }
        out.c[i] = v;
    }
    return out;
}

inline std::optional<Recolor> parse_recolor(const std::string& token) {
    std::vector<std::string> parts;
    size_t start = 0;
    for (size_t colon; (colon = token.find(':', start)) != std::string::npos; start = colon + 1)
        parts.push_back(token.substr(start, colon - start));
    parts.push_back(token.substr(start));
    if (parts.size() != 5 || parts[0].empty()) return std::nullopt;
    if (parts[0].find('/') != std::string::npos || parts[0].find("..") != std::string::npos)
        return std::nullopt;
    const auto sf = parse_hex(parts[1]), so = parse_hex(parts[2]);
    const auto nf = parse_hex(parts[3]), no = parse_hex(parts[4]);
    if (!sf || !so || !nf || !no) return std::nullopt;
    return Recolor{token, parts[0], *sf, *so, *nf, *no};
}

inline uint32_t read_u32(const std::string& d, uint64_t at) {
    uint32_t v;
    std::memcpy(&v, d.data() + at, sizeof v);  // Xcursor files are little-endian
    return v;
}

// False, leaving `d` unusable, when the file isn't a well-formed Xcursor.
inline bool recolor_xcursor(std::string& d, const Recolor& rc) {
    constexpr uint32_t IMAGE = 0xfffd0002;
    constexpr uint64_t CHUNK_HEADER = 36;
    if (d.size() < 16 || d.compare(0, 4, "Xcur") != 0) return false;
    const uint64_t header = read_u32(d, 4), entries = read_u32(d, 12);
    if (header < 16 || header + entries * 12 > d.size()) return false;

    double axis[3], den = 0;
    for (int k = 0; k < 3; ++k) {
        axis[k] = rc.src_fill.c[k] - rc.src_outline.c[k];
        den += axis[k] * axis[k];
    }
    if (den == 0) return false;

    for (uint64_t i = 0; i < entries; ++i) {
        const uint64_t toc = header + i * 12;
        if (read_u32(d, toc) != IMAGE) continue;
        const uint64_t pos = read_u32(d, toc + 8);
        if (pos + CHUNK_HEADER > d.size()) return false;
        const uint64_t chunk_header = read_u32(d, pos);
        const uint64_t w = read_u32(d, pos + 16), h = read_u32(d, pos + 20);
        if (chunk_header < CHUNK_HEADER || w > 0x7fff || h > 0x7fff) return false;
        const uint64_t first = pos + chunk_header, end = first + w * h * 4;
        if (end > d.size()) return false;

        for (uint64_t p = first; p < end; p += 4) {
            auto* px = reinterpret_cast<unsigned char*>(&d[p]);  // B G R A, premultiplied
            const double a = px[3];
            if (a == 0) continue;
            const double colour[3] = {std::min(255.0, px[2] * 255.0 / a),
                                      std::min(255.0, px[1] * 255.0 / a),
                                      std::min(255.0, px[0] * 255.0 / a)};
            double s = 0;
            for (int k = 0; k < 3; ++k) s += (colour[k] - rc.src_outline.c[k]) * axis[k];
            s = std::clamp(s / den, 0.0, 1.0);
            for (int k = 0; k < 3; ++k) {
                const double painted = rc.outline.c[k] + (rc.fill.c[k] - rc.outline.c[k]) * s;
                px[2 - k] = static_cast<unsigned char>(std::lround(painted * a / 255.0));
            }
        }
    }
    return true;
}

inline std::string read_file(const fs::path& p) {
    std::ifstream in(p, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), {}};
}

inline bool is_current(const fs::path& theme_dir, const Recolor& rc) {
    return read_file(theme_dir / STAMP) == rc.raw + "\n";
}

// Builds beside `dest` and swaps it in, so a failure leaves the old set intact.
inline bool build_theme(const fs::path& source, const fs::path& dest, const std::string& name,
                        const Recolor& rc) {
    std::error_code ec;
    fs::path tmp = dest;
    tmp += ".foxin-tmp";
    fs::remove_all(tmp, ec);
    fs::create_directories(tmp / "cursors", ec);
    if (ec) return false;

    bool ok = true;
    size_t cursors = 0;
    for (const auto& entry : fs::directory_iterator(source / "cursors", ec)) {
        const fs::path out = tmp / "cursors" / entry.path().filename();
        if (entry.is_symlink()) {
            fs::create_symlink(fs::read_symlink(entry.path(), ec), out, ec);
            ok = ok && !ec;
            continue;
        }
        std::string bytes = read_file(entry.path());
        ok = ok && recolor_xcursor(bytes, rc);
        std::ofstream(out, std::ios::binary) << bytes;
        ok = ok && fs::file_size(out, ec) == bytes.size();
        ++cursors;
    }
    ok = ok && !ec && cursors > 0;

    if (ok) {
        std::ofstream(tmp / "index.theme")
            << "[Icon Theme]\nName=" << name << "\nComment=Recoloured from " << rc.base << "\n";
        for (const char* notice : {"LICENSE", "AUTHORS"})
            if (fs::exists(source / notice)) fs::copy_file(source / notice, tmp / notice, ec);
        std::ofstream(tmp / STAMP) << rc.raw << '\n';
        fs::remove_all(dest, ec);
        fs::rename(tmp, dest, ec);
        ok = !ec;
    }
    if (!ok) fs::remove_all(tmp, ec);
    return ok;
}

}  // namespace fox_install::cursor_recolor

#endif
