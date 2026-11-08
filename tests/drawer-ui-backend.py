#!/usr/bin/env python3
"""Isolated backend fixture for the QML interaction test; never runs system actions."""
import json
import os
import sys
import time

args = sys.argv[1:]
if args[:1] == ["--config"]:
    args = args[2:]
if args[0] == "commit-days":
    print(json.dumps(dict(ok=True, month=args[1], days=[1, 2], today=3)))
    sys.exit(0)
if args[0] == "view":
    page = args[1]
    if page == "hung":
        time.sleep(30)
    elif page == "slow":
        time.sleep(.4)
    if page == "root":
        items = [dict(id="today", page="root", label="Today", kind="page", icon="today", summary="Friday, November 6")]
        items += [dict(id=name, page=name, label=name.title(), kind="page")
                  for name in ("desk", "sound", "connections", "comfort", "system")]
    elif page == "search":
        query = args[2] if len(args) > 2 else ""
        items = [dict(id="found", label=query, kind="action")]
    elif page == "screenshots":
        items = [dict(id="screenshot-open", label="little-picture-" + str(i) + ".png", kind="action", presentation="screenshot",
                      argument="/sample/shot-" + str(i) + ".png", image="", modifiedAt="2026-11-05 14:30:00 CST", close=True)
                 for i in range(7)]
    elif page == "garden":
        items = []
    elif page == "agents":
        items = [dict(id="agent-jump", label="Claude · Paper notebook", kind="action", icon="message",
                      detail="A little note is ready for you", argument="sample-agent"),
                 dict(id="agent-clear", label="Clear agent notes", kind="action", icon="message",
                      detail="Put these notes away", confirm="Clear all agent notes?")]
    elif page == "downloads":
        items = [dict(id="download-open", label="field-notes.pdf · sample", kind="action", presentation="download", icon="✉",
                      argument="/sample/field-notes.pdf", stamp="8m AGO", detail="PDF · 2.4 MiB · modified 8m ago"),
                 dict(id="download-open", label="little-garden.png · sample", kind="action", presentation="download", icon="✉",
                      argument="/sample/little-garden.png", stamp="2h AGO", detail="Picture · 840.0 KiB · modified 2h ago"),
                 dict(id="download-open", label="weekend-reading.zip · sample", kind="action", presentation="download", icon="✉",
                      argument="/sample/weekend-reading.zip", stamp="1d AGO", detail="Archive · 18.2 MiB · modified 1d ago")]
    elif page == "library":
        items = [dict(id="drive-open", label="Field notes · sample drive", kind="action", presentation="library",
                      argument="/dev/sample1", ejectArgument="/dev/sample", mounted=True,
                      detail="18.4 GiB free of 32.0 GiB · /run/media/you/Field notes"),
                 dict(id="drive-open", label="Photo archive · sample drive", kind="action", presentation="library",
                      argument="/dev/sample2", ejectArgument="/dev/sample", mounted=False,
                      detail="64.0 GiB · On the shelf · Enter to mount")]
    elif page in ("projects", "bookmarks"):
        items = [dict(id="project-open", label="Paper notebook · sample project", kind="action", presentation="project",
                      argument="/sample/paper-notebook", bookmarked=True, detail="Git project · ~/code/paper-notebook"),
                 dict(id="project-open", label="Little garden · sample project", kind="action", presentation="project",
                      argument="/sample/little-garden", bookmarked=False, detail="Python · Git · ~/code/little-garden")]
    else:
        items = [dict(id="volume", label="Volume", kind="slider", value=42),
                 dict(id="nightlight", label="Softer light", kind="toggle", checked=False),
                 dict(id="disabled", label="Unavailable", kind="action", enabled=False)]
    data = dict(id=page, title="Sound", group="sound", items=items)
    if page in ("library", "projects", "bookmarks"):
        data.update(title="Library cards · sample preview" if page == "library" else "Bookmark ribbons · sample preview", group="desk")
    elif page == "downloads":
        data.update(title="Incoming paper tray · sample preview", group="desk")
    elif page == "agents":
        data.update(title="Agent notes", group="desk",
                    items=[dict(id="claude-jump", label="Linux_Theme · Opus 5.5", kind="action", presentation="claude", icon="message",
                                claudeState="working", context=41, argument="%3", detail="41% of its context", enabled=True, fresh=True),
                           dict(id="claude-jump", label="Trader · Opus 5.5", kind="action", presentation="claude", icon="message",
                                claudeState="needs you", context=88, argument="%4", detail="88% of its context", enabled=True)])
    elif page == "garden":
        data.update(title="Commit garden", group="desk",
                    garden=dict(start="2025-11-02", counts=[0] * 360 + [1, 2, 0, 5, 9, 9, 3, 0, 0, 4, 2]))
    if page == "root":
        data["favorites"] = [dict(id="volume", group="sound", label="Volume", kind="slider", value=42)]
        data["items"][2]["summary"] = "42% · speakers"
        data["today"] = dict(battery="80%", batteryState="discharging", notes=2, todo="water the fern",
                             waiting=[dict(project="Paper notebook", argument="sample-agent", asking=False)],
                             claudeWorking=2, claudeUsage="17% of the week left · refills sun", claudeBerry=True,
                             claudeMinutes=130, claudeWeekLeft=17)
    print(json.dumps(data))
else:
    with open(os.environ["FOXML_DRAWER_TEST_LOG"], "a") as stream:
        stream.write(json.dumps(args) + "\n")
    print(json.dumps(dict(ok=True, message="all set.")))
