"""One red-zone list: shared/redzone.json is what the notebook's band and the review's risk marks read; the copy each
keeps for when the file is missing must say the same."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def quoted(block):
    return re.findall(r"'([^']+)'", block)


class RedZone(unittest.TestCase):
    def setUp(self):
        self.listed = json.loads((ROOT / "shared/redzone.json").read_text())

    def test_the_list_names_paths_and_tools(self):
        self.assertGreaterEqual(len(self.listed["paths"]), 10)
        self.assertIn("/etc/pam.d", self.listed["paths"])
        self.assertIn("bootctl", self.listed["tools"])
        for entry in self.listed["paths"] + self.listed["tools"]:
            self.assertRegex(entry, r"^[A-Za-z0-9 ._/-]+$", "plain text only: both readers match it literally")

    def test_the_fallback_copies_match_the_file(self):
        lua = (ROOT / "shared/nvim_lua/foxml/review.lua").read_text()
        block = lua[lua.index("local RED_DEFAULT = {"):lua.index("local red\n")]
        paths, tools = block.split("tools = {")
        self.assertEqual(quoted(paths), self.listed["paths"], "review.lua's fallback paths")
        self.assertEqual(quoted(tools), self.listed["tools"], "review.lua's fallback tools")
        mod = (ROOT / "shared/claude/mods/foxml-paper/hooks/register.tsx").read_text()
        block = mod[mod.index("const RED_DEFAULT = {"):mod.index("const escaped = ")]
        paths, tools = block.split("tools: [")
        self.assertEqual(quoted(paths), self.listed["paths"], "the notebook's fallback paths")
        self.assertEqual(quoted(tools), self.listed["tools"], "the notebook's fallback tools")

    def test_the_work_tool_s_fallback_matches_too(self):
        cpp = (ROOT / "src/desk-work/main.cpp").read_text()
        paths = cpp[cpp.index("RED_DEFAULT_PATHS = {"):cpp.index("RED_DEFAULT_TOOLS = {")]
        tools = cpp[cpp.index("RED_DEFAULT_TOOLS = {"):cpp.index("std::pair<std::vector<std::string>, std::vector<std::string>> red_zone()")]
        self.assertEqual(re.findall(r'"([^"]+)"', paths), self.listed["paths"])
        self.assertEqual(re.findall(r'"([^"]+)"', tools), self.listed["tools"])

    def test_it_is_deployed(self):
        import glob
        rows = Path(glob.glob(str(ROOT / "src/desk-ins*l/modules/symlinks_data.hpp"))[0]).read_text()
        self.assertIn('"redzone.json"', rows)


if __name__ == "__main__":
    unittest.main()
