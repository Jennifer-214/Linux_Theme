#ifndef FOX_INSTALL_LOCKDOWN_HEAL_HPP
#define FOX_INSTALL_LOCKDOWN_HEAL_HPP

namespace fox_install {

// True iff a present lockdown=integrity is BRICKING this host: an unsigned
// out-of-tree module (nvidia/DKMS) is present AND lockdown is on the cmdline.
// Strip only then. On an in-tree-only host a present lockdown is intentional,
// harmless hardening and must be left alone (never undo a deliberate --iommu).
// Inline + pure so the test pins the decision without linking the module.
inline bool lockdown_is_bricking(bool unsigned_oot, bool lockdown_present) {
    return unsigned_oot && lockdown_present;
}

}  // namespace fox_install

#endif
