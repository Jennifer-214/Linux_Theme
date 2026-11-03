#!/usr/bin/env bash
# Compatibility entry point for existing text/image clipboard shortcuts.
case "${1:-text}" in
    text) exec fox-desktop-menu clipboard-text ;;
    image) exec fox-desktop-menu clipboard-images ;;
    *) printf '%s\n' 'Usage: clipmanager.sh [text | image]' >&2; exit 2 ;;
esac
