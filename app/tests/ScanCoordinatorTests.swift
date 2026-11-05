// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class BlockingReader: DirectoryReading, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func read(fd: Int32, parentID: EntryID, rootDevice: UInt64,
              buffer: AttrBuffer, shouldContinue: @Sendable () -> Bool) throws -> DirectoryBatch {
        started.signal()
        release.wait()
        return DirectoryBatch(parentID: parentID, entries: [
            DirectoryItem(name: "result.bin", kind: .file, deviceID: rootDevice,
                fileID: UInt64(fd) + 100, linkCount: 1, logicalSize: 1024,
                allocatedSize: 4096, modifiedAt: 1, flags: [])
        ])
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanEvent] = []
    private var cancelledAt: [ScanGeneration: ContinuousClock.Instant] = [:]

    func append(_ event: ScanEvent) {
        lock.lock()
        storage.append(event)
        if case .cancelled(let generation) = event {
            cancelledAt[generation] = ContinuousClock.now
        }
        lock.unlock()
    }

    func events() -> [ScanEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func cancellationTime(for generation: ScanGeneration) -> ContinuousClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return cancelledAt[generation]
    }
}

@main
struct ScanCoordinatorTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-coordinator-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let reader = BlockingReader()
        let coordinator = ScanCoordinator(reader: reader, workerCount: 4,
            publishInterval: .milliseconds(10))
        let log = EventLog()

        let first = coordinator.start(root: root, priorityRoots: []) { log.append($0) }
        require(reader.started.wait(timeout: .now() + 1) == .success,
            "first generation should enter metadata read")
        first.cancel()

        let second = coordinator.start(root: root, priorityRoots: []) { log.append($0) }
        require(reader.started.wait(timeout: .now() + 1) == .success,
            "second generation should enter metadata read")

        let releasedAt = ContinuousClock.now
        reader.release.signal()
        reader.release.signal()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let events = log.events()
            let cancelled = events.contains { if case .cancelled(first.generation) = $0 { return true }; return false }
            let completed = events.contains { if case .completed(let result) = $0 { return result.generation == second.generation }; return false }
            if cancelled && completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let events = log.events()
        let firstCancelled = events.filter { if case .cancelled(first.generation) = $0 { return true }; return false }
        let firstLateResults = events.filter {
            switch $0 {
            case .progress(let progress): return progress.generation == first.generation
            case .partial(let partial): return partial.generation == first.generation
            case .completed(let result): return result.generation == first.generation
            default: return false
            }
        }
        let secondCompleted = events.contains {
            if case .completed(let result) = $0 { return result.generation == second.generation }
            return false
        }

        require(firstCancelled.count == 1, "cancelled generation should terminate exactly once")
        require(firstLateResults.isEmpty, "cancelled generation should publish no late results")
        require(secondCompleted, "new generation should complete normally")
        guard let cancelledAt = log.cancellationTime(for: first.generation) else {
            require(false, "cancellation timestamp should exist")
            return
        }
        require(releasedAt.duration(to: cancelledAt) < .milliseconds(100),
            "cancellation should publish within 100 ms after the active batch returns")

        let facadeReader = BlockingReader()
        let facadeTask = Task.detached {
            try await runIndexScan(root: root, reader: facadeReader, workerCount: 2)
        }
        require(facadeReader.started.wait(timeout: .now() + 1) == .success,
            "facade scan should enter metadata read")
        facadeTask.cancel()
        facadeReader.release.signal()
        do {
            _ = try await facadeTask.value
            require(false, "cancelled runIndexScan task must not return success")
        } catch is CancellationError {
            // Expected structured-concurrency behavior.
        }
        print("scan coordinator ok")
    }
}
