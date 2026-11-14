#!/usr/bin/env bash
# tests/roundtrip.sh — verifies that right after an install nothing deployed differs from what the repo lays.
#
# What it checks: render and deploy a theme, then run update.sh, which compares every deployed file with what the
# templates render to (and shared/ files with theirs). A difference right after an install means a step deploys
# something other than the template (a module rewriting a file it was handed, or a template the renderer and the
# deploy disagree on). update.sh writes nothing, so templates/ must still be clean afterwards.
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

echo "==> ./update.sh $THEME"
report="$(./update.sh "$THEME")"

if ! git diff --quiet -- templates/; then
    echo "FAIL: update.sh changed templates/; it must only report."
    git --no-pager diff --stat -- templates/
    exit 1
fi
if ! grep -q "Every deployed file matches" <<<"$report"; then
    echo ""
    echo "FAIL: right after the install, deployed files differ from what the repo lays:"
    echo "$report"
    exit 1
fi

echo "PASS: roundtrip clean (what is deployed is what the repo lays)"
