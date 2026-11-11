#ifndef FOX_INSTALL_GAMING_HPP
#define FOX_INSTALL_GAMING_HPP

#include <string>

namespace fox_install {

// The sed program that uncomments the [multilib] block in pacman.conf.
//
// Idempotent BY CONSTRUCTION (the safe shape): it removes the leading `#` over
// the range `/#[multilib]/ , /#Include = .../`. After it runs, `#[multilib]`
// becomes `[multilib]`, which destroys the range START trigger — so a second
// run matches nothing and is a no-op. It canNOT stack duplicate lines the way
// a blind `tee -a` / prepend would (which re-fires every run and corrupts the file).
//
// Exposed here so test_gaming can run the REAL program against a fixture
// pacman.conf and prove the fixed-point (no reimplementation → no drift).
inline constexpr const char* MULTILIB_UNCOMMENT_SED =
    "/#\\[multilib\\]/,/#Include = \\/etc\\/pacman.d\\/mirrorlist/ s/^#//";

// True iff conf_path already has an uncommented `[multilib]` header. This is
// enable_multilib's idempotency guard — and it matches what the sed writes
// (an uncommented `[multilib]`), so guard and writer agree.
bool multilib_already_enabled(const std::string& conf_path);

}  // namespace fox_install

#endif
