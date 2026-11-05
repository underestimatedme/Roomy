// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

private final class GradleDownloadProcesses: CommandRunning {
    var processes = "/sbin/launchd"
    var opened: [String] = []
    var failed = false
    var handleCalls = 0
    var onHandles: ((Int) -> Void)?
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/usr/sbin/lsof" { handleCalls += 1; onHandles?(handleCalls) }
        let handles = "p123\0\nf0\0n/dev/null\0" + opened.map { "f12\0n" + $0 + "\0" }.joined()
        return .init(status: failed ? 1 : 0, stdout: executable == "/bin/ps" ? processes : handles,
            stderr: "", timedOut: false)
    }
}

@main struct GradleDownloadEvidenceTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-gradle-download-" + UUID().uuidString
        let cache = root + "/.gradle/caches"
        let module = cache + "/modules-2/files-2.1/org.example/library"
        let bytes = Data("artifact-258".utf8)
        let fullDigest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let digest = String(fullDigest.drop(while: { $0 == "0" }))
        let hashDir = module + "/1.0/" + digest
        let blob = hashDir + "/library-1.0.jar"
        try fm.createDirectory(atPath: hashDir, withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: blob))
        let padded = module + "/2.0/" + fullDigest
        try fm.createDirectory(atPath: padded, withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: padded + "/library-2.0.jar"))
        defer { try? fm.removeItem(atPath: root) }
        let runner = GradleDownloadProcesses()
        let parent = CleanupEvidence.applying(to: ScanItem.trashTarget(path: cache, name: "Gradle",
            size: 4096, rule: "Gradle 缓存", evidence: "", risk: .amber), runner: runner)
        precondition(!parent.undo, "mixed Gradle root must remain review-only")
        let children = CleanupEvidence.generatedChildren(of: parent, runner: runner)
        guard let generated = children.first(where: { $0.path == module }) else {
            preconditionFailure("hash-verified Gradle dependency content must be exposed independently")
        }
        let entry = CleanupCategories.assign(CleanupListBuilder.fromRule(generated)).entry
        precondition(entry.selectable && entry.tier == .rebuildable && !entry.defaultChecked)
        precondition(entry.category == "devcache")
        precondition(CleanupPreferenceKeys.forRule(generated)?.owner == "gradle")
        precondition(CleanupEvidence.executionBlocker(generated, runner: runner) == nil)

        try Data("local change".utf8).write(to: URL(fileURLWithPath: blob))
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        precondition(CleanupEvidence.executionBlocker(generated, runner: runner) != nil)
        try bytes.write(to: URL(fileURLWithPath: blob))
        try Data("only copy".utf8).write(to: URL(fileURLWithPath: module + "/notes.txt"))
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed, "unknown content must not be swept with downloads")
        try fm.removeItem(atPath: module + "/notes.txt")
        try fm.createSymbolicLink(atPath: hashDir + "/link.jar", withDestinationPath: blob)
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        try fm.removeItem(atPath: hashDir + "/link.jar")
        // The checksum store holds one artifact at each digest leaf, not arbitrary siblings.
        try bytes.write(to: URL(fileURLWithPath: hashDir + "/extra.jar"))
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        try fm.removeItem(atPath: hashDir + "/extra.jar")
        for command in ["java org.gradle.launcher.daemon.bootstrap.GradleDaemon 9.3.1",
                        "./gradlew assembleDebug", "/opt/gradle/bin/gradle build",
                        "/bin/sh ./gradlew build"] {
            runner.processes = command
            precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed, "Gradle activity: \(command)")
        }
        runner.processes = "java unrelated.server.Main"
        precondition(CleanupEvidence.inspect(generated, runner: runner).allowed, "unrelated Java process is not Gradle")
        runner.opened = [blob]
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        runner.opened = []; runner.failed = true
        precondition(!CleanupEvidence.inspect(generated, runner: runner).allowed)
        runner.failed = false
        let fresh = CleanupEvidence.applying(to: generated, runner: runner)
        runner.handleCalls = 0
        runner.onHandles = { count in
            if count == 2 { try! Data("late modification".utf8).write(to: URL(fileURLWithPath: blob)) }
        }
        precondition(CleanupEvidence.executionBlocker(fresh, runner: runner) != nil, "final activity query must not hide writes")
        print("GradleDownloadEvidenceTests passed: SHA-1 content, independent modules, unknown files, links, activity and stale proofs")
    }
}
