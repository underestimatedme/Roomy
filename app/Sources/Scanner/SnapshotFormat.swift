// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct SnapshotMetadata: Codable, Equatable, Sendable {
    let volumeUUID: UUID
    let rootDeviceID: UInt64
    let filesystem: String
    let osVersion: String
    let permissionScope: String
    let lastEventID: UInt64
    let completedAt: Date
    let schemaVersion: UInt32
    let eventStoreUUID: UUID?
    let diagnostics: [ScanDiagnostic]

    init(
        volumeUUID: UUID,
        rootDeviceID: UInt64,
        filesystem: String,
        osVersion: String,
        permissionScope: String,
        lastEventID: UInt64,
        completedAt: Date,
        schemaVersion: UInt32 = SnapshotFormat.schema,
        eventStoreUUID: UUID? = nil,
        diagnostics: [ScanDiagnostic] = []
    ) {
        self.volumeUUID = volumeUUID
        self.rootDeviceID = rootDeviceID
        self.filesystem = filesystem
        self.osVersion = osVersion
        self.permissionScope = permissionScope
        self.lastEventID = lastEventID
        self.completedAt = completedAt
        self.schemaVersion = schemaVersion
        self.eventStoreUUID = eventStoreUUID
        self.diagnostics = diagnostics
    }
}

struct CachedScan: Equatable, Sendable {
    let index: ScanIndex
    let metadata: SnapshotMetadata
}

enum SnapshotError: Error, Equatable {
    case badMagic
    case unsupportedSchema(UInt32)
    case truncated
    case checksumMismatch
    case malformed(String)
}

enum SnapshotFormat {
    static let magic = Data("ROOMYIDX".utf8)
    static let schema: UInt32 = 2
    static let headerSize = 64
    static let entrySize = 72
}
