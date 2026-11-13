#!/usr/bin/env bash
# tests/roundtrip.sh — verifies install→update is a no-op on templates/.
#
# What it checks: render templates with a theme, deploy to live config,
# pull live config back into templates, and assert templates/ is unchanged.
# A drift means render.sh and update.sh aren't perfect inverses, or a
# templated file in shared/ has logic the templates/ haven't caught up
# with (I-04 violation).
#
# Run on a configured machine. Side effect: rewrites your live config
# from the current templates (with backups under ~/.theme_backups/).
#
# Usage: ./tests/roundtrip.sh [theme-name]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
THEME="${1:-Classic}"

# Refuse on dirty templates/ — would obscure drift detection
if ! git diff --quiet -- templates/; then
    echo "ERROR: templates/ has uncommitted changes — commit or stash first."
    git --no-pager diff --stat -- templates/
    exit 2
fi

echo "==> ./install.sh $THEME --render-only --yes"
./install.sh "$THEME" --render-only --yes >/dev/null

echo "==> ./update.sh"
./update.sh >/dev/null

if ! git diff --quiet -- templates/; then
    echo ""
    echo "FAIL: templates/ drifted after install→update roundtrip."
    git --no-pager diff --stat -- templates/
    echo ""
    echo "Either:"
    echo "  - render.sh and update.sh aren't perfect inverses (file a bug), or"
    echo "  - a templated file in shared/ has logic the templates/ haven't caught up with."
    exit 1
fi

echo "PASS: roundtrip clean (no template drift)"
