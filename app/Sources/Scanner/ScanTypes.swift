// SPDX-License-Identifier: MPL-2.0
import Foundation

typealias EntryID = UInt64
typealias ScanGeneration = UInt64

enum EntryKind: UInt8, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

struct EntryFlags: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt16

    static let package = Self(rawValue: 1 << 0)
    static let sparse = Self(rawValue: 1 << 1)
    static let purgeable = Self(rawValue: 1 << 2)
    static let mayShareContent = Self(rawValue: 1 << 3)
}

struct FileIdentity: Hashable, Codable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
}

struct ScanEntry: Codable, Equatable, Sendable {
    let id: EntryID
    let parentID: EntryID
    let fileID: UInt64
    let deviceID: UInt64
    let nameID: UInt32
    let kind: EntryKind
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let physicalAllocatedSize: UInt64
    let modifiedAt: Int64
    let flags: EntryFlags

    init(
        id: EntryID, parentID: EntryID, fileID: UInt64, deviceID: UInt64,
        nameID: UInt32, kind: EntryKind, logicalSize: UInt64, allocatedSize: UInt64,
        modifiedAt: Int64, flags: EntryFlags, physicalAllocatedSize: UInt64? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.fileID = fileID
        self.deviceID = deviceID
        self.nameID = nameID
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.physicalAllocatedSize = physicalAllocatedSize ?? allocatedSize
        self.modifiedAt = modifiedAt
        self.flags = flags
    }

    var identity: FileIdentity {
        FileIdentity(deviceID: deviceID, fileID: fileID)
    }
}

struct ScanDiagnostic: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case permissionDenied
        case disappeared
        case volumeDisconnected
        case metadataFailure
    }

    let path: String
    let kind: Kind
    let errorNumber: Int32?
}

struct ScanProgress: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case preparing
        case scanning
        case reconciling
        case completed
        case cancelled
    }

    let generation: ScanGeneration
    let phase: Phase
    let files: Int
    let directories: Int
    let allocatedBytes: UInt64
    let currentPath: String
}
