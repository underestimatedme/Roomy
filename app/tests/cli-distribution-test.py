# SPDX-License-Identifier: GPL-3.0-only
"""Exercise distribution boundaries with real CLI builds and private files."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "app/tools/package-cli.py"


class CLIDistributionTests(unittest.TestCase):
    def test_source_archive_contains_only_licensed_swift_sources(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("roomy_packager", PACKAGER)
        packager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packager)
        files = packager.source_files()
        for name in files:
            if name.endswith(".swift"):
                self.assertIn(b"SPDX-License-Identifier: GPL-3.0-only", packager.read_file(name).splitlines()[0], name)


    def test_source_change_during_compilation_cannot_create_a_valid_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            for relative in ["app/Sources/Scanner", "app/cli"]:
                shutil.copytree(ROOT / relative, repo / relative)
            (repo / "app/tools").mkdir(parents=True)
            shutil.copy2(ROOT / "app/tools/build-cli.sh", repo / "app/tools/build-cli.sh")
            wrappers = repo / "tool-wrappers"
            wrappers.mkdir()
            compiler = wrappers / "swiftc"
            compiler.write_text('''#!/bin/bash
/usr/bin/swiftc "$@" || exit $?
python3 - <<'PY'
import re
from pathlib import Path
source = Path('cli/RoomyCLI.swift')
text = source.read_text()
updated, count = re.subn(r'print\\("roomy [^"]*"\\)', 'print("roomy 9.9.9")', text)
if count != 1:
    raise SystemExit('version tamper target not found')
source.write_text(updated)
PY
''')
            compiler.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = str(wrappers) + os.pathsep + environment["PATH"]
            result = subprocess.run(["bash", "app/tools/build-cli.sh"], cwd=repo, env=environment,
                                    capture_output=True, text=True, timeout=240)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rebuild", result.stderr)
            self.assertFalse((repo / "app/build/roomy-build.json").exists())

    def test_linked_directory_is_refused_instead_of_silently_omitted(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            # Only files needed for discovering the linked subtree; refusal
            # must happen before any unrelated missing-file validation.
            (repo / "app/tools").mkdir(parents=True)
            (repo / "app/Sources/Scanner").mkdir(parents=True)
            shutil.copy2(PACKAGER, repo / "app/tools/package-cli.py")
            external = Path(temporary) / "external"
            external.mkdir()
            (external / "Private.swift").write_text("private sample")
            (repo / "app/Sources/Scanner/LinkedDirectory").symlink_to(external, target_is_directory=True)
            result = self.package(repo / "release", repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symbolic link", result.stderr)
            self.assertFalse((repo / "release").exists())

    def test_changed_sources_require_a_fresh_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"
            for relative in ["app/Sources/Scanner", "app/cli"]:
                shutil.copytree(ROOT / relative, repo / relative)
            for relative in ["app/tools/package-cli.py", "app/tools/build-cli.sh", "app/tools/install-cli.sh",
                             "app/tools/make-scan-fixture.swift", "app/tests/run-reliability.py",
                             "app/tests/reliability-harness-test.py", "app/tests/cli-integration-test.py", "app/tests/cli-distribution-test.py",
                             ".github/workflows/core-reliability.yml",
                             "LICENSE", "LICENSES/GPL-3.0-only.txt", "docs/core-readme.md", "docs/licensing.md", "docs/cli.md",
                             "app/build/roomy"]:
                destination = repo / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, destination)
            receipt = ROOT / "app/build/roomy-build.json"
            if receipt.exists():
                shutil.copy2(receipt, repo / "app/build/roomy-build.json")
            changed = repo / "app/cli/main.swift"
            changed.write_text(changed.read_text() + "\n// changed after binary build\n")
            result = self.package(repo / "release", repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rebuild", result.stderr)
            self.assertFalse((repo / "release").exists())

    def package(self, output, repo=ROOT):
        return subprocess.run(["python3", str(repo / "app/tools/package-cli.py"),
                               "--output", str(output)], capture_output=True,
                              text=True, timeout=30)

    def test_standalone_source_rebuild_and_binary_install(self):
        with tempfile.TemporaryDirectory(prefix="roomy-distribution-") as temporary:
            work = Path(temporary)
            output = work / "release"
            result = self.package(output)
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(manifest["cliPrice"], "free")
            self.assertEqual(manifest["sourceLicense"], "GPL-3.0-only")
            for entry in manifest["artifacts"]:
                artifact = output / entry["file"]
                self.assertEqual(hashlib.sha256(artifact.read_bytes()).hexdigest(), entry["sha256"])
            source = next(output.glob("*-source.tar.gz"))
            with tarfile.open(source) as archive:
                names = archive.getnames()
                self.assertFalse(any("/web/" in name or name.endswith("Info.plist")
                                     or name.endswith("Handlers.swift") or "/.git/" in name
                                     or name.endswith("GUILicense.swift") or name.endswith("RoomyUpdater.swift")
                                     or name.endswith("license-issuer.swift") or "/gui-tests/" in name
                                     or name.endswith("/.github/workflows/reliability.yml")
                                     or "/artifacts/" in name for name in names))
                self.assertTrue(any(name.endswith("/.github/workflows/core-reliability.yml") for name in names))
                self.assertTrue(any(name.endswith("Scanner/Cleanup/TrashLedger.swift") for name in names))
                archive.extractall(work / "source")
            exported = next((work / "source").iterdir())
            self.assertFalse((exported / "app/Sources/main.swift").exists())
            built = subprocess.run(["bash", "app/tools/build-cli.sh"], cwd=exported,
                                   capture_output=True, text=True, timeout=240)
            self.assertEqual(built.returncode, 0, built.stderr)
            environment = os.environ.copy()
            environment["ROOMY_CLI_PATH"] = str(exported / "app/build/roomy")
            checked = subprocess.run(["python3", "app/tests/cli-integration-test.py"], cwd=exported,
                                     env=environment, capture_output=True, text=True, timeout=120)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            binary = next(output.glob("*-macos-*.tar.gz"))
            with tarfile.open(binary) as archive:
                archive.extractall(work / "binary")
            installed_from = next((work / "binary").iterdir())
            prefix = work / "bin with spaces"
            installed = subprocess.run(["bash", "install.sh", "--prefix", str(prefix)],
                                       cwd=installed_from, capture_output=True, text=True, timeout=10)
            self.assertEqual(installed.returncode, 0, installed.stderr)
            self.assertEqual(subprocess.check_output([str(prefix / "roomy"), "version"], text=True).strip(),
                             "roomy " + manifest["version"])
            repeated = subprocess.run(["bash", "install.sh", "--prefix", str(prefix)],
                                      cwd=installed_from, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("未覆盖", repeated.stderr)

    def test_existing_release_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "release"
            output.mkdir()
            (output / "keep.txt").write_text("existing release")
            result = self.package(output)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((output / "keep.txt").read_text(), "existing release")
            self.assertEqual(list(output.iterdir()), [output / "keep.txt"])

    def test_linked_core_source_cannot_leak_outside_the_export(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            repo = work / "repo"
            for relative in ["app/tools", "app/Sources/Scanner", "app/cli", "app/build", "LICENSES", "docs"]:
                (repo / relative).mkdir(parents=True, exist_ok=True)
            for relative in ["app/tools/package-cli.py", "app/tools/build-cli.sh", "app/tools/install-cli.sh",
                             "LICENSE", "LICENSES/GPL-3.0-only.txt", "docs/core-readme.md", "docs/cli.md"]:
                shutil.copy2(ROOT / relative, repo / relative)
            shutil.copy2(ROOT / "app/build/roomy", repo / "app/build/roomy")
            shutil.copy2(ROOT / "app/cli/main.swift", repo / "app/cli/main.swift")
            secret = work / "private.swift"
            secret.write_text("private content must never be exported")
            (repo / "app/Sources/Scanner/Linked.swift").symlink_to(secret)
            result = self.package(repo / "release", repo)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symbolic link", result.stderr)
            self.assertFalse((repo / "release").exists())


if __name__ == "__main__":
    unittest.main()
