#ifndef FOX_INSTALL_CORE_SPLICE_HPP
#define FOX_INSTALL_CORE_SPLICE_HPP

// Replace the lines between a begin/end sentinel pair (the sentinel lines
// themselves are kept) with `new_content`, atomically (tmp + rename). Returns
// false if the file or the begin sentinel is missing. Shared by every module
// that rewrites a marked block in a deployed config (personalize, welcome_banner).

#include <filesystem>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>

namespace fox_install {

inline bool splice_sentinel(const std::filesystem::path& p,
                            const std::string& begin_sentinel,
                            const std::string& end_sentinel,
                            const std::string& new_content) {
    namespace fs = std::filesystem;
    if (!fs::exists(p)) return false;

    std::string body;
    {
        std::ifstream in(p);
        body.assign((std::istreambuf_iterator<char>(in)),
                     std::istreambuf_iterator<char>());
    }
    if (body.find(begin_sentinel) == std::string::npos) return false;

    std::istringstream iss(body);
    std::ostringstream out;
    std::string line;
    bool skip = false;
    while (std::getline(iss, line)) {
        if (line.find(begin_sentinel) != std::string::npos) {
            out << line << "\n" << new_content << "\n";
            skip = true;
            continue;
        }
        if (line.find(end_sentinel) != std::string::npos) {
            skip = false;
            out << line << "\n";
            continue;
        }
        if (!skip) out << line << "\n";
    }

    fs::path tmp = p;
    tmp += ".foxin.tmp";
    {
        std::ofstream w(tmp);
        w << out.str();
    }
    std::error_code ec;
    fs::rename(tmp, p, ec);
    if (ec) { fs::remove(tmp); return false; }
    return true;
}

}  // namespace fox_install

#endif
