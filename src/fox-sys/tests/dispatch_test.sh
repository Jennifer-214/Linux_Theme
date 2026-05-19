#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX_SYS="$SCRIPT_DIR/../fox-sys"

[[ -x "$FOX_SYS" ]] || { echo "FAIL: $FOX_SYS missing — build first" >&2; exit 1; }

run() {
    local desc="$1"; shift; local expected_rc="$1"; shift; local expected_grep="${1:-}"; shift || true
    local out rc; out=$("$FOX_SYS" "$@" 2>&1) || rc=$?; rc=${rc:-0}
    [[ "$rc" -eq "$expected_rc" ]] || { echo "FAIL: $desc — expected $expected_rc, got $rc" >&2; return 1; }
    [[ -z "$expected_grep" ]] || grep -q "$expected_grep" <<<"$out" || { echo "FAIL: $desc — missing '$expected_grep'" >&2; return 1; }
    echo "  ok: $desc"
}

run "fox-sys (no args)       → help"    0 "subcommand"
run "fox-sys help            → help"    0 "subcommand"   help
run "fox-sys --version       → version" 0 "fox-sys 0"    --version
run "fox-sys bogus           → unknown" 2 "unknown"      bogus

help_out=$("$FOX_SYS" help 2>&1)
for expected in install uninstall doctor hw-info lock menu cheatsheet rollback; do
    grep -q "^  $expected\b" <<<"$help_out" || { echo "FAIL: missing '$expected'" >&2; exit 1; }
    echo "  ok: registry contains '$expected'"
done

echo "all fox-sys sanity tests passed"
