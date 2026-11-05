// SPDX-License-Identifier: MPL-2.0
import Foundation

struct DiscoveredDirectory: Equatable, Sendable {
    let name: String
    let entryID: EntryID
    let identity: FileIdentity
}

struct AggregateBatchResult: Equatable, Sendable {
    let directories: [DiscoveredDirectory]
}

/// The coordinator gives this object exclusive access; it deliberately has no internal locks.
final class ScanAggregator {
    let rootPath: String
    let rootDevice: UInt64

    private var index: ScanIndex
    private var seenHardLinks: Set<FileIdentity> = []
    private(set) var fileCount = 0
    private(set) var directoryCount = 1
    private(set) var allocatedBytes: UInt64 = 0

    init(rootPath: String, rootDevice: UInt64, rootFileID: UInt64) {
        self.rootPath = rootPath
        self.rootDevice = rootDevice
        var newIndex = ScanIndex(rootPath: rootPath)
        newIndex.append(
            parentID: 0,
            fileID: rootFileID,
            deviceID: rootDevice,
            name: "",
            kind: .directory,
            logicalSize: 0,
            allocatedSize: 0,
            modifiedAt: 0,
            flags: []
        )
        index = newIndex
    }

    func consume(_ batch: DirectoryBatch) -> AggregateBatchResult {
        var directories: [DiscoveredDirectory] = []
        directories.reserveCapacity(batch.entries.count / 4)

        for item in batch.entries {
            var chargedBytes = item.allocatedSize
            if item.kind == .file && item.linkCount > 1 {
                let identity = FileIdentity(deviceID: item.deviceID, fileID: item.fileID)
                if !seenHardLinks.insert(identity).inserted {
                    chargedBytes = 0
                }
            }

            let entryID = index.append(
                parentID: batch.parentID,
                fileID: item.fileID,
                deviceID: item.deviceID,
                name: item.name,
                kind: item.kind,
                logicalSize: item.logicalSize,
                allocatedSize: chargedBytes,
                modifiedAt: item.modifiedAt,
                flags: item.flags,
                physicalAllocatedSize: item.allocatedSize
            )
            if item.kind == .file {
                fileCount += 1
                allocatedBytes &+= chargedBytes
            } else if item.kind == .directory {
                directoryCount += 1
                directories.append(DiscoveredDirectory(
                    name: item.name,
                    entryID: entryID,
                    identity: FileIdentity(deviceID: item.deviceID, fileID: item.fileID)
                ))
            }
        }
        return AggregateBatchResult(directories: directories)
    }

    func finalizedIndex() -> ScanIndex {
        var result = index
        result.finalizeAggregates()
        return result
    }
}
