// modules/cursor_recolor.hpp — derive a palette-coloured cursor set from a
// downloaded one. Upstream sets ship fixed colours, so a theme that needs its
// own ink names a base set + colours in CURSOR_RECOLOR:
//     base-theme:src_fill:src_outline:fill:outline[:flower]   (or "none")
// Every pixel of those sets is a blend of two inks, so recolouring is a
// projection onto the old fill↔outline line, repainted along the new one.
// `flower` also swaps the busy cursors for a slowly turning flower drawn in the
// same two inks; it's generated, so it scales with the set.

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
    bool flower = false;
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
    if (parts.size() == 6 && parts[5] != "flower") return std::nullopt;
    if ((parts.size() != 5 && parts.size() != 6) || parts[0].empty()) return std::nullopt;
    if (parts[0].find('/') != std::string::npos || parts[0].find("..") != std::string::npos)
        return std::nullopt;
    const auto sf = parse_hex(parts[1]), so = parse_hex(parts[2]);
    const auto nf = parse_hex(parts[3]), no = parse_hex(parts[4]);
    if (!sf || !so || !nf || !no) return std::nullopt;
    return Recolor{token, parts[0], *sf, *so, *nf, *no, parts.size() == 6};
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

inline std::string read_file(const fs::path& p);

struct Image {
    uint32_t nominal, width, height, xhot, yhot, delay;
    std::vector<unsigned char> bgra;  // premultiplied
};

// Every image chunk, in file order. Empty if the file is malformed.
inline std::vector<Image> read_images(const std::string& d) {
    constexpr uint32_t IMAGE_TYPE = 0xfffd0002;
    std::vector<Image> images;
    if (d.size() < 16 || d.compare(0, 4, "Xcur") != 0) return {};
    const uint64_t header = read_u32(d, 4), entries = read_u32(d, 12);
    if (header < 16 || header + entries * 12 > d.size()) return {};
    for (uint64_t i = 0; i < entries; ++i) {
        const uint64_t toc = header + i * 12;
        if (read_u32(d, toc) != IMAGE_TYPE) continue;
        const uint64_t pos = read_u32(d, toc + 8);
        if (pos + 36 > d.size()) return {};
        const uint64_t chunk = read_u32(d, pos), w = read_u32(d, pos + 16), h = read_u32(d, pos + 20);
        if (chunk < 36 || w > 0x7fff || h > 0x7fff || pos + chunk + w * h * 4 > d.size()) return {};
        Image image{read_u32(d, pos + 8), static_cast<uint32_t>(w), static_cast<uint32_t>(h),
                    read_u32(d, pos + 24), read_u32(d, pos + 28), read_u32(d, pos + 32), {}};
        const auto* px = reinterpret_cast<const unsigned char*>(d.data() + pos + chunk);
        image.bgra.assign(px, px + w * h * 4);
        images.push_back(std::move(image));
    }
    return images;
}

inline std::string write_images(const std::vector<Image>& images) {
    constexpr uint32_t IMAGE_TYPE = 0xfffd0002;
    std::string out = "Xcur";
    const auto put = [&out](uint32_t v) { out.append(reinterpret_cast<const char*>(&v), sizeof v); };
    put(16);
    put(0x10000);
    put(static_cast<uint32_t>(images.size()));
    uint32_t pos = 16 + static_cast<uint32_t>(images.size()) * 12;
    for (const Image& image : images) {
        put(IMAGE_TYPE);
        put(image.nominal);
        put(pos);
        pos += 36 + static_cast<uint32_t>(image.bgra.size());
    }
    for (const Image& image : images) {
        for (uint32_t v : {36u, IMAGE_TYPE, image.nominal, 1u, image.width, image.height,
                           image.xhot, image.yhot, image.delay})
            put(v);
        out.append(reinterpret_cast<const char*>(image.bgra.data()), image.bgra.size());
    }
    return out;
}

