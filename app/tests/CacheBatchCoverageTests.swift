// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

private final class BatchProcesses: CommandRunning {
    var calls = 0
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls += 1
        return .init(status: 0, stdout: executable == "/bin/ps" ? "npm exec language-server mcp" : "p123\0\nf0\0n/dev/null\0", stderr: "", timedOut: false)
    }
}

@main struct CacheBatchCoverageTests {
    static func main() throws {
        let root = "/private/tmp/roomy-cache-batch-" + UUID().uuidString
        let cache = root + "/.npm/_cacache", fm = FileManager.default
        defer { try? fm.removeItem(atPath: root) }
        var buckets = Set<String>(), seed = 0
        while buckets.count < 70 {
            let data = Data("cache fixture \(seed)".utf8); seed += 1
            let digest = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let prefix = String(digest.prefix(2))
            guard buckets.insert(prefix).inserted else { continue }
            let parent = cache + "/content-v2/sha512/" + prefix + "/" + digest.dropFirst(2).prefix(2)
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: parent + "/" + digest.dropFirst(4)))
        }
        let item = ScanItem(name: "npm", path: cache, size: 1, atimeDays: nil, mtimeDays: nil,
            rule: "包管理器缓存", evidence: "", risk: .amber, gentle: nil, hard: "", undo: false, note: "", rebuild: .free)
        let runner = BatchProcesses()
        let children = CleanupEvidence.generatedChildren(of: item, runner: runner)
        precondition(children.count == 70, "all verified buckets should be represented, not a hard cap of 64")
        precondition(runner.calls <= 6, "activity checks should be shared within one scan, with a fresh post-scan check")
        print("CacheBatchCoverageTests passed: 70 verified buckets, no coarse process blocker or 64-bucket cut-off")
    }
}
