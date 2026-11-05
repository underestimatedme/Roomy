// SPDX-License-Identifier: MPL-2.0
import Foundation

private final class MutatingSymbolRunner: CommandRunning {
    let file: String
    var mutated = false
    init(file: String) { self.file = file }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        if !mutated && arguments.contains("--uuid") {
            let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: file))
            try! handle.seekToEnd(); try! handle.write(contentsOf: Data([42])); try! handle.close()
            mutated = true
        }
        return ProcessRunner().run(executable, arguments, timeout: timeout)
    }
}

@main
struct CleanupSymbolsTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("roomy-symbols-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let root = realpath(temporary, nil).map { p in defer { free(p) }; return String(cString: p) }!
        defer { try? fm.removeItem(atPath: root) }
        let source = root + "/main.c", binary = root + "/App"
        try "int main(void) { return 0; }".write(toFile: source, atomically: true, encoding: .utf8)
        let runner = ProcessRunner()
        let compiled = runner.run("/usr/bin/xcrun", ["clang", "-g", source, "-o", binary], timeout: 30)
        precondition(compiled.ok, compiled.stderr)
        let xcode = root + "/Library/Developer/Xcode"
        let derived = xcode + "/DerivedData/App-abc"
        let dsym = derived + "/Build/Products/Release-iphoneos/App.app.dSYM"
        try fm.createDirectory(atPath: URL(fileURLWithPath: dsym).deletingLastPathComponent().path, withIntermediateDirectories: true)
        let symbols = runner.run("/usr/bin/xcrun", ["dsymutil", binary, "-o", dsym], timeout: 30)
        precondition(symbols.ok, symbols.stderr)
        let item = ScanItem.trashTarget(path: derived, name: "App", size: 4096, rule: "Xcode DerivedData", evidence: "", risk: .green)
        precondition(!CleanupEvidence.inspect(item).allowed, "real dSYM without archive must be retained")
        let backup = xcode + "/Archives/2026-10-22/App.xcarchive/dSYMs/App.app.dSYM"
        try fm.createDirectory(atPath: URL(fileURLWithPath: backup).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try fm.copyItem(atPath: dsym, toPath: backup)
        let checked = CleanupEvidence.applying(to: item)
        precondition(checked.undo && checked.cleanupEvidence != nil, "UUID and byte-identical archive should pass: \(checked.evidence)")
        let encoded = try JSONEncoder().encode(checked)
        let decoded = try JSONDecoder().decode(ScanItem.self, from: encoded)
        precondition(decoded.cleanupEvidence == checked.cleanupEvidence && decoded.withSize(8192).cleanupEvidence == checked.cleanupEvidence)
        let object = derived + "/Build/Intermediates.noindex/objects/A.o"
        try fm.createDirectory(atPath: URL(fileURLWithPath: object).deletingLastPathComponent().path, withIntermediateDirectories: true)
        precondition(runner.run("/usr/bin/xcrun", ["clang", "-c", source, "-o", object], timeout: 30).ok)
        let mutating = MutatingSymbolRunner(file: object)
        let changedDuringBackup = CleanupEvidence.inspect(item, runner: mutating)
        precondition(mutating.mutated && !changedDuringBackup.allowed,
            "deep changes during backup verification must invalidate the initial inventory")
        try "unique content".write(toFile: dsym + "/OnlyCopy.txt", atomically: true, encoding: .utf8)
        precondition(!CleanupEvidence.inspect(item).allowed, "matching DWARF does not back up extra local files in the dSYM bundle")
        try fm.removeItem(atPath: dsym + "/OnlyCopy.txt")
        try fm.removeItem(atPath: backup)
        precondition(CleanupEvidence.executionBlocker(checked) != nil, "deleting a backup after scanning revokes cleanup")
        print("CleanupSymbolsTests passed")
    }
}
