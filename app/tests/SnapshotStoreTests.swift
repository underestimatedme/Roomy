// SPDX-License-Identifier: MPL-2.0
import Foundation

private func makeCached(volume: UUID, eventID: UInt64, fileName: String) -> CachedScan {
    var index = ScanIndex(rootPath: "/")
    _ = index.append(parentID: 0, fileID: 1, deviceID: 2, name: "",
        kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    _ = index.append(parentID: 0, fileID: eventID + 10, deviceID: 2, name: fileName,
        kind: .file, logicalSize: 10, allocatedSize: 4096, modifiedAt: 2, flags: [])
    index.finalizeAggregates()
    return CachedScan(index: index, metadata: SnapshotMetadata(
        volumeUUID: volume, rootDeviceID: 2, filesystem: "apfs", osVersion: "26.0",
        permissionScope: "user", lastEventID: eventID,
        completedAt: Date(timeIntervalSince1970: Double(eventID))))
}

@main
struct SnapshotStoreTests {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("roomy-store-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: directory) }
        let volume = UUID()
        let original = makeCached(volume: volume, eventID: 1, fileName: "old.bin")
        let replacement = makeCached(volume: volume, eventID: 2, fileName: "new.bin")

        let store = SnapshotStore(directory: directory)
        try store.save(original, for: volume)
        guard case .hit(let firstLoad) = store.load(for: volume) else {
            preconditionFailure("saved snapshot should load")
        }
        precondition(firstLoad == original)

        let secondRoot = makeCached(volume: volume, eventID: 3, fileName: "second.bin")
        try store.save(original, for: volume, rootPath: "/Users/one")
        try store.save(secondRoot, for: volume, rootPath: "/Users/two")
        guard case .hit(let firstRoot) = store.load(for: volume, rootPath: "/Users/one"),
              case .hit(let secondRootLoad) = store.load(for: volume, rootPath: "/Users/two") else {
            preconditionFailure("roots on one volume need independent snapshots")
        }
        precondition(firstRoot == original && secondRootLoad == secondRoot)

        var failingFS = SnapshotFileSystem.live
        failingFS.replace = { _, _ in throw SnapshotStoreTestError.injected }
        let failingStore = SnapshotStore(directory: directory, fileSystem: failingFS)
        do {
            try failingStore.save(replacement, for: volume)
            preconditionFailure("injected pre-rename failure should escape")
        } catch SnapshotStoreTestError.injected {
            // Expected.
        }
        guard case .hit(let afterFailure) = store.load(for: volume) else {
            preconditionFailure("old snapshot should survive failed replacement")
        }
        precondition(afterFailure == original)

        try Data("broken".utf8).write(to: store.snapshotURL(for: volume))
        guard case .miss(.corrupt) = store.load(for: volume) else {
            preconditionFailure("corrupt snapshot should be a cache miss")
        }
        let quarantined = try fm.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("scan-index-\(volume.uuidString.lowercased()).corrupt-") }
        precondition(quarantined.count == 1, "corrupt snapshot should be quarantined")
        precondition(!fm.fileExists(atPath: store.snapshotURL(for: volume).path))
        print("snapshot store ok")
    }
}

private enum SnapshotStoreTestError: Error {
    case injected
}
