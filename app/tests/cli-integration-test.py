# SPDX-License-Identifier: MPL-2.0
"""Exercise the shipped CLI against private generated files; never clean user data."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(os.environ.get("ROOMY_CLI_PATH", Path(__file__).parents[1] / "build/roomy")).resolve()


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.sample = tempfile.TemporaryDirectory(prefix="roomy-cli-")
        self.root = Path(self.sample.name).resolve()
        (self.root / "nested").mkdir()
        (self.root / "nested/large.bin").write_bytes(b"x" * 16384)
        (self.root / "small.txt").write_text("keep me")

    def tearDown(self):
        self.sample.cleanup()

    def run_cli(self, *args):
        return subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True, timeout=30)

    def test_help_never_starts_scan(self):
        result = self.run_cli("--help", "--index-root", self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: roomy", result.stdout)
        self.assertNotIn("索引扫描完成", result.stdout)
        self.assertIn("schedule add", result.stdout)

    def test_invalid_schedules_fail_before_discovery_or_mutation(self):
        for args in [("schedule",), ("schedule", "list", "--apply"),
                     ("schedule", "add", "fixture", "--every-days", "0", "--scope", self.root),
                     ("schedule", "run", "--scope", self.root),
                     ("schedule", "install", "--yes")]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 2)
                self.assertTrue(result.stderr)
                self.assertEqual((self.root / "small.txt").read_text(), "keep me")

    def test_invalid_arguments_fail_without_falling_back_to_home(self):
        for args in [("wat",), ("disk", "--root"), ("disk", "--limit", "0"),
                     ("scan", "--root", self.root, "--aply"),
                     ("clean", "--yes"), ("restore", "--apply", "--yes")]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr)
                self.assertEqual((self.root / "small.txt").read_text(), "keep me")

    def test_scan_stdout_is_only_machine_json(self):
        result = self.run_cli("scan", "--root", self.root, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["command"], "scan")
        self.assertEqual(report["data"]["report"]["stats"]["files"], 2)

    def test_disk_search_and_paging_use_real_index(self):
        result = self.run_cli("disk", self.root, "--files", "--query", "large", "--limit", "1", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        page = json.loads(result.stdout)["data"]["page"]
        self.assertEqual(page["total"], 1)
        self.assertEqual(page["items"][0]["name"], "large.bin")
        self.assertEqual(page["items"][0]["logicalSize"], 16384)
        self.assertGreaterEqual(page["items"][0]["size"], 16384)

    def test_missing_root_is_error(self):
        result = self.run_cli("disk", self.root / "missing", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_json_dash_and_text_control_characters(self):
        (self.root / "unsafe\x1b[2J.txt").write_text("sample")
        result = self.run_cli("disk", self.root, "--files", "--json", "-")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["command"], "disk")
        text = self.run_cli("disk", self.root, "--files")
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertNotIn("\x1b", text.stdout)
        self.assertIn("\\u001B", text.stdout)

    def test_export_refuses_to_overwrite_existing_file(self):
        output = self.root / "report.json"
        output.write_text("important existing text")
        result = self.run_cli("scan", "--root", self.root, "--json", output)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(output.read_text(), "important existing text")

    def test_invalid_export_destination_fails_before_scan(self):
        result = self.run_cli("disk", self.root, "--json", self.root / "missing/report.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_legacy_index_flags_still_work(self):
        output = self.root / "index.json"
        result = self.run_cli("--index-root", self.root, "--index-json", output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(output.read_text())["command"], "disk")


if __name__ == "__main__":
    unittest.main()
