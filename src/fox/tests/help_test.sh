#!/usr/bin/env bash
# Phase 1 sanity test: fox help works and the binary handles its core
# argument-parsing paths correctly. Intentionally minimal — namespace
# dispatch behavior comes online in Phase 2 and gets its own tests.
set -euo pipefail

# Resolve binary relative to this script, not the caller's PWD.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX="$SCRIPT_DIR/../fox"

if [[ ! -x "$FOX" ]]; then
    echo "FAIL: $FOX missing or not executable. Build with 'make' first." >&2
    exit 1
fi

run() {
    local desc="$1"; shift
    local expected_rc="$1"; shift
    local expected_grep="${1:-}"; shift || true

    local out rc
    out=$("$FOX" "$@" 2>&1) || rc=$?
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

run "fox (no args)         → help, exit 0"  0  "namespace"
run "fox help              → help, exit 0"  0  "namespace"           help
run "fox --help            → help, exit 0"  0  "namespace"           --help
run "fox -h                → help, exit 0"  0  "namespace"           -h
run "fox --version         → version, exit 0" 0 "fox 0"              --version
run "fox -V                → version, exit 0" 0 "fox 0"              -V
run "fox bogus             → unknown ns, exit 2" 2 "unknown namespace" bogus

echo "all fox sanity tests passed"
