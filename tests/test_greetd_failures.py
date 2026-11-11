#!/usr/bin/env python3
"""A login screen that failed to deploy must be recorded, not just printed."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = (ROOT / "src/desk-install/modules/greetd.cpp").read_text()
BODY = SOURCE[SOURCE.index("void run_greetd(Context& ctx) {"):]


class GreetdFailures(unittest.TestCase):
    def test_no_failure_path_only_prints(self):
        # The theme marker trusts deploy_failed, so a bare error would save a half-applied theme.
        self.assertIsNone(re.search(r"\bui::err\([^;]*;\s*return;", BODY.replace("ctx.deploy_failed = true;\n        ui::err(why);", "")))

    def test_every_return_after_a_failure_is_marked(self):
        self.assertGreaterEqual(BODY.count("incomplete("), 9)
        self.assertIn("ctx.deploy_failed = true;", BODY)

    def test_failed_render_stops_before_anything_is_read(self):
        self.assertLess(BODY.index("ctx.render_ran && !ctx.render_ok"), BODY.index('ctx.config_home / "regreet"'))

    def test_dry_run_reports_before_it_needs_staged_files(self):
        # Specials stages nothing in a dry run, and CI requires those runs to exit 0.
        self.assertLess(BODY.index("sh::dry_run()"), BODY.index('ctx.config_home / "regreet"'))

    def test_config_is_checked_before_the_login_screen_changes(self):
        self.assertLess(BODY.index("greeter_config_parses(staged)"), BODY.index("backup_greeter()"))
        self.assertLess(BODY.index("backup_greeter()"), BODY.index("write_root_file("))

    def test_failed_enable_is_reported(self):
        self.assertIn('incomplete("could not enable greetd', BODY)

    def test_missing_hyprland_cannot_pass_the_check(self):
        self.assertNotIn("nothing to check against yet", SOURCE)
        self.assertIn("hypr_lua::greeter_config_ok(have, res)", SOURCE)


if __name__ == "__main__":
    unittest.main()
