#ifndef FOX_INSTALL_IDEMPOTENCY_HPP
#define FOX_INSTALL_IDEMPOTENCY_HPP

// Idempotency helpers for module re-runs. The contract:
//
//   if (idem::up_to_date(dst, BODY, ctx.force_reapply)) {
//       ui::ok("foo already configured");
//       return;
//   }
//   // ... write dst with BODY ...
//
// `up_to_date` is true when `dst` exists and its byte-for-byte content
// equals `expected`. `force_reapply` (set by --full) makes it always
// return false so the module re-applies even when settled.
//
// Why content equality (not just existence): when the installer body
// is updated upstream — new sysctls, tightened flags — the on-disk
// file falls out of sync and the module re-applies automatically.
// Users who want to override foxml-managed files should drop a
// higher-priority sibling (`99-user-override.conf`) rather than
// editing the foxml file itself; every foxml-managed file declares
// that convention in its header.

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

namespace fox_install::idem {

inline std::string read_file(const std::filesystem::path& p) {
    std::ifstream f(p);
    if (!f) return {};
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

inline bool up_to_date(const std::filesystem::path& dst,
                       const std::string& expected,
                       bool force_reapply) {
    if (force_reapply) return false;
    std::error_code ec;
    if (!std::filesystem::exists(dst, ec)) return false;
    return read_file(dst) == expected;
}

// tmp + rename in dst's directory, parents created. A reader never sees a
// half-written file, and a failed write leaves the old one in place.
inline bool write_atomic(const std::filesystem::path& dst, const std::string& body) {
    std::error_code ec;
    std::filesystem::create_directories(dst.parent_path(), ec);
    std::filesystem::path tmp = dst;
    tmp += ".foxin-tmp";
    {
        std::ofstream o(tmp);
        o << body;
        o.close();
        if (!o) {
            std::filesystem::remove(tmp, ec);
            return false;
        }
    }
    std::filesystem::rename(tmp, dst, ec);
    if (ec) {
        std::filesystem::remove(tmp, ec);
        return false;
    }
    return true;
}

}  // namespace fox_install::idem

#endif
