#!/usr/bin/env python3
"""Isolated backend fixture for the QML interaction test; never runs system actions."""
import json
import os
import sys

args = sys.argv[1:]
if args[:1] == ["--config"]:
    args = args[2:]
if args[0] == "view":
    page = args[1]
    if page == "root":
        items = [dict(id=name, page=name, label=name.title(), kind="page")
                 for name in ("desk", "sound", "connections", "comfort", "system")]
    elif page == "search":
        query = args[2] if len(args) > 2 else ""
        items = [dict(id="found", label=query, kind="action")]
    else:
        items = [dict(id="volume", label="Volume", kind="slider", value=42),
                 dict(id="nightlight", label="Softer light", kind="toggle", checked=False),
                 dict(id="disabled", label="Unavailable", kind="action", enabled=False)]
    print(json.dumps(dict(id=page, title="Sound", group="sound", items=items)))
else:
    with open(os.environ["FOXML_DRAWER_TEST_LOG"], "a") as stream:
        stream.write(json.dumps(args) + "\n")
    print(json.dumps(dict(ok=True, message="all set.")))
