# SPDX-License-Identifier: GPL-3.0-only
"""Launch-error regression samples never touch user data."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("reliability", Path(__file__).with_name("run-reliability.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LaunchFailureTests(unittest.TestCase):
    def test_core_only_does_not_require_graphical_sources_or_node(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def capture(command, cwd, environment, log):
                calls.append(command)
                return 0
            with patch.object(sys, "argv", ["run-reliability", "--core-only", "--output", directory]), \
                 patch.object(runner, "run_stage", side_effect=capture):
                self.assertEqual(runner.main(), 0)
            flattened = [str(argument) for command in calls for argument in command]
            self.assertNotIn("node", flattened)
            self.assertNotIn("app/Sources/SecurityPolicy.swift", flattened)
            self.assertFalse(any("SecurityPolicyTests" in argument or "ProbeVerificationTests" in argument
                                 or "DialogTests" in argument or "WindowShellTests" in argument for argument in flattened))
            self.assertTrue(any("CLIWorkflowTests" in argument for argument in flattened))
            self.assertTrue(any("cli-integration-test.py" in argument for argument in flattened))
            self.assertEqual(json.loads((Path(directory) / "summary.json").read_text())["scope"], "core-cli")

    def test_launch_failure_replaces_old_success_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.json"
            summary.write_text('{"status":"complete","failed":0,"nativePassed":99}')
            with patch.object(sys, "argv", ["run-reliability", "--output", directory]), \
                 patch.object(runner.subprocess, "run", side_effect=FileNotFoundError("missing tool")):
                self.assertEqual(runner.main(), 1)
            report = json.loads(summary.read_text())
            self.assertEqual(report["status"], "failed")
            self.assertGreater(report["failed"], 0)
            self.assertEqual(report["nativePassed"], 0)
            self.assertTrue(all(item["exitCode"] == 127 for item in report["results"]))

    def test_missing_tool_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as log:
            status = runner.run_stage([str(Path(directory) / "missing-tool")], Path(directory), {}, log)
            log.seek(0)
            self.assertEqual(status, 127)
            self.assertIn(b"FileNotFoundError", log.read())

    def test_nonexecutable_tool_is_recorded(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as log:
            sample = Path(directory) / "not-executable"
            sample.write_text("sample")
            sample.chmod(0o600)
            status = runner.run_stage([str(sample)], Path(directory), {}, log)
            log.seek(0)
            self.assertEqual(status, 126)
            self.assertIn(b"PermissionError", log.read())


if __name__ == "__main__":
    unittest.main()
