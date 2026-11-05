// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ScanAggregatorTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-aggregator-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)

        let original = a.appendingPathComponent("weights.bin")
        try Data(repeating: 0x5a, count: 8192).write(to: original)
        let linked = b.appendingPathComponent("weights-link.bin")
        require(Darwin.link(original.path, linked.path) == 0, "hard link fixture should be created")

        let loop = a.appendingPathComponent("back-to-root")
        require(Darwin.symlink(root.path, loop.path) == 0, "symlink fixture should be created")

        let sparse = a.appendingPathComponent("sparse.bin")
        let sparseFD = open(sparse.path, O_CREAT | O_WRONLY, 0o600)
        require(sparseFD >= 0, "sparse file should open")
        require(ftruncate(sparseFD, 1_048_576) == 0, "sparse file should resize")
        close(sparseFD)

        var rootStat = stat()
        require(lstat(root.path, &rootStat) == 0, "fixture root should stat")
        let device = UInt64(UInt32(bitPattern: rootStat.st_dev))
        let aggregator = ScanAggregator(
            rootPath: root.path,
            rootDevice: device,
            rootFileID: rootStat.st_ino
        )
        let reader = DirectoryReader()
        let buffer = AttrBuffer()

        func read(_ path: String, parentID: EntryID) throws -> DirectoryBatch {
            let fd = try openDir(path)
            defer { close(fd) }
            return try reader.read(fd: fd, parentID: parentID, rootDevice: device, buffer: buffer)
        }

        let rootResult = aggregator.consume(try read(root.path, parentID: 0))
        let directoryIDs = Dictionary(uniqueKeysWithValues: rootResult.directories.map { ($0.name, $0.entryID) })
        _ = aggregator.consume(try read(a.path, parentID: directoryIDs["a"]!))
        _ = aggregator.consume(try read(b.path, parentID: directoryIDs["b"]!))

        let index = aggregator.finalizedIndex()
        let weightEntries = index.entries.filter {
            let name = index.stringPool.value(for: $0.nameID)
            return name == "weights.bin" || name == "weights-link.bin"
        }
        require(weightEntries.count == 2, "both hard-link names should be indexed")
        require(weightEntries.filter { $0.allocatedSize > 0 }.count == 1,
            "hard-linked allocation should be charged exactly once")

        let symlinks = index.entries.filter { $0.kind == .symbolicLink }
        require(symlinks.count == 1, "symlink should be indexed but not traversed")
        require(symlinks[0].allocatedSize == 0, "symlink should not charge target bytes")

        guard let sparseEntry = index.entries.first(where: {
            index.stringPool.value(for: $0.nameID) == "sparse.bin"
        }) else {
            fputs("FAIL: sparse file should be indexed\n", stderr)
            exit(1)
        }
        require(sparseEntry.logicalSize == 1_048_576, "sparse logical size should be retained")
        require(sparseEntry.allocatedSize <= sparseEntry.logicalSize, "sparse allocation should not exceed logical size")
        require(sparseEntry.flags.contains(.sparse), "sparse file should be marked")

        let denied = DirectoryReader.diagnostic(for: BulkError.denied, path: a.path)
        require(denied.kind == .permissionDenied, "permission errors should be structured")
        let gone = DirectoryReader.diagnostic(for: BulkError.notFound, path: b.path)
        require(gone.kind == .disappeared, "missing directories should be structured as races")
        print("scan aggregator ok")
    }
}
