#!/usr/bin/env bash
# lint_unit_escaping.sh — generated systemd units must escape % as %%.
#
# systemd expands % specifiers inside unit files (%s = user shell, %Y, %u,
# ...). Code that writes a unit body with a bare %Y/%s ships a corrupted
# command — fox-etcwatch ran `date +/bin/zsh` for two weeks because of
# exactly this (etckeeper.cpp ported the bug verbatim from mappings.sh).
#
# Heuristic, not a parser: in every unit-writer source (contains
# "ExecStart="), examine the ExecStart line plus a 6-line window of
# continuation lines; after collapsing legitimate %% escapes, a %<letter>
# on a line that also carries a shell-format marker (date +, stat -c,
# printf, awk) is an unescaped specifier. The marker requirement is what
# keeps INTENDED systemd specifiers legal — `ExecStart=%h/...` (%h = home
# in a user unit, see vault.cpp) must pass. Widen the window/markers if
# the class recurs in a shape this misses.
set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

mapfile -t WRITERS < <(
    grep -rl 'ExecStart=' "$ROOT/src" --include='*.cpp' 2>/dev/null
    grep -l 'ExecStart=' "$ROOT/mappings.sh" "$ROOT"/shared/bin/* \
        "$ROOT"/shared/hyprland_scripts/*.sh 2>/dev/null
)

fail=0
for f in "${WRITERS[@]}"; do
    [[ -f "$f" ]] || continue
    hits=$(awk '
        /ExecStart=/ { win = NR + 6 }
        NR <= win {
            line = $0
            gsub(/%%/, "", line)
            if (line ~ /(date \+|stat -c|printf|awk)/ && line ~ /%[A-Za-z]/)
                printf "%d: %s\n", NR, $0
        }' "$f")
    if [[ -n "$hits" ]]; then
        echo "FAIL: ${f#$ROOT/} writes a unit body with an unescaped % specifier:"
        echo "$hits" | sed 's/^/    /'
        echo "    → double it: %%Y in the source becomes a literal %Y after systemd expansion"
        fail=1
    fi
done

if [[ $fail -eq 0 ]]; then
    echo "lint_unit_escaping: OK — generated unit bodies escape their % specifiers"
fi
exit $fail
