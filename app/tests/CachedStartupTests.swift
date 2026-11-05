// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private final class CacheEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanEvent] = []
    func append(_ event: ScanEvent) { lock.lock(); values.append(event); lock.unlock() }
    func snapshot() -> [ScanEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class BlockingSave: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private func makeIndex(root: String, file: String, bytes: UInt64) -> ScanIndex {
    var index = ScanIndex(rootPath: root)
    _ = index.append(parentID: 0, fileID: 1, deviceID: 7, name: "", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    _ = index.append(parentID: 0, fileID: UInt64(file.hashValue.magnitude), deviceID: 7,
        name: file, kind: .file, logicalSize: bytes, allocatedSize: bytes,
        modifiedAt: 1, flags: [])
    index.finalizeAggregates()
    return index
}

private func waitForTerminal(_ log: CacheEventLog) async throws -> [ScanEvent] {
    for _ in 0..<400 {
        let events = log.snapshot()
        if events.contains(where: {
            if case .completed = $0 { return true }
            if case .cancelled = $0 { return true }
            if case .failed = $0 { return true }
            return false
        }) { return events }
        try await Task.sleep(for: .milliseconds(5))
    }
    preconditionFailure("cache startup did not terminate")
}

@main
struct CachedStartupTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/Users/test")
        let volumeID = UUID()
        let volume = VolumeIdentity(uuid: volumeID, deviceID: 7,
            filesystem: "apfs", permissionScope: "user")
        let metadata = SnapshotMetadata(volumeUUID: volumeID, rootDeviceID: 7,
            filesystem: "apfs", osVersion: "26.0", permissionScope: "user",
            lastEventID: 10, completedAt: Date())
        let cached = CachedScan(index: makeIndex(root: root.path, file: "old.bin", bytes: 10),
            metadata: metadata)

        let reuseLog = CacheEventLog()
        let reuse = ScanCoordinator(cacheServices: CachedScanServices(
            identity: { _ in volume },
            load: { _, _ in .hit(cached) },
            events: { _, _ in
                try await Task.sleep(for: .milliseconds(30))
                return EventBatch(changes: [], endID: 11)
            },
            save: { _, _, _, shouldCommit in if !shouldCommit() { throw CancellationError() } },
            scan: { _, _, _ in preconditionFailure("reuse must not scan") },
            currentCheckpoint: { _ in (11, nil) }
        ))
        _ = reuse.resume(root: root, priorityRoots: []) { reuseLog.append($0) }
        let reuseEvents = try await waitForTerminal(reuseLog)
        guard case .cached(let publication) = reuseEvents.first else {
            preconditionFailure("matching cache must publish before validation")
        }
        precondition(publication.trust == .validating)
        precondition(reuseEvents.contains { if case .validation(let value) = $0 { return value.trust == .fresh }; return false })

        let dirtyLog = CacheEventLog()
        let dirty = ScanCoordinator(cacheServices: CachedScanServices(
            identity: { _ in volume }, load: { _, _ in .hit(cached) },
            events: { _, _ in EventBatch(changes: [
                VolumeChange(path: "/Users/test/old.bin", flags: [.itemModified])
            ], endID: 12) },
            save: { _, _, _, shouldCommit in if !shouldCommit() { throw CancellationError() } },
            scan: { url, _, _ in
                ScanCompletion(generation: 99,
                    index: makeIndex(root: url.path, file: "new.bin", bytes: 20), diagnostics: [])
            },
            currentCheckpoint: { _ in (12, nil) }
        ))
        _ = dirty.resume(root: root, priorityRoots: []) { dirtyLog.append($0) }
        let dirtyEvents = try await waitForTerminal(dirtyLog)
        guard let dirtyCompletion = dirtyEvents.compactMap({ event -> ScanCompletion? in
            if case .completed(let value) = event { return value }; return nil
        }).last else { preconditionFailure("dirty cache must complete") }
        precondition(dirtyCompletion.index.path(for: 1) == "/Users/test/new.bin")

        for loadResult in [SnapshotLoadResult.miss(.corrupt), .hit(CachedScan(
            index: cached.index,
            metadata: SnapshotMetadata(volumeUUID: UUID(), rootDeviceID: 7,
                filesystem: "apfs", osVersion: "26.0", permissionScope: "user",
                lastEventID: 10, completedAt: Date())
        )), .hit(CachedScan(index: makeIndex(root: "/Users/another", file: "wrong.bin", bytes: 1),
            metadata: metadata))] {
            let log = CacheEventLog()
            let coordinator = ScanCoordinator(cacheServices: CachedScanServices(
                identity: { _ in volume }, load: { _, _ in loadResult },
                events: { _, _ in EventBatch(changes: [], endID: 13) },
                save: { _, _, _, shouldCommit in if !shouldCommit() { throw CancellationError() } },
                scan: { url, _, _ in ScanCompletion(generation: 2,
                    index: makeIndex(root: url.path, file: "fresh.bin", bytes: 30), diagnostics: []) },
                currentCheckpoint: { _ in (13, nil) }
            ))
            _ = coordinator.resume(root: root, priorityRoots: []) { log.append($0) }
            let events = try await waitForTerminal(log)
            precondition(!events.contains { if case .cached = $0 { return true }; return false },
                "invalid cache identity must never publish")
            precondition(events.contains { if case .completed = $0 { return true }; return false })
        }

        let cancelLog = CacheEventLog()
        let cancelling = ScanCoordinator(cacheServices: CachedScanServices(
            identity: { _ in volume }, load: { _, _ in .hit(cached) },
            events: { _, _ in try await Task.sleep(for: .seconds(5)); return EventBatch(changes: [], endID: 14) },
            save: { _, _, _, shouldCommit in if !shouldCommit() { throw CancellationError() } },
            scan: { _, _, _ in preconditionFailure("cancelled validation must not scan") },
            currentCheckpoint: { _ in (14, nil) }
        ))
        let handle = cancelling.resume(root: root, priorityRoots: []) { cancelLog.append($0) }
        try await Task.sleep(for: .milliseconds(20))
        handle.cancel()
        let cancelEvents = try await waitForTerminal(cancelLog)
        precondition(cancelEvents.contains { if case .cancelled = $0 { return true }; return false })

        let saveLog = CacheEventLog()
        let blocker = BlockingSave()
        let saving = ScanCoordinator(cacheServices: CachedScanServices(
            identity: { _ in volume }, load: { _, _ in .hit(cached) },
            events: { _, _ in EventBatch(changes: [], endID: 15) },
            save: { _, _, _, shouldCommit in
                blocker.entered.signal()
                blocker.release.wait()
                guard shouldCommit() else { throw CancellationError() }
            },
            scan: { _, _, _ in preconditionFailure("reuse must not scan") },
            currentCheckpoint: { _ in (15, nil) }
        ))
        let saveHandle = saving.resume(root: root, priorityRoots: []) { saveLog.append($0) }
        precondition(blocker.entered.wait(timeout: .now() + 1) == .success)
        saveHandle.cancel()
        blocker.release.signal()
        let saveEvents = try await waitForTerminal(saveLog)
        precondition(saveEvents.contains { if case .cancelled = $0 { return true }; return false })
        precondition(!saveEvents.contains { if case .completed = $0 { return true }; return false })

        let progressLog = CacheEventLog()
        let full = ScanCoordinator(cacheServices: CachedScanServices(
            identity: { _ in volume }, load: { _, _ in .miss(.notFound) },
            events: { _, _ in EventBatch(changes: [], endID: 16) },
            save: { _, _, _, shouldCommit in guard shouldCommit() else { throw CancellationError() } },
            scan: { url, _, callback in
                callback(.progress(ScanProgress(generation: 99, phase: .scanning,
                    files: 1, directories: 1, allocatedBytes: 20, currentPath: url.path)))
                return ScanCompletion(generation: 99,
                    index: makeIndex(root: url.path, file: "fresh.bin", bytes: 20), diagnostics: [])
            },
            currentCheckpoint: { _ in (16, nil) }
        ))
        let fullHandle = full.resume(root: root, priorityRoots: []) { progressLog.append($0) }
        let progressEvents = try await waitForTerminal(progressLog)
        precondition(progressEvents.contains {
            if case .progress(let value) = $0 { return value.generation == fullHandle.generation }
            return false
        })

        let deniedLog = CacheEventLog()
        let deniedEvents = ScanCoordinator(cacheServices: CachedScanServices(
            identity: { _ in volume }, load: { _, _ in .hit(cached) },
            events: { _, _ in throw VolumeEventTrackerError.streamStartFailed },
            save: { _, _, _, shouldCommit in guard shouldCommit() else { throw CancellationError() } },
            scan: { url, _, _ in ScanCompletion(generation: 99,
                index: makeIndex(root: url.path, file: "new-after-denial.bin", bytes: 42), diagnostics: []) },
            currentCheckpoint: { _ in (17, nil) }
        ))
        _ = deniedEvents.resume(root: root, priorityRoots: []) { deniedLog.append($0) }
        let deniedResult = try await waitForTerminal(deniedLog)
        precondition(deniedResult.contains { if case .validation(let value) = $0 { return value.trust == .stale }; return false })
        precondition(deniedResult.contains { if case .completed(let value) = $0 { return value.index.totalAllocated(of: 0) == 42 }; return false },
            "denied events must replace the stale cache with a full scan, not authorize old results")
        print("cached startup ok (including unavailable FSEvents full-scan fallback)")
    }
}
