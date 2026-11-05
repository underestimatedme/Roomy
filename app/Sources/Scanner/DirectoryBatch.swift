// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct DirectoryItem: Equatable, Sendable {
    let name: String
    let kind: EntryKind
    let deviceID: UInt64
    let fileID: UInt64
    let linkCount: UInt32
    let logicalSize: UInt64
    let allocatedSize: UInt64
    let modifiedAt: Int64
    let flags: EntryFlags
}

struct DirectoryBatch: Equatable, Sendable {
    let parentID: EntryID
    let entries: [DirectoryItem]
}

protocol DirectoryReading: Sendable {
    func read(
        fd: Int32,
        parentID: EntryID,
        rootDevice: UInt64,
        buffer: AttrBuffer,
        shouldContinue: @Sendable () -> Bool
    ) throws -> DirectoryBatch
}

extension DirectoryReading {
    func read(
        fd: Int32,
        parentID: EntryID,
        rootDevice: UInt64,
        buffer: AttrBuffer
    ) throws -> DirectoryBatch {
        try read(fd: fd, parentID: parentID, rootDevice: rootDevice,
            buffer: buffer, shouldContinue: { true })
    }
}

struct DirectoryReader: DirectoryReading {
    static func diagnostic(for error: Error, path: String) -> ScanDiagnostic {
        switch error {
        case BulkError.denied:
            return ScanDiagnostic(path: path, kind: .permissionDenied, errorNumber: EACCES)
        case BulkError.notFound:
            return ScanDiagnostic(path: path, kind: .disappeared, errorNumber: ENOENT)
        case BulkError.identityChanged:
            return ScanDiagnostic(path: path, kind: .disappeared, errorNumber: ESTALE)
        case BulkError.cancelled:
            return ScanDiagnostic(path: path, kind: .metadataFailure, errorNumber: ECANCELED)
        case BulkError.other(let number) where number == ENODEV || number == ENXIO:
            return ScanDiagnostic(path: path, kind: .volumeDisconnected, errorNumber: number)
        case BulkError.other(let number):
            return ScanDiagnostic(path: path, kind: .metadataFailure, errorNumber: number)
        default:
            return ScanDiagnostic(path: path, kind: .metadataFailure, errorNumber: nil)
        }
    }

    func read(
        fd: Int32,
        parentID: EntryID,
        rootDevice: UInt64,
        buffer: AttrBuffer,
        shouldContinue: @Sendable () -> Bool
    ) throws -> DirectoryBatch {
        var raw: [DirEntry] = []
        raw.reserveCapacity(128)
        try readEntries(fd: fd, into: &raw, buf: buffer, shouldContinue: shouldContinue)

        let items = raw.compactMap { entry -> DirectoryItem? in
            guard entry.dev == rootDevice else { return nil }
            let kind: EntryKind
            if entry.isFile {
                kind = .file
            } else if entry.isDir {
                kind = .directory
            } else if entry.isLink {
                kind = .symbolicLink
            } else {
                kind = .other
            }

            var flags: EntryFlags = []
            if kind == .file && entry.logical > entry.alloc {
                flags.insert(.sparse)
            }
            // APFS does not expose cheap per-entry clone ownership in the hot bulk path.
            // Treat regular files as possibly shared until a future exact extent query proves otherwise.
            if kind == .file { flags.insert(.mayShareContent) }
            if kind == .directory && Self.packageExtensions.contains(
                (entry.name as NSString).pathExtension.lowercased()
            ) {
                flags.insert(.package)
            }

            return DirectoryItem(
                name: entry.name,
                kind: kind,
                deviceID: entry.dev,
                fileID: entry.fileID,
                linkCount: entry.links,
                logicalSize: entry.logical,
                allocatedSize: kind == .symbolicLink ? 0 : entry.alloc,
                modifiedAt: Int64(entry.mtime),
                flags: flags
            )
        }
        return DirectoryBatch(parentID: parentID, entries: items)
    }

    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "pkg"
    ]
}
