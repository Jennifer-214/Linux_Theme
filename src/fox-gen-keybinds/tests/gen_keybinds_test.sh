#!/usr/bin/env bash
# Fixture-driven tests for fox-gen-keybinds: splice correctness, the
# undocumented-bind lint, dispatcher-derive, drift detection, and the
# missing-markers guard, across both the tmux and hypr sources.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$SCRIPT_DIR/../fox-gen-keybinds"
[[ -x "$BIN" ]] || { echo "FAIL: $BIN missing — build first" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CONF="$WORK/tmux.conf"
HCONF="$WORK/hypr.conf"
DOC="$WORK/KEYBINDS.md"

cat >"$CONF" <<'EOF'
set -g prefix C-a
# Move focus one pane left.
bind h select-pane -L

bind z resize-pane -Z
EOF

cat >"$HCONF" <<'EOF'
$mainMod = ALT
# ─────────────────────────────────────────
# Test Section
# ─────────────────────────────────────────
# Open a terminal.
bind = $mainMod, RETURN, exec, kitty
bind = $mainMod, 1, workspace, 1
EOF

cat >"$DOC" <<'EOF'
# Keybind Reference

## Hand-curated section (must survive untouched)

| Key | Action |
|-----|--------|
| `Space x` | sentinel — outside markers |

<!-- BEGIN GENERATED: hypr -->
(old hypr content)
<!-- END GENERATED: hypr -->

<!-- BEGIN GENERATED: tmux -->
(old tmux content)
<!-- END GENERATED: tmux -->

## Trailing hand section
EOF

run() { "$BIN" --keybinds "$DOC" --tmux-conf "$CONF" --hypr-conf "$HCONF" "$@"; }

pass=0
check() { if eval "$2"; then echo "  ok: $1"; pass=$((pass+1)); else echo "FAIL: $1" >&2; exit 1; fi; }

# 1. write mode succeeds
run >/dev/null
check "write mode exits 0" "true"

# 2. tmux: generated row + undocumented flag
check "documented tmux bind rendered" "grep -q '\`Ctrl+a h\` | Move focus one pane left' '$DOC'"
check "undocumented tmux bind flagged" "grep -q 'undocumented' '$DOC'"

# 3. hypr: comment + section + dispatcher-derive
check "hypr section header rendered" "grep -q '### Test Section' '$DOC'"
check "hypr comment description"     "grep -q '\`ALT + Enter\` | Open a terminal' '$DOC'"
check "hypr dispatcher-derive"       "grep -q '\`ALT + 1\` | Switch to workspace' '$DOC'"

# 4. content outside both marker regions preserved
check "hand-curated sentinel survives" "grep -q 'sentinel — outside markers' '$DOC'"
check "trailing hand section survives"  "grep -q 'Trailing hand section' '$DOC'"

# 5. idempotent: --check on freshly written doc is in sync (rc 0)
rc=0; run --check >/dev/null || rc=$?
check "--check on synced doc exits 0" "[[ $rc -eq 0 ]]"

# 6. --strict fails because tmux 'z' is undocumented
rc=0; run --strict >/dev/null 2>&1 || rc=$?
check "--strict exits 1 on undocumented bind" "[[ $rc -eq 1 ]]"

# 7. drift: document 'z' in the config, doc now stale → --check exits 1
printf '# Toggle pane zoom.\nbind z resize-pane -Z\n' >>"$CONF"
rc=0; run --check >/dev/null || rc=$?
check "--check detects drift (exit 1)" "[[ $rc -eq 1 ]]"

# 8. missing markers → error exit 1
NOMARK="$WORK/no-markers.md"
printf '# Doc with no markers\n' >"$NOMARK"
rc=0; "$BIN" --keybinds "$NOMARK" --tmux-conf "$CONF" --hypr-conf "$HCONF" >/dev/null 2>&1 || rc=$?
check "missing markers exits 1" "[[ $rc -eq 1 ]]"

echo "all fox-gen-keybinds tests passed ($pass checks)"
