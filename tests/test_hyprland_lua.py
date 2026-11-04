#!/usr/bin/env python3
"""tests/test_hyprland_lua.py — the Lua config Hyprland 0.57 needs stays equivalent to the hyprlang one.

Hyprland 0.57 reads only hyprland.lua; 0.56 and older read hyprland.conf. The repo ships both, so:
- every shared module's .conf and .lua bind the same keys (same flags, same submap, same exec commands)
  and carry the same env, autostart, window/layer/workspace rules; the theme templates the same
  animations, curves and env;
- shared/hyprland.lua loads only modules the installer provides, and the theme row is deployed;
- the greeter launcher starts Hyprland with the config the installed release can parse;
- with Hyprland >= 0.57 installed, every theme's assembled Lua config and the greeter config pass
  `Hyprland --verify-config -c` (skipped elsewhere, e.g. CI).
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODS = ROOT / "shared" / "hyprland_modules"
FLAG_LETTERS = {"e": "repeating", "l": "locked", "m": "mouse", "r": "release",
                "n": "non_consuming", "t": "transparent", "i": "ignore_mods"}


# ─── a small reader for the Lua these files use ───────────────────────────────

def _scan_call(text, j):
    """From just after an opening '(' at depth 1, return the index after its matching ')'."""
    depth, quote = 1, None
    while j < len(text) and depth:
        c = text[j]
        if quote:
            if c == "\\":
                j += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif text.startswith("--", j):
            j = text.find("\n", j)
            if j < 0:
                break
            continue
        elif c in "({":
            depth += 1
        elif c in ")}":
            depth -= 1
        j += 1
    return j


def lua_calls(text, name):
    """(start, argtext) for every `name(...)` call that isn't commented out."""
    needle, i, out = name + "(", 0, []
    while True:
        i = text.find(needle, i)
        if i < 0:
            return out
        line_start = text.rfind("\n", 0, i) + 1
        if "--" in text[line_start:i]:
            i += len(needle)
            continue
        j = _scan_call(text, i + len(needle))
        out.append((i, text[i + len(needle):j - 1]))
        i = j


def split_args(s):
    args, depth, quote, cur = [], 0, None, ""
    for idx, c in enumerate(s):
        if quote:
            cur += c
            if c == quote and s[idx - 1] != "\\":
                quote = None
            continue
        if c in "\"'":
            quote = c
        elif c in "({":
            depth += 1
        elif c in ")}":
            depth -= 1
        elif c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
            continue
        cur += c
    if cur.strip():
        args.append(cur.strip())
    return args


def lua_eval_str(expr, env):
    """Evaluate `"a" .. name .. os.getenv("X")` → str ($X for env lookups); None if unknown."""
    # Compare the default session paths when an optional XDG override is unset.
    # Keep the required HOME lookup symbolic, just like the legacy $HOME path.
    expr = re.sub(r'\(os\.getenv\("XDG_CONFIG_HOME"\) or (os\.getenv\("HOME"\) \.\. "/\.config")\)',
                  lambda match: match.group(1), expr)
    out = ""
    for piece in re.split(r"\s*\.\.\s*", expr.strip()):
        m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', piece)
        if m:
            out += re.sub(r"\\(.)", r"\1", m.group(1))
            continue
        m = re.fullmatch(r'os\.getenv\("(\w+)"\)', piece)
        if m:
            out += "$" + m.group(1)
            continue
        if piece in env:
            out += env[piece]
            continue
        return None
    return out


def lua_locals(text):
    env = {}
    for m in re.finditer(r"^local (\w+) = (.+)$", text, re.M):
        v = lua_eval_str(m.group(2), env)
        if v is not None:
            env[m.group(1)] = v
    return env


def keyset(spec):
    parts = [p.strip() for p in spec.split("+") if p.strip()]
    return frozenset(p.upper() for p in parts[:-1]), parts[-1].lower()


def lua_binds(text):
    """{(mods, key, submap, flags): set of exec commands (or {None})}."""
    env = lua_locals(text)
    submaps = [(s, s + len(a), split_args(a)[0].strip('"')) for s, a in lua_calls(text, "hl.define_submap")]
    out = {}
    for start, argtext in lua_calls(text, "hl.bind"):
        args = split_args(argtext)
        mods, key = keyset(lua_eval_str(args[0], env))
        submap = next((n for s, e, n in submaps if s < start < e), "")
        flags = frozenset(re.findall(r"(\w+)\s*=\s*true", args[2])) if len(args) > 2 else frozenset()
        m = re.fullmatch(r"hl\.dsp\.exec_cmd\((.*)\)", args[1], re.S)
        cmd = lua_eval_str(m.group(1), env) if m else None
        out.setdefault((mods, key, submap, flags), set()).add(cmd)
    return out


