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

// True iff `base_args` is absent from the current cmdline text, i.e. a prepend
// is needed. Routing the decision through this pure check (instead of an inline
// grep) means a re-run on an already-configured host never double-prepends.
// Exposed so test_iommu pins the idempotency without sudo.
bool needs_prepend(const std::string& cmdline_text, const std::string& base_args);

// True iff `grub_cfg` looks like a real generated grub.cfg (non-empty + carries
// at least one menuentry). The validate-before-swap gate on the GRUB path: a
// failed/garbled grub-mkconfig trips this and the working grub.cfg is kept.
bool grub_cfg_sane(const std::string& grub_cfg);

// Builds the sed program that prepends `args` inside GRUB_CMDLINE_LINUX_DEFAULT.
// Exposed (like LOCKDOWN_STRIP_SED) so the test runs the REAL program against a
// fixture — no reimplementation to drift from production.
std::string grub_prepend_sed(const std::string& args);

}  // namespace fox_install

#endif
