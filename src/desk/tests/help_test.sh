#!/usr/bin/env bash
# Phase 1 sanity test: desk help works and the binary handles its core
# argument-parsing paths correctly. Intentionally minimal — namespace
# dispatch behavior comes online in Phase 2 and gets its own tests.
set -euo pipefail

# Resolve binary relative to this script, not the caller's PWD.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FOX="$SCRIPT_DIR/../desk"

if [[ ! -x "$FOX" ]]; then
    echo "FAIL: $FOX missing or not executable. Build with 'make' first." >&2
    exit 1
fi

# desk runs desk-legacy / desk-<name> / <name> from PATH, so every case runs with a PATH this test controls: its own stub dir
# (here, not /tmp, which may be noexec) then the system dirs, never ~/.local/bin.
STUB=$(mktemp -d "$SCRIPT_DIR/.stub.XXXXXX")
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\necho "leaf:$*"\n' > "$STUB/desk-stubleaf"
chmod +x "$STUB/desk-stubleaf"
mkdir -p "$STUB/home/.local/bin"                               # a tool that lost its prefix: yours, in ~/.local/bin
printf '#!/bin/sh\necho "plain:$*"\n' > "$STUB/home/.local/bin/plainleaf"
chmod +x "$STUB/home/.local/bin/plainleaf"
legacy_on()  { printf '#!/bin/sh\necho "legacy:$*"\n' > "$STUB/desk-legacy"; chmod +x "$STUB/desk-legacy"; }
legacy_off() { rm -f "$STUB/desk-legacy"; }

run() {
    local desc="$1"; shift
    local expected_rc="$1"; shift
    local expected_grep="${1:-}"; shift || true

    local out rc
    out=$(HOME="$STUB/home" PATH="$STUB:/usr/bin:/bin" "$FOX" "$@" 2>&1) || rc=$?
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

run "desk (no args)        → help, exit 0"  0  "namespace"
run "desk help              → help, exit 0"  0  "namespace"           help
run "desk --help            → help, exit 0"  0  "namespace"           --help
run "desk -h                → help, exit 0"  0  "namespace"           -h
run "desk --version        → version, exit 0" 0 "desk 0"              --version
run "desk -V               → version, exit 0" 0 "desk 0"              -V
run "desk bogus            → unknown ns, exit 2" 2 "unknown namespace" bogus

# Flat commands (installer audit 2026-10-15): not a namespace → desk-legacy gets every argument, else desk-<name>, else <name>.
legacy_off
run "no desk-legacy: desk stubleaf a b → desk-stubleaf"   0 "^leaf:a b$"          stubleaf a b
run "no desk-legacy: desk plainleaf x → the plain name"   0 "^plain:x$"           plainleaf x
run "no desk-legacy: desk tail → never the system's tail" 2 "unknown namespace"   tail
run "no desk-legacy: desk ../stubleaf → not a PATH name"  2 "unknown namespace"   ../stubleaf
run "no desk-legacy: desk -x          → unknown, exit 2"  2 "unknown namespace"   -x
run "no desk-legacy: desk help stubleaf → this help"      0 "namespace"           help stubleaf
legacy_on
run "desk-legacy: desk stubleaf a b → desk-legacy first"   0 "^legacy:stubleaf a b$" stubleaf a b
run "desk-legacy: desk bogus → desk-legacy decides"        0 "^legacy:bogus$"      bogus
run "desk-legacy: desk help stubleaf → its help"          0 "^legacy:help stubleaf$" help stubleaf
run "desk-legacy: desk help → still this help"            0 "namespace"           help
legacy_off

echo "all fox sanity tests passed"
