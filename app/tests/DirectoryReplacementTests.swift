// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private final class ReplacingAncestorReader: DirectoryReading, @unchecked Sendable {
    private let base = DirectoryReader()
    private let ancestor: URL
    private let backup: URL
    private let replacement: URL
    private let lock = NSLock()
    private var replaced = false

    init(ancestor: URL, backup: URL, replacement: URL) {
        self.ancestor = ancestor
        self.backup = backup
        self.replacement = replacement
    }

    func read(fd: Int32, parentID: EntryID, rootDevice: UInt64,
              buffer: AttrBuffer, shouldContinue: @Sendable () -> Bool) throws -> DirectoryBatch {
        let batch = try base.read(fd: fd, parentID: parentID,
            rootDevice: rootDevice, buffer: buffer, shouldContinue: shouldContinue)
        lock.lock()
        let shouldReplace = !replaced && batch.entries.contains { $0.name == "B" }
        if shouldReplace { replaced = true }
        lock.unlock()
        if shouldReplace {
            try FileManager.default.moveItem(at: ancestor, to: backup)
            guard symlink(replacement.path, ancestor.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        return batch
    }
}

@main
struct DirectoryReplacementTests {
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("roomy-replacement-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let ancestor = root.appendingPathComponent("A")
        let originalB = ancestor.appendingPathComponent("B")
        let backup = base.appendingPathComponent("original-A")
        let outside = base.appendingPathComponent("outside")
        let outsideB = outside.appendingPathComponent("B")
        try fm.createDirectory(at: originalB, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideB, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideB.appendingPathComponent("escaped.bin"))
        defer { try? fm.removeItem(at: base) }

        let completion = try await runIndexScan(root: root,
            reader: ReplacingAncestorReader(ancestor: ancestor, backup: backup, replacement: outside),
            workerCount: 2)
        let names = completion.index.entries.map { completion.index.stringPool.value(for: $0.nameID) }
        precondition(!names.contains("escaped.bin"), "replacement symlink must not escape the selected tree")
        precondition(completion.diagnostics.contains { $0.kind == .disappeared },
            "replaced directory identity should be reported as a race")
        print("directory replacement guarded")
    }
}