// Paints the flower over `image`, keeping whatever is already underneath.
inline void paint_flower(Image& image, double cx, double cy, double radius, double turn, const Recolor& rc) {
    constexpr double TAU = 6.283185307179586;
    constexpr int PETALS = 5, SAMPLES = 4;
    const double petal = radius * 0.42, reach = radius * 0.58, heart = radius * 0.2;
    const double line = std::max(1.0, radius * 0.11);
    double centres[PETALS][2];
    for (int i = 0; i < PETALS; ++i) {
        const double angle = turn + i * TAU / PETALS;
        centres[i][0] = cx + reach * std::cos(angle);
        centres[i][1] = cy + reach * std::sin(angle);
    }
    for (uint32_t y = 0; y < image.height; ++y) {
        for (uint32_t x = 0; x < image.width; ++x) {
            double colour[3] = {0, 0, 0}, cover = 0;
            for (int sy = 0; sy < SAMPLES; ++sy) {
                for (int sx = 0; sx < SAMPLES; ++sx) {
                    const double px = x + (sx + 0.5) / SAMPLES, py = y + (sy + 0.5) / SAMPLES;
                    double edge = 1e9;
                    for (const auto& c : centres)
                        edge = std::min(edge, std::hypot(px - c[0], py - c[1]) - petal);
                    const bool centre = std::hypot(px - cx, py - cy) < heart;
                    if (edge > 0 && !centre) continue;
                    const bool ink = centre || edge > -line;
                    const Rgb& paint = ink ? rc.outline : rc.fill;
                    for (int k = 0; k < 3; ++k) colour[k] += paint.c[k];
                    cover += 1;
                }
            }
            if (cover == 0) continue;
            const double total = SAMPLES * SAMPLES, a = cover / total;
            unsigned char* px = &image.bgra[(y * image.width + x) * 4];
            for (int k = 0; k < 3; ++k) {
                const double over = colour[k] / total + px[2 - k] * (1 - a);
                px[2 - k] = static_cast<unsigned char>(std::lround(std::min(255.0, over)));
            }
            px[3] = static_cast<unsigned char>(std::lround(std::min(255.0, 255 * a + px[3] * (1 - a))));
        }
    }
}

// wait: the flower alone, centred. progress: the arrow with a small one beside it.
inline bool add_flower_cursors(const fs::path& cursors, const Recolor& rc) {
    constexpr int FRAMES = 12;
    constexpr uint32_t DELAY_MS = 90;
    constexpr double SYMMETRY = 6.283185307179586 / 5;  // one petal's turn loops cleanly
    const auto arrows = read_images(read_file(cursors / "default"));
    if (arrows.empty()) return false;

    std::vector<Image> wait, progress;
    std::vector<uint32_t> seen;
    for (const Image& arrow : arrows) {
        if (std::find(seen.begin(), seen.end(), arrow.nominal) != seen.end()) continue;
        seen.push_back(arrow.nominal);
        const double w = arrow.width, h = arrow.height;
        for (int f = 0; f < FRAMES; ++f) {
            const double turn = SYMMETRY * f / FRAMES;
            Image alone{arrow.nominal, arrow.width, arrow.height, arrow.width / 2, arrow.height / 2,
                        DELAY_MS, std::vector<unsigned char>(arrow.bgra.size(), 0)};
            paint_flower(alone, w / 2, h / 2, arrow.nominal * 0.5, turn, rc);
            wait.push_back(std::move(alone));

            Image beside = arrow;
            beside.delay = DELAY_MS;
            paint_flower(beside, w * 0.72, h * 0.72, arrow.nominal * 0.27, turn, rc);
            progress.push_back(std::move(beside));
        }
    }
    const auto replace = [&cursors](const char* name, const std::vector<Image>& images) {
        std::error_code ec;
        fs::remove(cursors / name, ec);  // it may be a link back to another shape
        const std::string bytes = write_images(images);
        std::ofstream out(cursors / name, std::ios::binary);
        out << bytes;
        out.close();
        return static_cast<bool>(out);
    };
    return replace("wait", wait) && replace("progress", progress);
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
    if (ok && rc.flower) ok = add_flower_cursors(tmp / "cursors", rc);

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
