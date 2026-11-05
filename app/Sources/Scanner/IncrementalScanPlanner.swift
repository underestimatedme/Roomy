// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct VolumeIdentity: Equatable, Sendable {
    let uuid: UUID
    let deviceID: UInt64
    let filesystem: String
    let permissionScope: String
}

struct VolumeChangeFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt32

    static let mustScanSubdirectories = Self(rawValue: 1 << 0)
    static let eventIDsWrapped = Self(rawValue: 1 << 1)
    static let rootChanged = Self(rawValue: 1 << 2)
    static let itemCreated = Self(rawValue: 1 << 3)
    static let itemRemoved = Self(rawValue: 1 << 4)
    static let itemModified = Self(rawValue: 1 << 5)
    static let itemRenamed = Self(rawValue: 1 << 6)
}

struct VolumeChange: Equatable, Sendable {
    let path: String
    let flags: VolumeChangeFlags
}

struct EventBatch: Equatable, Sendable {
    let changes: [VolumeChange]
    let endID: UInt64
    let historyAvailable: Bool
    let storeUUID: UUID?

    init(changes: [VolumeChange], endID: UInt64, historyAvailable: Bool = true,
         storeUUID: UUID? = nil) {
        self.changes = changes
        self.endID = endID
        self.historyAvailable = historyAvailable
        self.storeUUID = storeUUID
    }
}

enum FullScanReason: Equatable, Sendable {
    case schemaMismatch
    case volumeChanged
    case eventHistoryLost
    case rootChanged
}

enum RescanPlan: Equatable, Sendable {
    case reuse
    case incremental([String])
    case full(FullScanReason)
}

struct IncrementalScanPlanner {
    func plan(snapshot: SnapshotMetadata, volume: VolumeIdentity, events: EventBatch) -> RescanPlan {
        guard snapshot.schemaVersion == SnapshotFormat.schema else {
            return .full(.schemaMismatch)
        }
        guard snapshot.volumeUUID == volume.uuid,
              snapshot.rootDeviceID == volume.deviceID,
              snapshot.filesystem == volume.filesystem,
              snapshot.permissionScope == volume.permissionScope else {
            return .full(.volumeChanged)
        }
        guard events.historyAvailable, events.endID >= snapshot.lastEventID,
              snapshot.eventStoreUUID == events.storeUUID else {
            return .full(.eventHistoryLost)
        }
        if events.changes.contains(where: {
            !$0.flags.intersection([.mustScanSubdirectories, .eventIDsWrapped]).isEmpty
        }) {
            return .full(.eventHistoryLost)
        }
        if events.changes.contains(where: { $0.flags.contains(.rootChanged) }) {
            return .full(.rootChanged)
        }

        let retryPaths = snapshot.diagnostics.compactMap { diagnostic in
            diagnostic.kind == .permissionDenied ? diagnostic.path : nil
        }
        let paths = Array(Set(events.changes.map(\.path) + retryPaths)).sorted()
        return paths.isEmpty ? .reuse : .incremental(paths)
    }
}
