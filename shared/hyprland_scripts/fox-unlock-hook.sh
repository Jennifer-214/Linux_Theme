#!/usr/bin/env bash
# fox-unlock-hook.sh — invoked when the screen unlocks. Restores
# USBGuard's implicit-policy back to "apply-policy" so devices plugged
# in WHILE you're at the desk are evaluated normally instead of
# blanket-blocked. Pair to fox-lock's lock-on-screen-lock hardening.
#
# Wire-up: hypridle's unlock_cmd, OR called from a hyprlock post-auth
# hook. For now the wire-up is via hypridle (configured by mappings.sh
# alongside lock_cmd).

set -u

if command -v usbguard >/dev/null 2>&1 && systemctl is-active --quiet usbguard 2>/dev/null; then
    usbguard set-parameter ImplicitPolicyTarget apply-policy 2>/dev/null || true
fi

# Clear a wedged fingerprint reader on unlock (suspend/idle path). hyprlock
# holds pam_fprintd while locked; a Synaptics close-timeout can leave the
# reader "already claimed", silently breaking fingerprint-for-sudo until
# fprintd is bounced. fox-fingerprint reset does the restart (password-less
# via the fprintd_reset_polkit grant). The manual-lock path is handled in
# fox-lock's own post-unlock cleanup.
# Gated on the polkit grant existing (fprintd_reset_polkit module) — without
# it the restart would pop an auth dialog on every unlock.
[ -f /etc/polkit-1/rules.d/49-foxml-fprintd.rules ] \
    && command -v fox-fingerprint >/dev/null 2>&1 \
    && fox-fingerprint reset >/dev/null 2>&1 || true
