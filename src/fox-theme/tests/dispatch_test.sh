#!/usr/bin/env bash
# Phase 4 sanity test: fox-theme dispatcher.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX_THEME="$SCRIPT_DIR/../fox-theme"

[[ -x "$FOX_THEME" ]] || { echo "FAIL: $FOX_THEME missing — build first" >&2; exit 1; }

run() {
    local desc="$1"; shift; local expected_rc="$1"; shift; local expected_grep="${1:-}"; shift || true
    local out rc; out=$("$FOX_THEME" "$@" 2>&1) || rc=$?; rc=${rc:-0}
    [[ "$rc" -eq "$expected_rc" ]] || { echo "FAIL: $desc — expected $expected_rc, got $rc" >&2; return 1; }
    [[ -z "$expected_grep" ]] || grep -q "$expected_grep" <<<"$out" || { echo "FAIL: $desc — missing '$expected_grep'" >&2; return 1; }
    echo "  ok: $desc"
}

run "fox-theme (no args)     → help"    0 "subcommand"
run "fox-theme help          → help"    0 "subcommand"   help
run "fox-theme --version     → version" 0 "fox-theme 0"  --version
run "fox-theme bogus         → unknown" 2 "unknown"      bogus

help_out=$("$FOX_THEME" help 2>&1)
for expected in tweak wallpaper develop; do
    grep -q "^  $expected\b" <<<"$help_out" || { echo "FAIL: missing '$expected'" >&2; exit 1; }
    echo "  ok: registry contains '$expected'"
done

echo "all fox-theme sanity tests passed"
