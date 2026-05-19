#!/usr/bin/env bash
# Phase 2 sanity test: fox-ai dispatcher routes correctly + lists
# all 23 registered subcommands. Doesn't execvp into actual leaves —
# leaf behavior is tested separately by each leaf's own test.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX_AI="$SCRIPT_DIR/../fox-ai"

if [[ ! -x "$FOX_AI" ]]; then
    echo "FAIL: $FOX_AI missing or not executable. Build with 'make' first." >&2
    exit 1
fi

run() {
    local desc="$1"; shift
    local expected_rc="$1"; shift
    local expected_grep="${1:-}"; shift || true

    local out rc
    out=$("$FOX_AI" "$@" 2>&1) || rc=$?
    rc=${rc:-0}

    if [[ "$rc" -ne "$expected_rc" ]]; then
        echo "FAIL: $desc — expected exit $expected_rc, got $rc" >&2
        echo "      args: $*" >&2
        echo "      output: $out" >&2
        return 1
    fi

    if [[ -n "$expected_grep" ]] && ! grep -q "$expected_grep" <<<"$out"; then
        echo "FAIL: $desc — output missing expected text '$expected_grep'" >&2
        echo "      output: $out" >&2
        return 1
    fi

    echo "  ok: $desc"
}

run "fox-ai (no args)        → help"        0 "subcommand"
run "fox-ai help              → help"       0 "subcommand"   help
run "fox-ai --help            → help"       0 "subcommand"   --help
run "fox-ai -h                → help"       0 "subcommand"   -h
run "fox-ai --version         → version"    0 "fox-ai 0"     --version
run "fox-ai -V                → version"    0 "fox-ai 0"     -V
run "fox-ai bogus             → unknown"    2 "unknown"      bogus

# Spot-check that the registry actually contains the 23 entries we
# expect — checks a few representative names from different groups.
# (Don't enumerate all 23 — adding a new subcommand shouldn't require
# a test edit; spot checks catch "I deleted half the registry by
# accident" without being brittle.)
help_out=$("$FOX_AI" help 2>&1)
for expected in doctor snitch review commit cmd swap status strategy setup-project; do
    if ! grep -q "^  $expected\b" <<<"$help_out"; then
        echo "FAIL: 'fox-ai help' output missing expected subcommand '$expected'" >&2
        exit 1
    fi
    echo "  ok: registry contains '$expected'"
done

echo "all fox-ai sanity tests passed"
