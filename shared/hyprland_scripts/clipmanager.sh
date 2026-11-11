#!/usr/bin/env bash
# Compatibility entry point for existing text/image clipboard shortcuts.
case "${1:-text}" in
    text) exec desktop-menu clipboard-text ;;
    image) exec desktop-menu clipboard-images ;;
    *) printf '%s\n' 'Usage: clipmanager.sh [text | image]' >&2; exit 2 ;;
esac
