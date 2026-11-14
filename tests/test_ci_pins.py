"""CI's toolchains are pinned in one place, .github/toolchain.json, and every workflow reads them from there."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / '.github/toolchain.json').read_text())
WORKFLOWS = sorted((ROOT / '.github/workflows').glob('*.yml'))


class CiPins(unittest.TestCase):
    def test_the_image_and_the_package_archive_are_the_same_day(self):
        self.assertRegex(PINS['archSnapshot'], r'^\d{4}/\d{2}/\d{2}$')
        self.assertIn('-' + PINS['archSnapshot'].replace('/', '') + '.', PINS['archImage'],
                      'the Arch image and the archive it installs from must be the same day')
        self.assertRegex(PINS['ubuntu'], r'^ubuntu-\d{2}\.\d{2}$')

    def test_no_workflow_writes_a_pin_of_its_own(self):
        for path in WORKFLOWS:
            text = path.read_text()
            for pinned in (r'ubuntu-\d{2}\.\d{2}', r'archlinux:base[-\w.]*\d{8}', r'\b20\d{2}/\d{2}/\d{2}\b'):
                self.assertIsNone(re.search(pinned, text), f'{path.name} pins a toolchain itself; use .github/toolchain.json')

    def test_a_workflow_that_reads_the_pins_has_the_job_that_reads_them(self):
        for path in WORKFLOWS:
            text = path.read_text()
            if 'needs.pins.outputs' in text:
                self.assertIn('\n  pins:\n', text, path.name)
                self.assertIn('.github/toolchain.json', text, path.name)


if __name__ == '__main__':
    unittest.main()
