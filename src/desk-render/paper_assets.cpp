#include "paper_assets.hpp"
#include "render.hpp"
#include <fstream>
#include <iterator>

namespace fs = std::filesystem;
namespace desk_render {
bool finish_paper_assets(const fs::path& templates, const fs::path& output) {
    const bool full = fs::exists(templates / "firefox/userContent.css");
    if (!full && !fs::exists(templates / "userContent.css")) return true;
    const fs::path css = full ? output / "firefox/userContent.css" : output / "userContent.css";
    if (!fs::exists(css)) return true;
    std::ifstream in(css);
    std::string text{std::istreambuf_iterator<char>(in), {}};
    const std::string marker = "{{PAPER_BOTANICAL_DATA_URI}}";
    if (text.find(marker) == std::string::npos) return true;
    const auto repo = full ? templates.parent_path() : templates.parent_path().parent_path();
    std::ifstream asset(repo / "shared/quickshell/desk/paper-sprig.png", std::ios::binary);
    const std::string bytes{std::istreambuf_iterator<char>(asset), {}};
    if (bytes.empty()) return false;
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string data = "data:image/png;base64,";
    data.reserve(data.size() + (bytes.size() + 2) / 3 * 4);
    for (size_t i = 0; i < bytes.size(); i += 3) {
        unsigned value = static_cast<unsigned char>(bytes[i]) << 16;
        if (i + 1 < bytes.size()) value |= static_cast<unsigned char>(bytes[i + 1]) << 8;
        if (i + 2 < bytes.size()) value |= static_cast<unsigned char>(bytes[i + 2]);
        data += alphabet[(value >> 18) & 63]; data += alphabet[(value >> 12) & 63];
        data += i + 1 < bytes.size() ? alphabet[(value >> 6) & 63] : '=';
        data += i + 2 < bytes.size() ? alphabet[value & 63] : '=';
    }
    // Firefox blocks file: images here, so embed the same sprig used by the drawer and lock screen.
    for (size_t at = text.find(marker); at != std::string::npos; at = text.find(marker, at + data.size()))
        text.replace(at, marker.size(), data);
    return atomic_write(css, text, fs::status(css).permissions());
}
}
