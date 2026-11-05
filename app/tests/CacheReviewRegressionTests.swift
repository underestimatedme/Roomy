// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation
import CoreServices

private func baseIndex(root: String) -> ScanIndex {
    var index = ScanIndex(rootPath: root)
    _ = index.append(parentID: 0, fileID: 1, deviceID: 7, name: "", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    index.finalizeAggregates()
    return index
}

private func metadata(root: String, volume: UUID, store: UUID? = nil,
                      diagnostics: [ScanDiagnostic] = []) -> CachedScan {
    CachedScan(index: baseIndex(root: root), metadata: SnapshotMetadata(
        volumeUUID: volume, rootDeviceID: 7, filesystem: "apfs", osVersion: "26",
        permissionScope: "user", lastEventID: 10, completedAt: Date(),
        eventStoreUUID: store, diagnostics: diagnostics
    ))
}

@main
struct CacheReviewRegressionTests {
    static func main() throws {
        precondition(VolumeEventTracker.change(path: "/tmp/root",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) == nil)

        let volume = UUID()
        let storeA = UUID()
        let identity = VolumeIdentity(uuid: volume, deviceID: 7,
            filesystem: "apfs", permissionScope: "user")
        let planner = IncrementalScanPlanner()
        precondition(planner.plan(snapshot: metadata(root: "/a", volume: volume,
            store: storeA).metadata, volume: identity,
            events: EventBatch(changes: [], endID: 11, storeUUID: UUID()))
            == .full(.eventHistoryLost))

        var original = ScanIndex(rootPath: "/root")
        _ = original.append(parentID: 0, fileID: 1, deviceID: 7, name: "", kind: .directory,
            logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let left = original.append(parentID: 0, fileID: 2, deviceID: 7, name: "left",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let right = original.append(parentID: 0, fileID: 3, deviceID: 7, name: "right",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        _ = original.append(parentID: left, fileID: 99, deviceID: 7, name: "a",
            kind: .file, logicalSize: 10, allocatedSize: 4096, modifiedAt: 1, flags: [],
            physicalAllocatedSize: 4096)
        _ = original.append(parentID: right, fileID: 99, deviceID: 7, name: "b",
            kind: .file, logicalSize: 10, allocatedSize: 0, modifiedAt: 1, flags: [],
            physicalAllocatedSize: 4096)
        original.finalizeAggregates()

        var replacement = ScanIndex(rootPath: "/root/right")
        _ = replacement.append(parentID: 0, fileID: 3, deviceID: 7, name: "",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 2, flags: [])
        _ = replacement.append(parentID: 0, fileID: 99, deviceID: 7, name: "b",
            kind: .file, logicalSize: 10, allocatedSize: 4096, modifiedAt: 2, flags: [],
            physicalAllocatedSize: 4096)
        replacement.finalizeAggregates()
        let patcher = IndexPatcher(pathExists: { $0 != "/root/gone" })
        let patched = try patcher.replaceSubtrees(in: original, with: ["/root/right": replacement])
        precondition(patched.totalAllocated(of: 0) == 4096)

        var withDeletedDirectory = original
        _ = withDeletedDirectory.append(parentID: 0, fileID: 5, deviceID: 7, name: "gone",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        withDeletedDirectory.finalizeAggregates()
        precondition(patcher.rescanRoots(["/root/gone"], in: withDeletedDirectory) == ["/root"])

        let diagnostic = ScanDiagnostic(path: "/root/private", kind: .permissionDenied,
            errorNumber: EACCES)
        let cached = metadata(root: "/root", volume: volume, diagnostics: [diagnostic])
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(
            index: cached.index, metadata: cached.metadata
        ))
        precondition(decoded.metadata.diagnostics == [diagnostic])

        var malformed = try SnapshotCodec.encode(index: cached.index, metadata: cached.metadata)
        let metadataLength = malformed.withUnsafeBytes { raw in
            Int(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
        }
        let indexStart = SnapshotFormat.headerSize + metadataLength
        let rootLength = malformed.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: indexStart, as: UInt32.self)))
        }
        var cursor = indexStart + 4 + rootLength
        let nameCount = malformed.withUnsafeBytes { raw in
            Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)))
        }
        cursor += 4
        let nameBytes = malformed.withUnsafeBytes { raw in
            Int(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)))
        }
        cursor += 8 + nameCount * 8 + nameBytes + 8
        var badID = UInt64(9).littleEndian
        withUnsafeBytes(of: &badID) { malformed.replaceSubrange(cursor..<(cursor + 8), with: $0) }
        let payload = malformed[SnapshotFormat.headerSize...]
        malformed.replaceSubrange(32..<64, with: Data(SHA256.hash(data: payload)))
        do {
            _ = try SnapshotCodec.decode(malformed)
            preconditionFailure("malformed entry IDs must be rejected")
        } catch SnapshotError.malformed {
            // Expected rather than a precondition crash.
        }

        print("cache review regressions ok")
    }
}
