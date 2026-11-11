---
description: Wrap up for the night — a where-we-left-off note, what is uncommitted, then the goodnight page
---

We're stopping for the night. Wrap up gently, and change nothing in the project:

1. Write a short "where we left off" note, five to ten lines: what we did this session, what comes next, and
   anything half-done or waiting on a decision. Start it with one line `next: <the very next step>`; the
   drawer's morning slip quotes that line. Save it to
   `${XDG_STATE_HOME:-~/.local/state}/foxml/goodnight/<name>.md`, where `<name>` is the folder name of the
   project's git root (`git rev-parse --show-toplevel`, or the working folder outside git), replacing an older
   one, and show it here. The next session in this project points to it.
2. Run `git status --short` in the project and list anything uncommitted. Do not commit, stash, push or
   discard anything; just say what is there.
3. Run `~/.local/bin/desktop-menu power` to open the Power page, which says goodnight at night.
4. End with one warm line of goodnight.
