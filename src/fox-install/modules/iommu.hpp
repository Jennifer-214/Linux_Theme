#ifndef FOX_INSTALL_IOMMU_HPP
#define FOX_INSTALL_IOMMU_HPP

#include <string>

namespace fox_install {

// Builds the IOMMU kernel-cmdline args for the detected CPU vendor.
// lockdown=integrity is appended ONLY when add_lockdown is true — it is
// withheld on hosts with unsigned out-of-tree modules (nvidia/DKMS), where
// it would block the module from loading and force a software-render CPU
// storm. Exposed so test_iommu pins the decision without booting a VM.
std::string build_iommu_args(const std::string& vendor, bool add_lockdown);

// sed program that removes " lockdown=integrity" from a cmdline line. Used
// to self-heal a host an earlier (unconditional) install bricked. Idempotent
// by construction: a second pass finds nothing to remove, so it can never
// stack damage. Exposed so test_iommu runs the REAL program against a
// fixture entry (no reimplementation → no drift), the same discipline as
// gaming.hpp::MULTILIB_UNCOMMENT_SED.
inline constexpr const char* LOCKDOWN_STRIP_SED = "s/ lockdown=integrity//g";

// True iff a systemd-boot `options` line still carries the two tokens a
// bootable entry must keep: root= and a standalone rw. The post-edit
// self-check — a sed that mangles the line trips this and triggers the
// auto-revert from the per-run .foxml-preedit copy.
bool cmdline_options_sane(const std::string& options_line);

}  // namespace fox_install

#endif
