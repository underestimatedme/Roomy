// SPDX-License-Identifier: MPL-2.0
import CoreServices
import Foundation

enum VolumeEventTrackerError: Error {
    case streamCreationFailed
    case streamStartFailed
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [VolumeChange] = []

    func append(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        for index in 0..<count {
            if let change = VolumeEventTracker.change(path: paths[index], flags: flags[index]) {
                collected.append(change)
            }
        }
    }

    func snapshot() -> [VolumeChange] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    static func translate(_ flags: FSEventStreamEventFlags) -> VolumeChangeFlags {
        var result: VolumeChangeFlags = []
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
            result.insert(.mustScanSubdirectories)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
            result.insert(.eventIDsWrapped)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            result.insert(.rootChanged)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
            result.insert(.itemCreated)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            result.insert(.itemRemoved)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
            result.insert(.itemModified)
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
            result.insert(.itemRenamed)
        }
        return result
    }
}

private final class EventStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var cancelled = false

    func start(_ stream: FSEventStreamRef) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.stream = stream
        guard FSEventStreamStart(stream) else {
            self.stream = nil
            return false
        }
        return true
    }

    func finish(_ ownedStream: FSEventStreamRef) {
        lock.lock()
        if let active = stream {
            FSEventStreamStop(active)
            FSEventStreamInvalidate(active)
            stream = nil
        }
        lock.unlock()
        FSEventStreamRelease(ownedStream)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let active = stream {
            FSEventStreamStop(active)
            FSEventStreamInvalidate(active)
            stream = nil
        }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct VolumeEventTracker: Sendable {
    static func change(path: String, flags: FSEventStreamEventFlags) -> VolumeChange? {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
            return nil
        }
        return VolumeChange(path: path, flags: EventCollector.translate(flags))
    }

    static func eventStoreUUID(for deviceID: UInt64) -> UUID? {
        guard let value = FSEventsCopyUUIDForDevice(dev_t(deviceID)) else { return nil }
        let string = CFUUIDCreateString(nil, value) as String
        return UUID(uuidString: string)
    }

    func changes(since eventID: UInt64, root: URL) async throws -> EventBatch {
        let cancellation = EventStreamCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try collect(
                            since: eventID, root: root, cancellation: cancellation
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func collect(
        since eventID: UInt64,
        root: URL,
        cancellation: EventStreamCancellation
    ) throws -> EventBatch {
        if cancellation.isCancelled { throw CancellationError() }
        let collector = EventCollector()
        let checkpoint = UInt64(FSEventsGetCurrentEventId())
        let storeUUID = Self.eventStoreUUID(for: deviceID(of: root))
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, pathsPointer, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<EventCollector>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue() as NSArray
            guard let strings = paths as? [String], strings.count == count else { return }
            collector.append(paths: strings, flags: flags, count: count)
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.standardizedFileURL.path] as CFArray,
            FSEventStreamEventId(eventID),
            0.05,
            createFlags
        ) else {
            throw VolumeEventTrackerError.streamCreationFailed
        }
        defer {
            cancellation.finish(stream)
        }
        let queue = DispatchQueue(label: "app.roomy.fsevents.history")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard cancellation.start(stream) else {
            if cancellation.isCancelled { throw CancellationError() }
            throw VolumeEventTrackerError.streamStartFailed
        }
        FSEventStreamFlushSync(stream)
        if cancellation.isCancelled { throw CancellationError() }
        return EventBatch(
            changes: collector.snapshot(),
            endID: checkpoint,
            historyAvailable: storeUUID != nil,
            storeUUID: storeUUID
        )
    }

    private func deviceID(of root: URL) -> UInt64 {
        var value = stat()
        return lstat(root.path, &value) == 0 ? UInt64(UInt32(bitPattern: value.st_dev)) : 0
    }
}
