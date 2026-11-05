#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run all headless suites, retain failures, and report the actual host.

Only generated temporary samples are moved/deleted by the tests. DialogTests
and WindowShellTests have separate GUI runners; this script never starts cleanup against user data.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time
import uuid


def run_stage(command, cwd, environment, log):
    try:
        return subprocess.run(command, cwd=cwd, env=environment, stdout=log,
                              stderr=subprocess.STDOUT, timeout=240).returncode
    except subprocess.TimeoutExpired as error:
        log.write(("TIMEOUT: " + str(error) + "\n").encode())
        return 124
    except OSError as error:
        log.write((type(error).__name__ + ": " + str(error) + "\n").encode())
        return 127 if isinstance(error, FileNotFoundError) else 126


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="app/build/reliability")
    parser.add_argument("--core-only", action="store_true", help="core and CLI suites; no GUI sources or Node.js")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.setdefault("SWIFT_MODULECACHE_PATH", "/private/tmp/roomy-swift-cache")
    environment.setdefault("CLANG_MODULE_CACHE_PATH", "/private/tmp/roomy-clang-cache")
    results = []
    arch = environment.get("ROOMY_TEST_ARCH", platform.machine())
    if arch not in ("arm64", "x86_64"):
        parser.error("unsupported test architecture")
    support = root / "app/build/reliability-support" / arch
    support.mkdir(parents=True, exist_ok=True)
    target = arch + "-apple-macos14.0"
    # Build unchanged production code once with internal test visibility. Each
    # test imports that exact library, avoiding a full scanner rebuild per suite.
    sources = [str(p.relative_to(root)) for p in sorted((root / "app/Sources/Scanner").rglob("*.swift"))]
    sources += [str(p.relative_to(root)) for p in sorted((root / "app/cli").glob("*.swift")) if p.name != "main.swift"]
    if not args.core_only:
        sources.append("app/Sources/SecurityPolicy.swift")
    library = ["swiftc", "-Onone", "-whole-module-optimization", "-enable-testing", "-emit-library", "-emit-module",
               "-module-name", "RoomyTestSupport", "-target", target,
               "-framework", "CoreServices", "-framework", "CryptoKit", *sources,
               "-emit-module-path", str(support / "RoomyTestSupport.swiftmodule"),
               "-o", str(support / "libRoomyTestSupport.dylib")]
    commands = []
    if not args.core_only:
        commands.append(("JavaScript", ["node", "--test", *[str(p.relative_to(root)) for p in sorted((root / "app/tests").glob("*.test.js"))]]))
    if not args.core_only:
        for test in sorted((root / "app/gui-tests").glob("*Tests.swift")):
            binary = support / test.stem
            commands.append((test.stem, [["swiftc", "-Onone", "-parse-as-library", "-target", target,
                "-framework", "Security", "-framework", "CryptoKit", str(root / "app/Sources/GUILicense.swift"), str(root / "app/Sources/AuthorContent.swift"), str(test), "-o", str(binary)], [str(binary)]]))
    commands.append(("ReliabilityHarness", [sys.executable, "app/tests/reliability-harness-test.py"]))
    commands.append(("NativeSupportBuild", library))
    cli_main = support / "cli/main.swift"
    cli_main.parent.mkdir(parents=True, exist_ok=True)
    cli_main.write_text("@testable import RoomyTestSupport\n" + (root / "app/cli/main.swift").read_text())
    environment["ROOMY_CLI_PATH"] = str(support / "roomy")
    commands.append(("CLIIntegration", [["swiftc", "-target", target, "-I", str(support), "-L", str(support),
                     "-lRoomyTestSupport", "-Xlinker", "-rpath", "-Xlinker", str(support), str(cli_main), "-o", environment["ROOMY_CLI_PATH"]],
                     [sys.executable, "app/tests/cli-integration-test.py"]]))
    generator = support / "make-scan-fixture"
    fixture = support / "fixtures" / str(uuid.uuid4())
    environment["ROOMY_CORRECTNESS_ROOT"] = str(fixture)
    commands.append(("FixtureGeneratorBuild", ["swiftc", "-O", "-target", target,
                     "app/tools/make-scan-fixture.swift", "-o", str(generator)]))
    commands.append(("CorrectnessFixture", [str(generator), str(fixture), "--seed", "42"]))
    for test in sorted((root / "app/tests").glob("*Tests.swift")):
        if test.name in ("DialogTests.swift", "WindowShellTests.swift") or (args.core_only and test.name in ("SecurityPolicyTests.swift", "ProbeVerificationTests.swift")):
            continue
        generated = support / test.name
        generated.write_text("@testable import RoomyTestSupport\n" + test.read_text())
        binary = support / test.stem
        compile_command = ["swiftc", "-Onone", "-parse-as-library", "-target", target,
                           "-I", str(support), "-L", str(support), "-lRoomyTestSupport",
                           "-Xlinker", "-rpath", "-Xlinker", str(support), str(generated), "-o", str(binary)]
        commands.append((test.stem, [compile_command, [str(binary)]]))
    report = {"schema": 1, "scope": "core-cli" if args.core_only else "full-headless", "machine": platform.machine(), "os": platform.mac_ver()[0],
              "testArchitecture": environment.get("ROOMY_TEST_ARCH", platform.machine()),
              "guiDialogTest": "separate; not run by this headless suite",
              "guiWindowShellTest": "separate build-window-preview.sh runner; not run by this headless suite", "results": results,
              "status": "running", "passed": 0, "failed": 0, "skipped": 0}
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    for name, command in commands:
        start = time.monotonic()
        with (output / (name + ".log")).open("wb") as log:
            stages = command if command and isinstance(command[0], list) else [command]
            status = 0
            for stage in stages:
                working_directory = root if name in ("JavaScript", "ReliabilityHarness", "NativeSupportBuild", "CLIIntegration", "FixtureGeneratorBuild", "CorrectnessFixture") else root / "app"
                status = run_stage(stage, working_directory, environment, log)
                if status:
                    break
        results.append({"suite": name, "exitCode": status, "seconds": round(time.monotonic() - start, 3)})
        report["passed"] = sum(item["exitCode"] == 0 for item in results)
        report["failed"] = sum(item["exitCode"] not in (0, 77) for item in results)
        report["skipped"] = sum(item["exitCode"] == 77 for item in results)
        report["nativePassed"] = sum(item["suite"].endswith("Tests") and item["exitCode"] == 0 for item in results)
        report["nativeSkipped"] = sum(item["suite"].endswith("Tests") and item["exitCode"] == 77 for item in results)
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"{name}: {'PASS' if status == 0 else 'SKIP' if status == 77 else 'FAIL'} ({status})", flush=True)
        if name == "NativeSupportBuild" and status:
            break
    report["status"] = "failed" if report["failed"] else "complete"
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return int(report["failed"] != 0)


if __name__ == "__main__":
    raise SystemExit(main())
