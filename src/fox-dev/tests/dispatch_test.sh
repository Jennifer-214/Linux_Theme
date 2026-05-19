#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX_DEV="$SCRIPT_DIR/../fox-dev"

[[ -x "$FOX_DEV" ]] || { echo "FAIL: $FOX_DEV missing — build first" >&2; exit 1; }

run() {
    local desc="$1"; shift; local expected_rc="$1"; shift; local expected_grep="${1:-}"; shift || true
    local out rc; out=$("$FOX_DEV" "$@" 2>&1) || rc=$?; rc=${rc:-0}
    [[ "$rc" -eq "$expected_rc" ]] || { echo "FAIL: $desc — expected $expected_rc, got $rc" >&2; return 1; }
    [[ -z "$expected_grep" ]] || grep -q "$expected_grep" <<<"$out" || { echo "FAIL: $desc — missing '$expected_grep'" >&2; return 1; }
    echo "  ok: $desc"
}

run "fox-dev (no args)       → help"    0 "subcommand"
run "fox-dev help            → help"    0 "subcommand"   help
run "fox-dev --version       → version" 0 "fox-dev 0"    --version
run "fox-dev bogus           → unknown" 2 "unknown"      bogus

help_out=$("$FOX_DEV" help 2>&1)
for expected in new-project init build-verify test tail distro-build aider template-lint; do
    grep -q "^  $expected\b" <<<"$help_out" || { echo "FAIL: missing '$expected'" >&2; exit 1; }
    echo "  ok: registry contains '$expected'"
done

echo "all fox-dev sanity tests passed"