# ─── the hyprlang side ─────────────────────────────────────────────────────────

def conf_lines(text):
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            yield line


def conf_binds(text):
    vars_, submap, out = {}, "", {}
    expand = lambda s: re.sub(r"\$(\w+)", lambda m: vars_.get(m.group(1), m.group(0)), s)
    for line in conf_lines(text):
        m = re.fullmatch(r"\$(\w+)\s*=\s*(.*)", line)
        if m:
            vars_[m.group(1)] = expand(m.group(2))
            continue
        m = re.fullmatch(r"submap\s*=\s*(\S+)", line)
        if m:
            submap = "" if m.group(1) == "reset" else m.group(1)
            continue
        m = re.fullmatch(r"bind([a-z]*)\s*=\s*([^,]*),\s*([^,]+?)\s*,\s*([^,]+?)\s*(?:,\s*(.*))?", line)
        if not m:
            continue
        letters, mods, key, disp, args = m.groups()
        mods = frozenset(t.upper() for t in expand(mods).split())
        flags = frozenset(FLAG_LETTERS[c] for c in letters)
        cmd = expand(args or "") if disp == "exec" else None
        out.setdefault((mods, key.lower(), submap, flags), set()).add(cmd)
    return out


def conf_env(text):
    return {m.group(1): m.group(2) for m in (re.fullmatch(r"env\s*=\s*([^,]+?)\s*,\s*(.*)", l)
                                             for l in conf_lines(text)) if m}


def lua_env(text):
    env = lua_locals(text)
    out = {}
    for _, a in lua_calls(text, "hl.env"):
        name, value = (lua_eval_str(x, env) for x in split_args(a)[:2])
        out[name] = value
    return out


def conf_autostart(text):
    return [l.split("=", 1)[1].strip() for l in conf_lines(text) if l.startswith("exec-once")]


def lua_autostart(text):
    env = lua_locals(text)
    return [lua_eval_str(a, env) for _, a in lua_calls(text, "hl.exec_cmd")]


def conf_window_rules(text):
    rules, cur = {}, None
    for line in conf_lines(text):
        if re.fullmatch(r"windowrule\s*\{", line):
            cur = {}
        elif line == "}" and cur is not None:
            rules[cur.get("name")] = cur
            cur = None
        elif cur is not None:
            k, _, v = line.partition("=")
            cur[k.strip()] = v.strip()
    return {n: r.get("match:class") for n, r in rules.items()}


def lua_window_rules(text):
    out = {}
    for _, a in lua_calls(text, "hl.window_rule"):
        out[re.search(r'name = "([^"]+)"', a).group(1)] = re.search(r'class = "([^"]+)"', a).group(1)
    return out


def conf_layer_rules(text):
    out = set()
    for l in conf_lines(text):
        m = re.fullmatch(r"layerrule\s*=\s*(.*)", l)
        if m:
            f = dict(x.strip().partition(" ")[::2] for x in m.group(1).split(","))
            out.add((f["match:namespace"].strip(), f.get("ignore_alpha", "").strip()))
    return out


def lua_layer_rules(text):
    return {(re.search(r'namespace = "([^"]+)"', a).group(1), re.search(r"ignore_alpha = ([\d.]+)", a).group(1))
            for _, a in lua_calls(text, "hl.layer_rule")}


def conf_workspace_rules(text):
    out = set()
    for l in conf_lines(text):
        m = re.fullmatch(r"workspace\s*=\s*([^,]+?)\s*,\s*(.*)", l)
        if m:
            out.add((m.group(1), frozenset(x.strip() for x in m.group(2).split(","))))
    return out


def lua_workspace_rules(text):
    out = set()
    for _, a in lua_calls(text, "hl.workspace_rule"):
        ws = re.search(r'workspace = "([^"]+)"', a).group(1)
        rest = set()
        if re.search(r"default = true", a):
            rest.add("default:true")
        m = re.search(r'monitor = "([^"]+)"', a)
        if m:
            rest.add("monitor:" + m.group(1))
        out.add((ws, frozenset(rest)))
    return out


