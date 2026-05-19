#!/usr/bin/env bash
# Phase 3 sanity test: fox-sec dispatcher routes correctly + lists
# all registered subcommands. Doesn't execvp into actual leaves.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX_SEC="$SCRIPT_DIR/../fox-sec"

if [[ ! -x "$FOX_SEC" ]]; then
    echo "FAIL: $FOX_SEC missing or not executable. Build with 'make' first." >&2
    exit 1
fi

run() {
    local desc="$1"; shift
    local expected_rc="$1"; shift
    local expected_grep="${1:-}"; shift || true

    local out rc
    out=$("$FOX_SEC" "$@" 2>&1) || rc=$?
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

run "fox-sec (no args)       → help"        0 "subcommand"
run "fox-sec help             → help"       0 "subcommand"   help
run "fox-sec --help           → help"       0 "subcommand"   --help
run "fox-sec -h               → help"       0 "subcommand"   -h
run "fox-sec --version        → version"    0 "fox-sec 0"    --version
run "fox-sec -V               → version"    0 "fox-sec 0"    -V
run "fox-sec bogus            → unknown"    2 "unknown"      bogus

# Spot-check that representative subcommands from each group are registered.
help_out=$("$FOX_SEC" help 2>&1)
for expected in audit snitch firewall vpn fingerprint jail usb arm honey dashboard; do
    if ! grep -q "^  $expected\b" <<<"$help_out"; then
        echo "FAIL: 'fox-sec help' output missing expected subcommand '$expected'" >&2
        exit 1
    fi
    echo "  ok: registry contains '$expected'"
done

echo "all fox-sec sanity tests passed"
