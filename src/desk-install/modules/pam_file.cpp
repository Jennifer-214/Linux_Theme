// modules/pam_file.cpp — runs pam_file.hpp's install script under sudo and reads the result back.
#include "pam_file.hpp"
#include "../../desk-common/shell.hpp"

#include <unistd.h>

namespace desk_install::pam_file {

std::string install(const std::filesystem::path& path, const std::string& text) {
    if (sh::dry_run()) return "";
    char tmpl[] = "/tmp/desk-pam-XXXXXX";   // mkstemp: no predictable name to race; root only reads it
    const int fd = ::mkstemp(tmpl);
    if (fd < 0) return "could not create a temporary file for " + path.string() + "; it is unchanged";
    std::size_t at = 0;
    while (at < text.size()) {
        const auto n = ::write(fd, text.data() + at, text.size() - at);
        if (n <= 0) break;
        at += static_cast<std::size_t>(n);
    }
    ::close(fd);
    if (at != text.size()) { ::unlink(tmpl); return "could not write the new " + path.string() + "; it is unchanged"; }
    const int rc = sh::run({"sudo", "sh", "-c", kInstallScript, "sh", path.string(), tmpl});
    ::unlink(tmpl);
    if (rc == 3) return path.string() + " came out different from what was built; the previous file is back";
    if (rc != 0) return "could not replace " + path.string() + " (exit " + std::to_string(rc) + "); it is unchanged";
    std::ifstream back(path);
    const std::string now(std::istreambuf_iterator<char>(back), {});
    if (now != text) return path.string() + " does not read back as written; restore it from " + path.string() + ".foxml-bak";
    return "";
}

}  // namespace desk_install::pam_file
