// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class DeletingReader: DirectoryReading, @unchecked Sendable {
    private let base = DirectoryReader()
    private let pathToDelete: String
    private let lock = NSLock()
    private var deleted = false

    init(pathToDelete: String) {
        self.pathToDelete = pathToDelete
    }

    func read(fd: Int32, parentID: EntryID, rootDevice: UInt64,
              buffer: AttrBuffer, shouldContinue: @Sendable () -> Bool) throws -> DirectoryBatch {
        let batch = try base.read(fd: fd, parentID: parentID,
            rootDevice: rootDevice, buffer: buffer, shouldContinue: shouldContinue)
        lock.lock()
        let shouldDelete = parentID == 0 && !deleted
        if shouldDelete { deleted = true }
        lock.unlock()
        if shouldDelete {
            try FileManager.default.removeItem(atPath: pathToDelete)
        }
        return batch
    }
}

@main
struct FullScanAcceptanceTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-full-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let keep = root.appendingPathComponent("keep")
        let nested = keep.appendingPathComponent("nested")
        let vanished = root.appendingPathComponent("vanished")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: vanished, withIntermediateDirectories: true)

        let original = keep.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 16_384).write(to: original)
        let linked = nested.appendingPathComponent("payload-hardlink.bin")
        require(Darwin.link(original.path, linked.path) == 0, "hard link should be created")
        require(Darwin.symlink(root.path, keep.appendingPathComponent("loop").path) == 0,
            "symlink cycle should be created")
        try Data("race".utf8).write(to: vanished.appendingPathComponent("gone.txt"))

        let completion = try await runIndexScan(
            root: root,
            priorityRoots: [keep],
            reader: DeletingReader(pathToDelete: vanished.path),
            workerCount: 4
        )
        let index = completion.index
        require(index.path(for: 0) == root.path, "index root should preserve the selected path")
        let names = index.entries.map { index.stringPool.value(for: $0.nameID) }
        require(names.contains("keep"), "surviving directory should be indexed")
        require(names.contains("nested"), "nested directory should be indexed")
        require(names.contains("payload.bin") && names.contains("payload-hardlink.bin"),
            "both hard-link paths should be indexed")
        guard let payloadID = index.entries.first(where: {
            index.stringPool.value(for: $0.nameID) == "payload.bin"
        })?.id else {
            require(false, "payload entry should have an ID")
            return
        }
        require(index.path(for: payloadID) == original.path,
            "restored paths should be absolute under the selected root")
        let hardLinks = index.entries.filter {
            let name = index.stringPool.value(for: $0.nameID)
            return name == "payload.bin" || name == "payload-hardlink.bin"
        }
        require(hardLinks.filter { $0.allocatedSize > 0 }.count == 1,
            "hard-linked bytes should be charged once")
        require(index.entries.filter { $0.kind == .symbolicLink }.count == 1,
            "symlink should be indexed without traversing its target")
        require(completion.diagnostics.contains { $0.kind == .disappeared },
            "directory removed after enumeration should be a race diagnostic")
        print("full scan acceptance ok")
    }
}
