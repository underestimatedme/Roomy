// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

private final class NpmProcesses: CommandRunning {
    var output = "/sbin/launchd\n/bin/ordinary-process"
    var succeeds = true
    var opened: [String] = []
    var handleCalls = 0
    var onHandles: ((Int) -> Void)?
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/usr/sbin/lsof" { handleCalls += 1; onHandles?(handleCalls) }
        let text = executable == "/usr/sbin/lsof" ? "p123\0\nf0\0n/dev/null\0" + opened.map { "f12\0n" + $0 + "\0" }.joined() : output
        return CommandResult(status: succeeds ? 0 : 1, stdout: text, stderr: "", timedOut: false)
    }
}

@main struct NpmCacheEvidenceTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-npm-" + UUID().uuidString
        let cache = root + "/.npm/_cacache"
        let data = Data("cached package or registry response".utf8)
        let digest = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let bucket = cache + "/content-v2/sha512/" + digest.prefix(2)
        let parent = bucket + "/" + digest.dropFirst(2).prefix(2)
        let blob = parent + "/" + digest.dropFirst(4)
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: blob))
        defer { try? fm.removeItem(atPath: root) }
        let runner = NpmProcesses()
        let original = ScanItem(name: "npm", path: cache, size: 4096, atimeDays: nil, mtimeDays: 500,
            rule: "包管理器缓存", evidence: "", risk: .green, gentle: nil, hard: "移到废纸篓", undo: true,
            note: "", rebuild: .free)
        let checked = CleanupEvidence.applying(to: original)
        precondition(!checked.undo, "the mixed npm index/temp root is not a verified content unit")
        let unit = ScanItem.trashTarget(path: bucket, name: "content", size: 4096, rule: "npm 下载缓存", evidence: "", risk: .amber)
        let direct = CleanupEvidence.inspect(unit, runner: runner)
        precondition(direct.allowed, "fixture content inspection: \(direct.reason)")
        let children = CleanupEvidence.generatedChildren(of: checked, runner: runner)
        guard let generated = children.first(where: { $0.path == bucket }) else { preconditionFailure("verified npm SHA-512 content should be exposed independently") }
        let candidate = CleanupListBuilder.fromRule(generated)
        precondition(candidate.entry.tier == .rebuildable && candidate.entry.selectable && !candidate.entry.defaultChecked)
        let proof = CleanupEvidence.inspect(generated, runner: runner)
        precondition(proof.allowed && proof.snapshot?.kind == "npmCache")
        try Data("corrupt or locally changed".utf8).write(to: URL(fileURLWithPath: blob))
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        precondition(CleanupEvidence.executionBlocker(generated, runner: runner) != nil, "deep changes must invalidate the content proof")
        try data.write(to: URL(fileURLWithPath: blob))
        try Data("unique data".utf8).write(to: URL(fileURLWithPath: bucket + "/OnlyCopy.txt"))
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        try fm.removeItem(atPath: bucket + "/OnlyCopy.txt")
        runner.output = "node /opt/npm/bin/npm-cli.js install"
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        runner.output = "npm exec xcodebuildmcp mcp\nnpm run dev\nnode language-server.js"
        precondition(CleanupEvidence.inspect(generated, runner: runner).allowed,
            "idle long-running npm tools must not hide unrelated cache contents")
        runner.opened = [blob]
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed, "an actually open content blob must remain blocked")
        runner.opened = []
        runner.output = "/sbin/launchd"; runner.succeeds = false
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        runner.succeeds = true; runner.output = "npm exec tool mcp"; runner.handleCalls = 0
        let fresh = CleanupEvidence.applying(to: unit, runner: runner)
        precondition(fresh.cleanupEvidence != nil)
        runner.handleCalls = 0
        runner.onHandles = { count in
            if count == 2 {
                let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: blob))
                try! handle.write(contentsOf: Data(repeating: 88, count: data.count)); try! handle.close()
            }
        }
        precondition(CleanupEvidence.executionBlocker(fresh, runner: runner) != nil,
            "a nested change during the final activity query must invalidate execution")
        print("NpmCacheEvidenceTests passed: independent hash-verified buckets, unknown files, corrupt blobs, active tools and stale proof")
    }
}
