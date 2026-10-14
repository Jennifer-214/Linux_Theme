// core/hardware.hpp — RAM / VRAM probes for the models module (the model tier keys off RAM).
#ifndef FOX_INSTALL_CORE_HARDWARE_HPP
#define FOX_INSTALL_CORE_HARDWARE_HPP

#include "../../fox-common/shell.hpp"

#include <cstdlib>
#include <fstream>
#include <string>

namespace fox_install::hw {

// MemTotal (KB) → GB, ceiling.
inline int ram_gb() {
    std::ifstream f("/proc/meminfo");
    std::string key;
    long kb = 0;
    while (f >> key) {
        if (key == "MemTotal:") { f >> kb; break; }
    }
    return static_cast<int>((kb + 1024L * 1024L - 1) / (1024L * 1024L));
}

// Best-effort nvidia-smi probe; 0 when absent (CPU-only / AMD / Intel).
inline int vram_gb() {
    std::string out;
    if (!sh::capture({"nvidia-smi", "--query-gpu=memory.total",
                      "--format=csv,noheader,nounits"}, out)) return 0;
    long mb = std::strtol(out.c_str(), nullptr, 10);
    return static_cast<int>((mb + 1023) / 1024);
}

}  // namespace fox_install::hw

#endif
