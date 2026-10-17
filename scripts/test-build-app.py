#!/usr/bin/env python3
"""Check installation ordering without building or touching /Applications."""
from pathlib import Path
import subprocess
import unittest


class BuildAppInstallTests(unittest.TestCase):
    def test_installation_stops_on_failure_and_can_be_skipped(self):
        script = Path(__file__).with_name("build.sh").read_text()
        install = script[script.index('codesign --force --sign - "$APP"'):]
        for enabled, quit_status, verify_status in [
            (True, 0, 0), (False, 0, 0), (True, 1, 0), (True, 0, 1)
        ]:
            with self.subTest(enabled=enabled, quit=quit_status, verify=verify_status):
                stub = f'''
set -euo pipefail
APP=/tmp/AuvGit-build-test.app
INSTALL_APP={str(enabled).lower()}
function codesign() {{
  print "CALL:codesign $*"
  if [[ "$1" == --verify ]]; then return {verify_status}; fi
}}
function touch() {{ :; }}
function swift() {{ cat >/dev/null; print CALL:quit; return {quit_status}; }}
function ditto() {{ print "CALL:copy $*"; }}
function cmp() {{ print "CALL:compare $*"; }}
'''
                result = subprocess.run(["zsh", "-c", stub + install], text=True, capture_output=True)
                success = enabled and quit_status == 0 and verify_status == 0
                self.assertEqual(result.returncode, int(enabled and not success))
                self.assertEqual("CALL:copy" in result.stdout, success)
                self.assertEqual("CALL:compare" in result.stdout, success)
                if success:
                    self.assertLess(result.stdout.index("CALL:quit"), result.stdout.index("CALL:copy"))
                    self.assertIn("Installed /Applications/AuvGit.app", result.stdout)


if __name__ == "__main__":
    unittest.main()
