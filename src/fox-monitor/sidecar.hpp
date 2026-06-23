#ifndef FOX_MONITOR_SIDECAR_HPP
#define FOX_MONITOR_SIDECAR_HPP

// Parser + writer for ~/.config/foxml/monitor-layout.conf, the sidecar
// file written by configure_monitors / fox-monitor-watch / reconcile.
//
// Format: bash-style KEY="value" assignments. Only these four keys are
// recognized; everything else is ignored. Values may be unquoted, double
// or single quoted. Spaces inside the quoted value are preserved.
//
// This is the single sidecar implementation — both fox-install and
// fox-monitor link libfox-monitor.a so there's one read/write code path.

#include <filesystem>
#include <string>
#include <vector>

namespace fox_monitor::sidecar {

struct Layout {
    std::string              primary;
    std::vector<std::string> portrait_outputs;
    std::vector<std::string> secondary_outputs;
    // entries shaped like "<name>:<WxH>" — matches bash MONITOR_RESOLUTIONS.
    std::vector<std::string> monitor_resolutions;
};

// Returns a Layout populated from `path`. Missing file or unparseable
// content yields an empty Layout — call sites check primary.empty().
Layout read(const std::filesystem::path& path);

// Atomically writes `layout` to `path` (tmp + rename). Byte-identical to
// the format fox-install's monitors module emits: a generated-by header
// then PRIMARY / PORTRAIT_OUTPUTS / SECONDARY_OUTPUTS / MONITOR_RESOLUTIONS,
// vectors joined by single spaces, all values double-quoted. Returns false
// on rename failure (tmp is cleaned up).
bool write(const std::filesystem::path& path, const Layout& layout);

}  // namespace fox_monitor::sidecar

#endif
