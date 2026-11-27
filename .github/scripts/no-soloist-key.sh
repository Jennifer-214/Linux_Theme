#!/usr/bin/env bash
# Fails when a Soloist API key (spak_…) is in any commit of any branch, or in the working tree.
# Says where, never the key: CI logs of a public repo are public.
set -euo pipefail

pattern='spak_[A-Za-z0-9_-]{20,}'
found=0

commits=$(git log --all -E -G "$pattern" --format=%H)
for commit in $commits; do
    found=1
    files=$(git show --format= --name-only "$commit" | while read -r f; do
        git show "$commit" -- "$f" | grep -qE "^[+-].*$pattern" && printf ' %s' "$f"; done)
    echo "Soloist API key in commit $(git log -1 --format='%h %s' "$commit"):${files}"
done

if files=$(git grep -lE "$pattern" 2>/dev/null); then
    found=1
    echo "Soloist API key in the working tree: ${files//$'\n'/ }"
fi

if [ "$found" = 1 ]; then
    echo "Remove it (history too, if it was pushed) and get a new key: the old one is public."
    exit 1
fi
echo "no Soloist API key in any commit"
