// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

@main
struct WorkspaceArtifactEvidenceTests {
    final class Activity: CommandRunning {
        var process = "launchd", opened = "/unrelated", checks = 0
        var mutate: (() -> Void)?
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
            if executable == "/bin/ps" { return .init(status: 0, stdout: process + "\n", stderr: "", timedOut: false) }
            if executable == "/usr/sbin/lsof" {
                checks += 1
                if checks == 2 { mutate?() }
                return .init(status: 0, stdout: "p999999\0fcwd\0n\(opened)\0\n", stderr: "", timedOut: false)
            }
            return ProcessRunner().run(executable, arguments, timeout: timeout)
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("roomy-workspace-proof-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let root = realpath(temporary, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }!
        defer { try? fm.removeItem(atPath: root) }
        func write(_ path: String, _ data: Data) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        }
        func text(_ relative: String, _ value: String) throws { try write(root + "/" + relative, Data(value.utf8)) }
        precondition(ProcessRunner().run("/usr/bin/git", ["init", "-q", root], timeout: 5).ok)
        try text(".gitignore", ".dart_tool/\ntarget/\n")
        try text("pubspec.yaml", "name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n")
        let build = root + "/.dart_tool/flutter_build/" + String(repeating: "a", count: 32)
        let kernel = build + "/app.dill"
        let bytes = Data([0x90, 0xab, 0xcd, 0xef, 0, 0, 0, 127] + Array(repeating: 23, count: 4096))
        try write(kernel, bytes)
        let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let cache = try JSONSerialization.data(withJSONObject: ["version": 2, "files": [["path": kernel, "hash": md5]]])
        try write(build + "/.filecache", cache)
        let stamp = try JSONSerialization.data(withJSONObject: ["inputs": [root + "/lib/main.dart"], "outputs": [kernel]])
        try write(build + "/kernel_snapshot_program.stamp", stamp)
        try text("lib/main.dart", "void main() {}")
        let parent = ScanItem.trashTarget(path: root + "/.dart_tool", name: "Flutter", size: 8192,
            rule: "工作空间构建目录", evidence: "", risk: .amber)
        // Missing independent-child extraction would hide the large generated file.
        let runner = Activity()
        let children = CleanupEvidence.generatedChildren(of: CleanupEvidence.applying(to: parent), runner: runner)
        precondition(children.count == 1 && children[0].path == kernel, "verified Flutter kernel should be individually available")
        let item = children[0], candidate = CleanupListBuilder.fromRule(item)
        precondition(candidate.entry.selectable && candidate.entry.tier == .rebuildable && !candidate.entry.defaultChecked)
        precondition(!CleanupEvidence.applying(to: parent).undo, "mixed parent must remain protected")
        let sourceRace = Activity()
        sourceRace.mutate = { try! Data("void main() { print('changed'); }".utf8).write(to: URL(fileURLWithPath: root + "/lib/main.dart")) }
        precondition(!CleanupEvidence.inspect(item, runner: sourceRace).allowed, "source inputs changed during the final activity query must invalidate the proof")
        try fm.removeItem(atPath: root + "/lib/main.dart")
        precondition(!CleanupEvidence.inspect(item, runner: Activity()).allowed, "a missing recorded input cannot establish rebuildability")
        try text("lib/main.dart", "void main() {}")
        let active = Activity(); active.process = "/opt/flutter/bin/cache/dart-sdk/bin/dart /opt/flutter/bin/cache/flutter_tools.snapshot --verbose build apk"
        precondition(!CleanupEvidence.inspect(item, runner: active).allowed, "running Flutter compilation must block")
        let opened = Activity(); opened.opened = kernel
        precondition(!CleanupEvidence.inspect(item, runner: opened).allowed, "actual open file must block")
        let race = Activity(); race.mutate = { try! Data([1]).write(to: URL(fileURLWithPath: build + "/kernel_snapshot_program.stamp")) }
        precondition(!CleanupEvidence.inspect(item, runner: race).allowed, "changes during final activity query must block")
        try write(build + "/kernel_snapshot_program.stamp", stamp)
        try write(kernel, Data("source with a misleading .dill suffix".utf8))
        precondition(!CleanupEvidence.inspect(item, runner: Activity()).allowed, "file extensions cannot authorize removal")
        try write(kernel, bytes)
        precondition(ProcessRunner().run("/usr/bin/git", ["-C", root, "add", "-f", kernel], timeout: 5).ok)
        precondition(!CleanupEvidence.inspect(item, runner: Activity()).allowed, "explicitly tracked artifacts must be preserved")
        precondition(ProcessRunner().run("/usr/bin/git", ["-C", root, "rm", "--cached", "-q", kernel], timeout: 5).ok)
        try fm.removeItem(atPath: kernel)
        try fm.createSymbolicLink(atPath: kernel, withDestinationPath: root + "/lib/main.dart")
        precondition(!CleanupEvidence.inspect(item, runner: Activity()).allowed, "symlink output must be preserved")

        try text("Cargo.toml", "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n")
        try text("target/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n")
        let unit = root + "/target/debug/incremental/demo-123abc"
        let session = unit + "/s-abcd-1234-deadbeef"
        let rustCache = Data("RSIC\0\0\u{1d}1.98.1 (48a229cea 2026-09-01)\0payload".utf8)
        try write(session + "/query-cache.bin", rustCache)
        try write(session + "/metadata.rmeta", Data([0x72,0x75,0x73,0x74,0,0,0,10] + Array(repeating: 0, count: 32)))
        try write(unit + "/s-abcd-1234.lock", Data())
        let rustParent = ScanItem.trashTarget(path: root + "/target", name: "Rust", size: 8192,
            rule: "Rust 构建产物", evidence: "", risk: .green)
        let rust = CleanupEvidence.generatedChildren(of: CleanupEvidence.applying(to: rustParent), runner: Activity())
        precondition(rust.count == 1 && rust[0].path == unit, "verified incremental cache must be independently available")
        precondition(!CleanupEvidence.applying(to: rustParent).undo, "Cargo target is a mixed parent")
        let r = rust[0]
        precondition(CleanupListBuilder.fromRule(r).entry.tier == .rebuildable)
        try write(session + "/query-cache.bin", Data("RSIC".utf8))
        precondition(!CleanupEvidence.inspect(r, runner: Activity()).allowed, "a truncated Rust header must not establish a generated cache")
        try write(session + "/query-cache.bin", rustCache)
        var unknownRevision = rustCache; unknownRevision[4] = 1
        try write(session + "/query-cache.bin", unknownRevision)
        precondition(!CleanupEvidence.inspect(r, runner: Activity()).allowed, "unsupported Rust header revisions stay review")
        try write(session + "/query-cache.bin", rustCache)
        let compiling = Activity(); compiling.process = "/opt/rust/bin/cargo --locked check"
        precondition(!CleanupEvidence.inspect(r, runner: compiling).allowed)
        try write(session + "/private.rs", Data("unique source".utf8))
        precondition(!CleanupEvidence.inspect(r, runner: Activity()).allowed, "unknown source in incremental cache must prevent whole-unit cleanup")
        try fm.removeItem(atPath: session + "/private.rs")
        let changing = Activity(); changing.mutate = { try! Data("new source".utf8).write(to: URL(fileURLWithPath: session + "/private.rs")) }
        precondition(!CleanupEvidence.inspect(r, runner: changing).allowed, "nested changes during final activity check must block")
        precondition(CleanupEvidence.executionBlocker(r, runner: Activity()) != nil, "stale snapshot must not authorize execution")
        print("WorkspaceArtifactEvidenceTests passed")
    }
}
