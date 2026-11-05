// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import CryptoKit

private final class SnapshotWriteLock: @unchecked Sendable {
    let value = NSLock()
}

enum SnapshotMissReason: Equatable {
    case notFound
    case incompatible
    case corrupt
}

enum SnapshotLoadResult: Equatable {
    case hit(CachedScan)
    case miss(SnapshotMissReason)
}

struct SnapshotFileSystem {
    var createDirectory: (URL) throws -> Void
    var read: (URL) throws -> Data
    var write: (Data, URL) throws -> Void
    var synchronize: (URL) throws -> Void
    var exists: (URL) -> Bool
    var replace: (URL, URL) throws -> Void
    var copy: (URL, URL) throws -> Void
    var move: (URL, URL) throws -> Void
    var remove: (URL) throws -> Void

    static var live: SnapshotFileSystem {
        let manager = FileManager.default
        return SnapshotFileSystem(
            createDirectory: { url in
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            },
            read: { url in try Data(contentsOf: url, options: .mappedIfSafe) },
            write: { data, url in try data.write(to: url) },
            synchronize: { url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.synchronize()
            },
            exists: { manager.fileExists(atPath: $0.path) },
            replace: { source, destination in
                guard Darwin.rename(source.path, destination.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            },
            copy: { source, destination in try manager.copyItem(at: source, to: destination) },
            move: { source, destination in try manager.moveItem(at: source, to: destination) },
            remove: { url in try manager.removeItem(at: url) }
        )
    }
}

struct SnapshotStore {
    let directory: URL
    private var fileSystem: SnapshotFileSystem
    private let writeLock: SnapshotWriteLock

    init(directory: URL, fileSystem: SnapshotFileSystem = .live) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.writeLock = SnapshotWriteLock()
    }

    func snapshotURL(for volumeUUID: UUID) -> URL {
        directory.appendingPathComponent("scan-index-\(volumeUUID.uuidString.lowercased()).roomyidx")
    }

    func snapshotURL(for volumeUUID: UUID, rootPath: String) -> URL {
        let normalized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(
            "scan-index-\(volumeUUID.uuidString.lowercased())-\(digest).roomyidx"
        )
    }

    func save(_ cachedScan: CachedScan, for volumeUUID: UUID) throws {
        try save(cachedScan, to: snapshotURL(for: volumeUUID), shouldCommit: { true })
    }

    func save(
        _ cachedScan: CachedScan,
        for volumeUUID: UUID,
        rootPath: String,
        shouldCommit: @Sendable () -> Bool = { true }
    ) throws {
        try save(cachedScan, to: snapshotURL(for: volumeUUID, rootPath: rootPath),
            shouldCommit: shouldCommit)
    }

    private func save(
        _ cachedScan: CachedScan,
        to destination: URL,
        shouldCommit: @Sendable () -> Bool
    ) throws {
        writeLock.value.lock()
        defer { writeLock.value.unlock() }
        try fileSystem.createDirectory(directory)
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let previous = directory.appendingPathComponent(".\(destination.lastPathComponent).previous")
        defer { try? fileSystem.remove(temporary) }

        let encoded = try SnapshotCodec.encode(index: cachedScan.index, metadata: cachedScan.metadata)
        try fileSystem.write(encoded, temporary)
        try fileSystem.synchronize(temporary)
        _ = try SnapshotCodec.decode(fileSystem.read(temporary))
        guard shouldCommit() else { throw CancellationError() }

        if fileSystem.exists(previous) { try fileSystem.remove(previous) }
        if fileSystem.exists(destination) { try fileSystem.copy(destination, previous) }

        do {
            try fileSystem.replace(temporary, destination)
            _ = try SnapshotCodec.decode(fileSystem.read(destination))
            if fileSystem.exists(previous) { try fileSystem.remove(previous) }
        } catch {
            if fileSystem.exists(previous) {
                try? fileSystem.replace(previous, destination)
            }
            throw error
        }
    }

    func load(for volumeUUID: UUID) -> SnapshotLoadResult {
        load(at: snapshotURL(for: volumeUUID), volumeUUID: volumeUUID)
    }

    func load(for volumeUUID: UUID, rootPath: String) -> SnapshotLoadResult {
        load(at: snapshotURL(for: volumeUUID, rootPath: rootPath), volumeUUID: volumeUUID)
    }

    private func load(at url: URL, volumeUUID: UUID) -> SnapshotLoadResult {
        guard fileSystem.exists(url) else { return .miss(.notFound) }
        do {
            return .hit(try SnapshotCodec.decode(fileSystem.read(url)))
        } catch SnapshotError.unsupportedSchema {
            return .miss(.incompatible)
        } catch {
            quarantine(url, volumeUUID: volumeUUID)
            return .miss(.corrupt)
        }
    }

    private func quarantine(_ url: URL, volumeUUID: UUID) {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1_000))
        let quarantined = directory.appendingPathComponent(
            "scan-index-\(volumeUUID.uuidString.lowercased()).corrupt-\(timestamp)"
        )
        try? fileSystem.move(url, quarantined)
    }
}
