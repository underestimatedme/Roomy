#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create matching free CLI/source archives without GUI or machine data."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
GUI_TESTS = {"DialogTests.swift", "SecurityPolicyTests.swift", "ProbeVerificationTests.swift", "WindowShellTests.swift"}


def source_files():
    # An allowlist, not a repository archive: new GUI, activation and reports
    # never enter the core distribution merely because they were committed.
    for directory in ["app/Sources/Scanner", "app/cli", "app/tests"]:
        for base, directories, names in os.walk(ROOT / directory, followlinks=False):
            for candidate in [Path(base), *[Path(base) / name for name in directories + names]]:
                if candidate.is_symlink():
                    raise ValueError("symbolic link not allowed in distribution: " + str(candidate.relative_to(ROOT)))
    files = [".github/workflows/core-reliability.yml", "LICENSE", "LICENSES/GPL-3.0-only.txt", "docs/cli.md", "docs/licensing.md", "docs/core-readme.md",
             "app/tools/build-cli.sh", "app/tools/install-cli.sh", "app/tools/package-cli.py",
             "app/tools/make-scan-fixture.swift", "app/tests/run-reliability.py",
             "app/tests/reliability-harness-test.py", "app/tests/cli-integration-test.py",
             "app/tests/cli-distribution-test.py"]
    for directory, pattern in [("app/Sources/Scanner", "*.swift"), ("app/cli", "*.swift"),
                               ("app/tests", "*Tests.swift")]:
        files += [p.relative_to(ROOT).as_posix() for p in (ROOT / directory).rglob(pattern)
                  if p.name not in GUI_TESTS]
    files += [p.relative_to(ROOT).as_posix() for p in (ROOT / "app/tests/fixtures").rglob("*") if p.is_file()]
    return sorted(set(files))


def read_file(relative):
    candidate = ROOT / relative
    for item in [candidate, *candidate.parents]:
        if item == ROOT:
            break
        if item.is_symlink():
            raise ValueError("symbolic link not allowed in distribution: " + relative)
    if not stat.S_ISREG(candidate.stat().st_mode):
        raise ValueError("not a regular distribution file: " + relative)
    return candidate.read_bytes()


def archive(destination, prefix, entries):
    with tarfile.open(destination, "w:gz") as output:
        for name, data, mode in entries:
            member = tarfile.TarInfo(prefix + "/" + name)
            member.size = len(data)
            member.mode = mode
            member.mtime = 0
            output.addfile(member, io.BytesIO(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="new output directory; existing destinations are refused")
    args = parser.parse_args()
    destination = Path(args.output).absolute()
    try:
        if destination.exists() or destination.is_symlink():
            raise ValueError("output already exists; existing releases are never overwritten")
        # Read and validate all source paths before creating any release output.
        entries = [(relative, read_file(relative), 0o755 if relative.endswith(".sh") else 0o644)
                   for relative in source_files()]
        binary = read_file("app/build/roomy")
        try:
            receipt = json.loads(read_file("app/build/roomy-build.json"))
        except (OSError, ValueError):
            raise ValueError("missing or invalid build receipt; rebuild the CLI first")
        expected = {relative: hashlib.sha256(data).hexdigest() for relative, data, _ in entries
                    if relative.startswith(("app/Sources/Scanner/", "app/cli/")) and relative.endswith(".swift")}
        if not isinstance(receipt, dict) or receipt.get("schemaVersion") != 1 or receipt.get("sourceFiles") != expected \
                or receipt.get("binarySHA256") != hashlib.sha256(binary).hexdigest():
            raise ValueError("binary or source changed since build; rebuild the CLI first")
        executable = ROOT / "app/build/roomy"
        version_output = subprocess.check_output([str(executable), "version"], text=True, timeout=10).strip()
        match = re.fullmatch(r"roomy (\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)", version_output)
        if not match:
            raise ValueError("unexpected CLI version output")
        version = match.group(1)
        arch = subprocess.check_output(["/usr/bin/lipo", "-archs", str(executable)], text=True, timeout=10).strip()
        if arch not in ("arm64", "x86_64"):
            raise ValueError("CLI archive requires one supported architecture")
        if receipt.get("architecture") != arch:
            raise ValueError("build architecture mismatch; rebuild the CLI first")
        libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(executable)], text=True, timeout=10)
        if "/WebKit.framework/" in libraries or "/AppKit.framework/" in libraries:
            raise ValueError("CLI unexpectedly depends on graphical frameworks")
        source_name = "roomy-" + version + "-source.tar.gz"
        binary_name = "roomy-" + version + "-macos-" + arch + ".tar.gz"
        notice = ("Roomy " + version + " — free CLI for macOS 14+ (" + arch + ").\n"
                  "No GUI purchase or activation is required.\n"
                  "Install: bash install.sh [--prefix DIRECTORY] [--replace]\n"
                  "Use: ./roomy --help\n"
                  "Core and CLI: GPL-3.0-only. Matching source: " + source_name + "\n"
                  "Source archive is supplied alongside this binary release.\n"
                  "Current build uses development ad-hoc signing; no notarization.\n").encode()
        binary_entries = [("roomy", binary, 0o755), ("install.sh", read_file("app/tools/install-cli.sh"), 0o755),
                          ("README.txt", notice, 0o644), ("docs/cli.md", read_file("docs/cli.md"), 0o644),
                          ("LICENSE", read_file("LICENSE"), 0o644),
                          ("LICENSES/GPL-3.0-only.txt", read_file("LICENSES/GPL-3.0-only.txt"), 0o644),
                          ("docs/licensing.md", read_file("docs/licensing.md"), 0o644)]
        entries.append(("README.md", read_file("docs/core-readme.md"), 0o644))
        destination.mkdir()  # Exclusive creation; no overwrite or recursive deletion.
        archive(destination / source_name, "roomy-" + version + "-source", entries)
        archive(destination / binary_name, "roomy-" + version + "-macos-" + arch, binary_entries)
        artifacts = [{"file": name, "sha256": hashlib.sha256((destination / name).read_bytes()).hexdigest()}
                     for name in [source_name, binary_name]]
        manifest = {"schemaVersion": 1, "version": version, "architecture": arch, "minimumMacOS": "14.0",
                    "cliPrice": "free", "sourceLicense": "GPL-3.0-only", "signing": "development-ad-hoc",
                    "notarized": False, "artifacts": artifacts}
        (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        (destination / "SHA256SUMS").write_text("".join(item["sha256"] + "  " + item["file"] + "\n" for item in artifacts))
        print(destination)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
