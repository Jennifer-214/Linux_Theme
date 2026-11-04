#!/usr/bin/env bash
# Linux_Theme — One-command bootstrap.
#
# Usage (run on a fresh Arch + Hyprland laptop):
#   curl -fsSL https://raw.githubusercontent.com/Jennifer-214/Linux_Theme/main/bootstrap.sh | bash
#
# Optional theme arg:
#   curl -fsSL .../bootstrap.sh | bash -s Cave_Data_Center
#
# Honors env vars:
#   FOXML_DIR  — where to clone the repo (default: ~/code/Linux_Theme)
#   FOXML_REPO — git URL to clone        (default: GitHub mirror)
#
# The repo lands inside ~/code/ alongside everything --github clones, so a
# fresh box ends up with one consolidated workspace at ~/code/.

set -euo pipefail

THEME_NAME="${1:-FoxML_Classic}"
FOXML_REPO="${FOXML_REPO:-https://github.com/Jennifer-214/Linux_Theme.git}"
FOXML_DIR="${FOXML_DIR:-$HOME/code/Linux_Theme}"

echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│              Linux_Theme — Bootstrap                             │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo "  Theme:     $THEME_NAME"
echo "  Repo:      $FOXML_REPO"
echo "  Clone to:  $FOXML_DIR"
echo ""

# ─── Sanity checks ──────────────────────────────────────────────────
if ! command -v pacman >/dev/null 2>&1; then
    echo "ERROR: pacman not found — this installer requires Arch Linux." >&2
    exit 1
fi

# Check free space on /boot (or / if /boot is not separate)
_boot_path="/boot"
[[ ! -d "$_boot_path" ]] && _boot_path="/"
_boot_info=$(df -Pk "$_boot_path" | awk 'NR==2 {print $2" "$4}')
read -r _boot_total_kb _boot_free_kb <<< "$_boot_info"
_boot_total_mb=$((_boot_total_kb / 1024))
_boot_free_mb=$((_boot_free_kb / 1024))
_rec_total_mb=1024
_min_free_mb=256

if (( _boot_total_mb < _rec_total_mb || _boot_free_mb < _min_free_mb )); then
    echo "WARNING: Low disk space on $_boot_path."
    echo "         Capacity:  ${_boot_total_mb}MB (${_boot_free_mb}MB free)"
    echo "         FoxML recommends at least ${_rec_total_mb}MB total capacity for safe updates."

    if (( _boot_free_mb < 128 )); then
        echo "ERROR: Only ${_boot_free_mb}MB available. This is critically low."
        echo "       Free at least 128MB on your boot partition to continue."
        exit 1
    fi
    echo "         Continuing with bootstrap..."
fi

# Clear sudo prompt up front so the rest can run unattended
echo "Caching sudo (needed for pacman, greetd config, etc.)..."
sudo -v || { echo "ERROR: sudo required."; exit 1; }
( while true; do sudo -n true; sleep 50; done 2>/dev/null ) &
SUDO_PID=$!
trap 'kill "$SUDO_PID" 2>/dev/null || true' EXIT

# ─── Bootstrap deps ─────────────────────────────────────────────────
need_install=()
command -v git  >/dev/null 2>&1 || need_install+=(git)
command -v curl >/dev/null 2>&1 || need_install+=(curl)
command -v make >/dev/null 2>&1 || need_install+=(base-devel)
if [[ ${#need_install[@]} -gt 0 ]]; then
    echo "Installing bootstrap deps: ${need_install[*]}"
    sudo pacman -S --needed --noconfirm "${need_install[@]}"
fi

# ─── Clone or update ────────────────────────────────────────────────
if [[ -d "$FOXML_DIR/.git" ]]; then
    echo "Repo already cloned — pulling latest..."
    git -C "$FOXML_DIR" pull --ff-only
else
    echo "Cloning $FOXML_REPO → $FOXML_DIR..."
    git clone --depth 1 "$FOXML_REPO" "$FOXML_DIR"
fi

# ─── Run installer non-interactively ────────────────────────────────
# --full enables every opt-in module except --xgboost. NVIDIA detection
# stays here because --full doesn't auto-detect — it'd be wrong to pull
# the proprietary driver stack onto AMD/Intel-only boxes.
INSTALL_FLAGS=(--full --yes)
for dev in /sys/bus/pci/devices/*/; do
    [[ "$(cat "$dev/vendor" 2>/dev/null)" == "0x10de" ]] || continue
    [[ "$(cat "$dev/class" 2>/dev/null)" == 0x03* ]] || continue
    INSTALL_FLAGS+=(--nvidia)
    echo "NVIDIA GPU detected at $(basename "$dev") — adding --nvidia to install."
    break
done

cd "$FOXML_DIR"

# ─── Choose installer ──────────────────────────────────────────────
# C++ (./install.sh + native fox-install) is the default. Legacy bash
# (./legacy/install.sh, frozen at pre-cutover SHA 596a81a) is the
# fallback for users who hit a C++ bug on a fresh laptop.
#
# Override the prompt with FOXML_INSTALLER=cpp|bash, or via --yes in
# the bootstrap args (curl-pipe path defaults to C++ silently).
INSTALLER_PATH="./install.sh"
INSTALLER_LABEL="C++ orchestrator"
_force=""
case "${FOXML_INSTALLER:-}" in
    cpp|c++)        _force=cpp ;;
    bash|legacy)    _force=bash ;;
esac

if [[ -z "$_force" && -t 0 ]]; then
    echo ""
    echo "  ╭───────────────────────────────────────────╮"
    echo "  │  FoxML Theme Hub — pick install path      │"
    echo "  ├───────────────────────────────────────────┤"
    echo "  │   1) C++ (recommended)                    │"
    echo "  │      Native orchestrator + --full review  │"
    echo "  │      wizard + --resume / --phase / --only │"
    echo "  │      Mostly works — in progress for       │"
    echo "  │      testing.                             │"
    echo "  │                                           │"
    echo "  │   2) Bash (legacy fallback)               │"
    echo "  │      Pre-cutover bash installer, frozen   │"
    echo "  │      at the migration cutover. Safe       │"
    echo "  │      fallback if the C++ path breaks.     │"
    echo "  ╰───────────────────────────────────────────╯"
    read -r -n 1 -p "  Pick [1/2, default 1]: " _pick
    echo "" # New line after single-char input
    case "$_pick" in
        2|bash|legacy|b) _force=bash ;;
        *) _force=cpp ;;
    esac
fi

if [[ "$_force" == "bash" ]]; then
    INSTALLER_PATH="./legacy/install.sh"
    INSTALLER_LABEL="bash legacy installer"
fi

echo ""
echo "Running $INSTALLER_LABEL: $INSTALLER_PATH $THEME_NAME ${INSTALL_FLAGS[*]}"
echo ""
"$INSTALLER_PATH" "$THEME_NAME" "${INSTALL_FLAGS[@]}"

echo ""
echo "╭──────────────────────────────────────────────────────────────────╮"
echo "│                       Bootstrap Complete                         │"
echo "╰──────────────────────────────────────────────────────────────────╯"
echo "  Reload Hyprland:   hyprctl reload"
echo "  Restart bar:       pkill waybar && waybar &"
echo "  Open new shell to load the caramel zsh prompt."
