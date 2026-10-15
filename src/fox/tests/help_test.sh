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

# fox runs fox-legacy / fox-<name> from PATH, so every case runs with a PATH this test controls: its own stub dir
# (here, not /tmp, which may be noexec) then the system dirs, never ~/.local/bin.
STUB=$(mktemp -d "$SCRIPT_DIR/.stub.XXXXXX")
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\necho "leaf:$*"\n' > "$STUB/fox-stubleaf"
chmod +x "$STUB/fox-stubleaf"
legacy_on()  { printf '#!/bin/sh\necho "legacy:$*"\n' > "$STUB/fox-legacy"; chmod +x "$STUB/fox-legacy"; }
legacy_off() { rm -f "$STUB/fox-legacy"; }

run() {
    local desc="$1"; shift
    local expected_rc="$1"; shift
    local expected_grep="${1:-}"; shift || true

    local out rc
    out=$(PATH="$STUB:/usr/bin:/bin" "$FOX" "$@" 2>&1) || rc=$?
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

# Flat commands (installer audit 2026-10-15): not a namespace → fox-legacy gets every argument, else fox-<name>.
legacy_off
run "no fox-legacy: fox stubleaf a b → fox-stubleaf"     0 "^leaf:a b$"          stubleaf a b
run "no fox-legacy: fox ../stubleaf → not a PATH name"  2 "unknown namespace"   ../stubleaf
run "no fox-legacy: fox -x          → unknown, exit 2"  2 "unknown namespace"   -x
run "no fox-legacy: fox help stubleaf → this help"      0 "namespace"           help stubleaf
legacy_on
run "fox-legacy: fox stubleaf a b → fox-legacy first"   0 "^legacy:stubleaf a b$" stubleaf a b
run "fox-legacy: fox bogus → fox-legacy decides"        0 "^legacy:bogus$"      bogus
run "fox-legacy: fox help stubleaf → its help"          0 "^legacy:help stubleaf$" help stubleaf
run "fox-legacy: fox help → still this help"            0 "namespace"           help
legacy_off

echo "all fox sanity tests passed"