class ModuleParity(unittest.TestCase):
    """Each shared module: the .lua says what the .conf says."""

    def pairs(self):
        found = sorted(p.stem for p in MODS.glob("*.lua"))
        self.assertTrue(found, "no Lua modules")
        for stem in found:
            conf = MODS / (stem + ".conf")
            self.assertTrue(conf.exists(), f"{stem}.lua has no .conf twin")
            yield stem, conf.read_text(), (MODS / (stem + ".lua")).read_text()

    def test_xdg_config_fallback_in_environment_reader(self):
        expr = '(os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/foxml/qt-palette.json"'
        self.assertEqual(lua_eval_str(expr, {}), "$HOME/.config/foxml/qt-palette.json")
        self.assertIsNone(lua_eval_str("unknown_config .. \"/palette.json\"", {}))

    def test_binds(self):
        for stem, conf, lua in self.pairs():
            with self.subTest(module=stem):
                c, l = conf_binds(conf), lua_binds(lua)
                self.assertEqual(set(c), set(l), "bound keys differ")
                for k in c:
                    self.assertEqual(c[k], l[k], f"commands differ for {sorted(k[0])}+{k[1]}")
        self.assertGreater(len(conf_binds((MODS / "keybinds.conf").read_text())), 50)

    def test_env_autostart_rules(self):
        for stem, conf, lua in self.pairs():
            with self.subTest(module=stem):
                self.assertEqual(conf_env(conf), lua_env(lua), "env differs")
                self.assertEqual(conf_autostart(conf), lua_autostart(lua), "autostart differs")
                self.assertEqual(conf_window_rules(conf), lua_window_rules(lua), "window rules differ")
                self.assertEqual(conf_layer_rules(conf), lua_layer_rules(lua), "layer rules differ")
                self.assertEqual(conf_workspace_rules(conf), lua_workspace_rules(lua), "workspace rules differ")

    def test_theme_template(self):
        conf = (ROOT / "templates/hyprland/theme.conf").read_text()
        lua = (ROOT / "templates/hyprland/theme.lua").read_text()
        squash = lambda s: re.sub(r"\s+", "", s)
        conf_anims = {}
        for l in conf_lines(conf):
            m = re.fullmatch(r"animation\s*=\s*(.*)", l)
            if m:
                f = [x.strip() for x in m.group(1).split(",")]
                conf_anims[f[0]] = (f[1] == "1", f[2] if f[1] == "1" else None,
                                    f[3] if len(f) > 3 else None, f[4] if len(f) > 4 else None)
        lua_anims = {}
        for _, a in lua_calls(lua, "hl.animation"):
            def g(k):
                m = re.search(k + r'\s*=\s*(?:"([^"]*)"|([^,}\s]+))', a)
                return (m.group(1) if m.group(1) is not None else m.group(2)) if m else None
            enabled = g("enabled") == "true"
            lua_anims[g("leaf")] = (enabled, g("speed") if enabled else None, g("bezier"), g("style"))
        self.assertEqual(conf_anims, lua_anims)
        conf_curves = {f[0]: [squash(x) for x in f[1:]] for f in
                       ([x.strip() for x in m.group(1).split(",")] for m in
                        (re.fullmatch(r"bezier\s*=\s*(.*)", l) for l in conf_lines(conf)) if m)}
        def points(a):   # by brace depth: point values may hold {{TOKENS}}
            j = a.index("{", a.index("points"))
            inner = a[j + 1:_scan_call(a, j + 1) - 1]
            return [squash(x) for pt in split_args(inner) for x in split_args(pt.strip()[1:-1])]
        lua_curves = {split_args(a)[0].strip('"'): points(a) for _, a in lua_calls(lua, "hl.curve")}
        self.assertEqual(conf_curves, lua_curves)
        self.assertEqual(conf_env(conf), lua_env(lua))


class EntryAndDeploy(unittest.TestCase):
    def test_entry_loads_only_shipped_modules(self):
        text = (ROOT / "shared/hyprland.lua").read_text()
        table = re.search(r"local modules = \{(.*?)\}", text, re.S).group(1)
        names = re.findall(r'"(\w+)"', table)
        self.assertIn("keybinds", names)
        for n in names:
            src = ROOT / "templates/hyprland/theme.lua" if n == "theme" else MODS / f"{n}.lua"
            self.assertTrue(src.exists(), f"hyprland.lua requires modules.{n} but {src} is missing")

    def test_theme_lua_is_deployed(self):
        rows = (ROOT / "src/fox-install/modules/symlinks_data.hpp").read_text()
        self.assertIn('"hyprland/theme.lua"', rows)


# Files that send the legacy form on purpose, as the fallback for Hyprland 0.56 and older.
LEGACY_FALLBACKS = {
    "shared/bin/fox-hl",                 # implements both forms
    "shared/greetd_select_monitor.sh",   # keyword branch when eval is unsupported
    "shared/greetd_hyprland.conf",       # the greeter config for 0.56 and older
    "shared/greetd_hyprland.lua",        # `hyprctl dispatch exit` after the Lua exit
}
LEGACY_CALL = re.compile(r"hyprctl\s+(?:-\S+\s+)*(?:dispatch\s+(?![\'\"]?hl\.)|keyword\b|--batch\b)")


