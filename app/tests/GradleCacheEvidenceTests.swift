// SPDX-License-Identifier: MPL-2.0
import Foundation

private final class GradleProcesses: CommandRunning {
    var output = "/sbin/launchd\n/usr/bin/ordinary-program\n"
    var succeeds = true
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        precondition(executable == "/bin/ps" && arguments == ["-axo", "command="])
        return CommandResult(status: succeeds ? 0 : 1, stdout: output, stderr: "", timedOut: false)
    }
}

@main struct GradleCacheEvidenceTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-gradle-" + UUID().uuidString
        let cache = root + "/.gradle/caches"
        try fm.createDirectory(atPath: cache + "/modules-2/files-2.1", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let tag = cache + "/CACHEDIR.TAG"
        let signature = "Signature: 8a477f597d28d172789f06886806bc55\n# Gradle cache\n"
        let runner = GradleProcesses()
        let item = ScanItem(name: "Gradle", path: cache, size: 10, atimeDays: nil, mtimeDays: 100,
            rule: "Gradle 缓存", evidence: "", risk: .green, gentle: nil, hard: "移到废纸篓", undo: true,
            note: "", rebuild: .cheap)
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed, "a folder name is insufficient")
        try signature.write(toFile: tag, atomically: true, encoding: .utf8)
        let verified = CleanupEvidence.inspect(item, runner: runner)
        precondition(!verified.allowed, "a cache tag and known top-level layout cannot prove all nested content rebuildable")
        var checked = item
        checked.cleanupEvidence = verified.snapshot
        precondition(CleanupTierPolicy.forRule(checked).tier == .review)
        precondition(!CleanupListBuilder.fromRule(checked).entry.defaultChecked)

        let personal = cache + "/OnlyCopy.txt"
        try "unique data".write(toFile: personal, atomically: true, encoding: .utf8)
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed, "unknown top-level content overrides a cache tag")
        try fm.removeItem(atPath: personal)
        try "only copy".write(toFile: cache + "/modules-2/files-2.1/OnlyCopy.txt", atomically: true, encoding: .utf8)
        let unknown = CleanupEvidence.inspect(item, runner: runner)
        precondition(!unknown.allowed, "unknown nested content must stay review even under a recognized directory")
        var legacy = item
        legacy.cleanupEvidence = unknown.snapshot ?? .init(version: 1, fingerprint: "previous-unsafe-policy")
        precondition(CleanupEvidence.executionBlocker(legacy) != nil, "an unchanged unknown target cannot survive execution recheck")
        runner.output = "java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14"
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed, "a running Gradle daemon blocks cache moves")
        runner.output = ""; runner.succeeds = false
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed, "failed activity checks must fail closed")
        runner.succeeds = true
        try "not a cache tag".write(toFile: tag, atomically: true, encoding: .utf8)
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed)
        try signature.write(toFile: tag, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: cache + "/modules-2/link", withDestinationPath: root)
        precondition(!CleanupEvidence.inspect(item, runner: runner).allowed)
        print("GradleCacheEvidenceTests passed: cache tags and known parent names never authorize unknown payloads")
    }
}
