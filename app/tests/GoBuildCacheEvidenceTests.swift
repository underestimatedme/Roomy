// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

private final class GoCacheProcesses: CommandRunning {
    var processes = "gopls serve"
    var opened: [String] = []
    var handleCalls = 0
    var onHandles: ((Int) -> Void)?
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/usr/sbin/lsof" { handleCalls += 1; onHandles?(handleCalls) }
        return .init(status: 0, stdout: executable == "/bin/ps" ? processes :
            "p123\0\nf0\0n/dev/null\0" + opened.map { "f12\0n" + $0 + "\0" }.joined(), stderr: "", timedOut: false)
    }
}

@main struct GoBuildCacheEvidenceTests {
    static func main() throws {
        let fm = FileManager.default, root = "/private/tmp/roomy-go-cache-" + UUID().uuidString
        let cache = root + "/Library/Caches/go-build"
        let data = Data("generated build output".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let bucket = cache + "/" + hash.prefix(2), blob = bucket + "/" + hash + "-d"
        try fm.createDirectory(atPath: bucket, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        try "This directory holds cached build artifacts from the Go build system.\n".write(toFile: cache + "/README", atomically: true, encoding: .utf8)
        try data.write(to: URL(fileURLWithPath: blob))
        let actionID = String(hash.prefix(2)) + String(repeating: "a", count: 62)
        let action = bucket + "/" + actionID + "-a"
        let manifest = "v1 " + actionID + " " + hash + " " + String(format: "%20lld", Int64(data.count)) + " " + String(format: "%20lld", Int64(1_000_000)) + "\n"
        try manifest.write(toFile: action, atomically: true, encoding: .utf8)
        let runner = GoCacheProcesses()
        let item = ScanItem.trashTarget(path: bucket, name: "Go", size: 4096, rule: "Go 生成缓存", evidence: "", risk: .amber)
        let inspected = CleanupEvidence.applying(to: item, runner: runner)
        precondition(inspected.cleanupEvidence?.kind == "goBuildCache" && inspected.undo)
        let entry = CleanupListBuilder.fromRule(inspected).entry
        precondition(entry.tier == .rebuildable && entry.selectable && !entry.defaultChecked)
        try "unique source".write(toFile: bucket + "/OnlyCopy.swift", atomically: true, encoding: .utf8)
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed)
        try fm.removeItem(atPath: bucket + "/OnlyCopy.swift")
        try Data("changed".utf8).write(to: URL(fileURLWithPath: blob))
        precondition(CleanupEvidence.executionBlocker(inspected, runner: runner) != nil)
        try data.write(to: URL(fileURLWithPath: blob))
        runner.opened = [blob]
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed)
        runner.opened = []; runner.processes = "go test ./..."
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed)
        runner.processes = "gopls serve"
        try "not a Go v1 action record".write(toFile: action, atomically: true, encoding: .utf8)
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed)
        try manifest.write(toFile: action, atomically: false, encoding: .utf8)
        let fresh = CleanupEvidence.applying(to: item, runner: runner)
        precondition(fresh.cleanupEvidence != nil)
        runner.handleCalls = 0
        runner.onHandles = { count in
            if count == 2 { try! Data("changed marker".utf8).write(to: URL(fileURLWithPath: cache + "/README")) }
        }
        precondition(CleanupEvidence.executionBlocker(fresh, runner: runner) != nil,
            "a changed Go marker during the final activity query must invalidate execution")
        runner.onHandles = nil
        try "This directory holds cached build artifacts from the Go build system.\n".write(toFile: cache + "/README", atomically: false, encoding: .utf8)
        var malformed = Array(manifest.utf8); malformed[152] = 32
        try Data(malformed).write(to: URL(fileURLWithPath: action))
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed, "trailing padding is not a valid Go numeric field")
        malformed = Array(manifest.utf8); malformed[154] = 9
        try Data(malformed).write(to: URL(fileURLWithPath: action))
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed, "tab padding is not a valid Go numeric field")
        print("GoBuildCacheEvidenceTests passed: generated content, v1 records, unknown data, actual usage and stale proofs")
    }
}