class NoLegacyHyprctl(unittest.TestCase):
    """0.57 rejects `hyprctl dispatch <name>`, `hyprctl keyword` and keyword batches: every call
    goes through fox-hl (both forms) or uses the Lua form. This is how the hypridle dpms calls
    were nearly missed: they live in .conf files, not scripts."""

    def test_no_bare_legacy_calls(self):
        offenders = []
        for base in ("shared", "templates"):
            for path in sorted((ROOT / base).rglob("*")):
                rel = path.relative_to(ROOT).as_posix()
                if not path.is_file() or rel in LEGACY_FALLBACKS or "__pycache__" in rel:
                    continue
                try:
                    text = path.read_text()
                except (UnicodeDecodeError, OSError):
                    continue
                for n, line in enumerate(text.splitlines(), 1):
                    if re.match(r"\s*(#|--|//)", line):
                        continue
                    if LEGACY_CALL.search(line):
                        offenders.append(f"{rel}:{n}: {line.strip()[:100]}")
        self.assertEqual(offenders, [], "legacy hyprctl calls break on Hyprland 0.57 — use fox-hl")


class GreeterLauncher(unittest.TestCase):
    """shared/greetd_start.sh picks hyprland.lua (0.57+, or unknown) or hyprland.conf (older)."""

    def launch(self, version_line):
        # /tmp is noexec on hardened boxes, so the fake Hyprland lives under tests/.
        with tempfile.TemporaryDirectory(dir=ROOT / "tests") as d:
            fake = Path(d) / "Hyprland"
            fake.write_text('#!/bin/sh\nif [ "$1" = --version ]; then printf "%s\\n" "$FAKE_VERSION"; '
                            'else echo "$@"; fi\n')
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{d}:{os.environ['PATH']}", FAKE_VERSION=version_line)
            r = subprocess.run(["sh", str(ROOT / "shared/greetd_start.sh")], env=env,
                               capture_output=True, text=True, timeout=20)
            return r.stdout.strip()

    def test_picks_config_by_version(self):
        lua, conf = "-c /etc/greetd/hyprland.lua", "-c /etc/greetd/hyprland.conf"
        self.assertEqual(self.launch("Hyprland 0.56.2 built from branch v0.56.2 at commit efb5099"), conf)
        self.assertEqual(self.launch("Hyprland 0.55.0 built from branch v0.55.0"), conf)
        self.assertEqual(self.launch("Hyprland 0.57.0 built from branch v0.57.0 at commit 0aa6745"), lua)
        self.assertEqual(self.launch("Hyprland 0.60.1 built"), lua)
        self.assertEqual(self.launch("Hyprland 1.0.0 built"), lua)
        self.assertEqual(self.launch(""), lua)
        self.assertEqual(self.launch("something unexpected"), lua)


def hyprland_version():
    try:
        out = subprocess.run(["Hyprland", "--version"], capture_output=True, text=True, timeout=20).stdout
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"Hyprland\s+(\d+)\.(\d+)\.(\d+)", out)
    return tuple(int(x) for x in m.groups()) if m else None


HYPR = hyprland_version()


@unittest.skipUnless(HYPR and HYPR >= (0, 57, 0), "needs Hyprland >= 0.57 installed")
class VerifyWithHyprland(unittest.TestCase):
    def verify(self, entry):
        # Always pass -c: without it, 0.57's verify-config writes a stock ~/.config/hypr/hyprland.lua.
        r = subprocess.run(["Hyprland", "--verify-config", "-c", str(entry)],
                           capture_output=True, text=True, timeout=120)
        result = r.stdout[r.stdout.find("parsing result"):] if "parsing result" in r.stdout else r.stdout[-400:]
        self.assertIn("config ok", r.stdout, f"{entry}:\n{result}")

    def test_every_theme(self):
        native = ROOT / "src/fox-render/fox-render-fast"
        renderer = [str(native)] if os.access(native, os.X_OK) else ["bash", str(ROOT / "render.sh")]
        for palette in sorted((ROOT / "themes").glob("*/palette.sh")):
            with self.subTest(theme=palette.parent.name), tempfile.TemporaryDirectory() as d:
                out, cfg = Path(d) / "render", Path(d) / "hypr"
                subprocess.run(renderer + [str(palette), str(ROOT / "templates"), str(out)],
                               check=True, capture_output=True, timeout=120)
                (cfg / "modules").mkdir(parents=True)
                (cfg / "hyprland.lua").write_text((ROOT / "shared/hyprland.lua").read_text())
                for m in MODS.glob("*.lua"):
                    (cfg / "modules" / m.name).write_text(m.read_text())
                (cfg / "modules/theme.lua").write_text((out / "hyprland/theme.lua").read_text())
                self.verify(cfg / "hyprland.lua")

    def test_greeter(self):
        self.verify(ROOT / "shared/greetd_hyprland.lua")


if __name__ == "__main__":
    unittest.main(verbosity=1)
