// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

private final class CountingReader: DirectoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [FileIdentity: Int] = [:]
    private let base = DirectoryReader()

    func read(fd: Int32, parentID: EntryID, rootDevice: UInt64,
              buffer: AttrBuffer, shouldContinue: @Sendable () -> Bool) throws -> DirectoryBatch {
        var info = stat()
        precondition(fstat(fd, &info) == 0)
        let identity = FileIdentity(deviceID: UInt64(UInt32(bitPattern: info.st_dev)),
            fileID: info.st_ino)
        lock.lock(); reads[identity, default: 0] += 1; lock.unlock()
        return try base.read(fd: fd, parentID: parentID, rootDevice: rootDevice,
            buffer: buffer, shouldContinue: shouldContinue)
    }

    func counts() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return Array(reads.values)
    }
}

@main
struct UnifiedTraversalTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-unified-\(UUID().uuidString)")
        let overlap = root.appendingPathComponent(".ollama/models/project/node_modules")
        try FileManager.default.createDirectory(at: overlap, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: overlap.appendingPathComponent("model.gguf"))
        defer { try? FileManager.default.removeItem(at: root) }

        let reader = CountingReader()
        let report = try await runUnifiedScan(root: root, reader: reader, workerCount: 4)
        precondition(reader.counts().allSatisfy { $0 == 1 },
            "production report path must enumerate each directory identity once")
        precondition(report.version == 2 && report.complete)
        precondition(report.stats.files == 1)
        print("unified traversal ok")
    }
}
