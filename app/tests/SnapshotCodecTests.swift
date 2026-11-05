// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func expectError(_ expected: SnapshotError, _ body: () throws -> Void) {
    do {
        try body()
        preconditionFailure("expected \(expected)")
    } catch let error as SnapshotError {
        precondition(error == expected, "expected \(expected), got \(error)")
    } catch {
        preconditionFailure("unexpected error \(error)")
    }
}

@main
struct SnapshotCodecTests {
    static func main() throws {
        var index = ScanIndex(rootPath: "/Users/example")
        _ = index.append(parentID: 0, fileID: 10, deviceID: 7, name: "",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let models = index.append(parentID: 0, fileID: 11, deviceID: 7, name: "Models",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 2, flags: [])
        _ = index.append(parentID: models, fileID: 12, deviceID: 7, name: "qwen.gguf",
            kind: .file, logicalSize: 100, allocatedSize: 4096, modifiedAt: 3,
            flags: [.mayShareContent])
        index.finalizeAggregates()

        let metadata = SnapshotMetadata(
            volumeUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            rootDeviceID: 7,
            filesystem: "apfs",
            osVersion: "26.0",
            permissionScope: "user",
            lastEventID: 42,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoded = try SnapshotCodec.encode(index: index, metadata: metadata)
        let decoded = try SnapshotCodec.decode(encoded)
        precondition(decoded.index == index)
        precondition(decoded.metadata == metadata)

        var badMagic = encoded
        badMagic[0] ^= 0xff
        expectError(.badMagic) { _ = try SnapshotCodec.decode(badMagic) }

        var badSchema = encoded
        badSchema[8] = 99
        badSchema[9] = 0
        badSchema[10] = 0
        badSchema[11] = 0
        expectError(.unsupportedSchema(99)) { _ = try SnapshotCodec.decode(badSchema) }

        var badChecksum = encoded
        badChecksum[badChecksum.count - 1] ^= 0xff
        expectError(.checksumMismatch) { _ = try SnapshotCodec.decode(badChecksum) }

        let truncated = encoded.dropLast()
        expectError(.truncated) { _ = try SnapshotCodec.decode(Data(truncated)) }
        print("snapshot codec ok")
    }
}
