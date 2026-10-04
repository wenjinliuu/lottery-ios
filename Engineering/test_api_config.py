import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class APIConfigTests(unittest.TestCase):
    def run_generator(self, key="", team=""):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        (root / "Scripts").mkdir()
        (root / "LotteryWallet/Data/V2").mkdir(parents=True)
        script = Path(__file__).resolve().parents[1] / "Scripts/write-api-config.py"
        shutil.copyfile(script, root / "Scripts/write-api-config.py")
        env = {**os.environ, "APP_RUNTIME_API_KEY": key, "DEVELOPMENT_TEAM": team}
        result = subprocess.run([sys.executable, str(root / "Scripts/write-api-config.py")],
                                env=env, capture_output=True, text=True)
        return result, root / "LotteryWallet/Data/V2/GeneratedLotteryReadKey.swift"

    def test_archive_without_key_is_blocked(self):
        result, target = self.run_generator(team="TESTTEAM")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())
        self.assertIn("LOTTERY_READ_API_KEY", result.stderr)

    def test_test_build_without_key_can_use_fallback(self):
        result, target = self.run_generator()
        self.assertEqual(result.returncode, 0)
        self.assertIn("static let value: String? = nil", target.read_text())

    def test_archive_key_is_embedded_but_not_logged(self):
        key = "unit-test-only-read-key-not-for-production"
        result, target = self.run_generator(key=key, team="TESTTEAM")
        self.assertEqual(result.returncode, 0)
        self.assertIn(key, target.read_text())
        self.assertNotIn(key, result.stdout + result.stderr)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_invalid_header_characters_and_short_keys_are_rejected(self):
        for key in ["short", "a" * 32 + "\nInjected: header", "a" * 129]:
            result, target = self.run_generator(key=key)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())
