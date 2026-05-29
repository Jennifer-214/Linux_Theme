#!/usr/bin/env bash
# lint_shell_assets.sh — refuse PAM/sudoers/bootloader surgery in any
# bulk-deployed shell asset.
#
# shared/bin + shared/{hyprland,waybar}_scripts ship to the user
# verbatim (specials.cpp::deploy_dir_files). Those edits are the
# exclusive job of fox-install modules — gated, backed up, covered by
# the fox-health B1/B2 lockout checks. A shell helper doing
# `sed -i '1i ... pam_fprintd' /etc/pam.d/sudo` is the canonical lockout
# footgun (memory: project_pam_fprintd_lockout).
#
# This is the build-time half of the guard; specials.cpp enforces the
# same rule at install time. KEEP THE TWO LISTS IN SYNC.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCAN_DIRS=(shared/bin shared/hyprland_scripts shared/waybar_scripts)

SENSITIVE_RE='(/etc/pam\.d|/etc/sudoers|/boot/loader|/efi/loader|/etc/default/grub|/etc/security/faillock)'
MUTATOR_RE='(sed -i|tee |>|cp |mv |install |ln |dd |truncate|chmod|chown|rm )'

is_shell() {
    case "$1" in
        *.sh) return 0 ;;
    esac
    read -r first < "$1" 2>/dev/null || return 1
    [[ "$first" == '#!'*sh* ]]
}

fail=0
for dir in "${SCAN_DIRS[@]}"; do
    [[ -d "$ROOT/$dir" ]] || continue
    for f in "$ROOT/$dir"/*; do
        [[ -f "$f" ]] || continue
        is_shell "$f" || continue
        # lines that touch a sensitive path, are not comments, and carry
        # a mutation verb
        hits=$(grep -nE "$SENSITIVE_RE" "$f" \
                 | grep -vE '^[0-9]+:[[:space:]]*#' \
                 | grep -E "$MUTATOR_RE")
        if [[ -n "$hits" ]]; then
            echo "FAIL: ${f#$ROOT/} mutates a sensitive system path:"
            echo "$hits" | sed 's/^/    /'
            echo "    → move PAM/sudoers/bootloader edits into a fox-install module"
            fail=1
        fi
    done
done

if [[ $fail -eq 0 ]]; then
    echo "lint_shell_assets: OK — no sensitive-path mutations in deployed shell assets"
fi
exit $fail
