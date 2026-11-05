// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin
import CoreServices

struct PartialScanSnapshot: Equatable, Sendable {
    let generation: ScanGeneration
    let sequence: UInt64
    let rootPath: String
    let files: Int
    let directories: Int
    let allocatedBytes: UInt64
}

struct ScanCompletion: Equatable, Sendable {
    let generation: ScanGeneration
    let index: ScanIndex
    let diagnostics: [ScanDiagnostic]
}

enum CacheTrustState: String, Equatable, Sendable {
    case fresh
    case validating
    case stale
    case unavailable
}

struct CachedScanPublication: Equatable, Sendable {
    let generation: ScanGeneration
    let index: ScanIndex
    let trust: CacheTrustState
}

struct ScanValidation: Equatable, Sendable {
    let generation: ScanGeneration
    let trust: CacheTrustState
}

enum ScanEvent: Equatable, Sendable {
    case cached(CachedScanPublication)
    case validation(ScanValidation)
    case progress(ScanProgress)
    case partial(PartialScanSnapshot)
    case completed(ScanCompletion)
    case cancelled(ScanGeneration)
    case failed(ScanGeneration, String)
}

struct CachedScanServices: @unchecked Sendable {
    var identity: @Sendable (URL) throws -> VolumeIdentity
    var load: @Sendable (UUID, String) -> SnapshotLoadResult
    var events: @Sendable (UInt64, URL) async throws -> EventBatch
    var save: @Sendable (CachedScan, UUID, String, @Sendable () -> Bool) throws -> Void
    var scan: @Sendable (URL, [URL], @escaping @Sendable (ScanEvent) -> Void) async throws -> ScanCompletion
    var currentCheckpoint: @Sendable (URL) -> (eventID: UInt64, storeUUID: UUID?)

    static func live(
        directory: URL,
        reader: any DirectoryReading,
        workerCount: Int,
        permissionScope: String = "user"
    ) -> CachedScanServices {
        let store = SnapshotStore(directory: directory)
        return CachedScanServices(
            identity: { root in try liveVolumeIdentity(root: root, permissionScope: permissionScope) },
            load: { store.load(for: $0, rootPath: $1) },
            events: { eventID, root in
                try await VolumeEventTracker().changes(since: eventID, root: root)
            },
            save: { try store.save($0, for: $1, rootPath: $2, shouldCommit: $3) },
            scan: { root, priorityRoots, onEvent in
                try await runIndexScan(root: root, priorityRoots: priorityRoots,
                    reader: reader, workerCount: workerCount, onEvent: onEvent)
            },
            currentCheckpoint: { root in
                var value = stat()
                let device = lstat(root.path, &value) == 0
                    ? UInt64(UInt32(bitPattern: value.st_dev)) : 0
                return (UInt64(FSEventsGetCurrentEventId()),
                    VolumeEventTracker.eventStoreUUID(for: device))
            }
        )
    }
}

private func liveVolumeIdentity(root: URL, permissionScope: String) throws -> VolumeIdentity {
    var rootStat = stat()
    guard lstat(root.path, &rootStat) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var fileSystem = statfs()
    guard statfs(root.path, &fileSystem) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let filesystem = withUnsafePointer(to: &fileSystem.f_fstypename) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
    }
    let resources = try root.resourceValues(forKeys: [.volumeUUIDStringKey])
    guard let value = resources.volumeUUIDString, let uuid = UUID(uuidString: value) else {
        throw CocoaError(.fileReadUnknown)
    }
    return VolumeIdentity(
        uuid: uuid,
        deviceID: UInt64(UInt32(bitPattern: rootStat.st_dev)),
        filesystem: filesystem,
        permissionScope: permissionScope
    )
}

struct ScanHandle: Sendable {
    let generation: ScanGeneration
    private let cancellation: @Sendable () -> Void

    init(generation: ScanGeneration, cancellation: @escaping @Sendable () -> Void) {
        self.generation = generation
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation()
    }
}

private actor PendingDirectoryCount {
    private var count = 1

    func completed(discovered: Int) -> Bool {
        count += discovered - 1
        precondition(count >= 0, "pending directory count underflow")
        return count == 0
    }
}

private actor ScanTerminalState {
    private(set) var failure: String?

    func fail(_ message: String) {
        if failure == nil { failure = message }
    }
}

private actor ScanPublicationState {
    private let interval: Duration
    private var lastPublished: ContinuousClock.Instant?
    private var sequence: UInt64 = 0

    init(interval: Duration) {
        self.interval = interval
    }

    func nextSequenceIfDue() -> UInt64? {
        let now = ContinuousClock.now
        if let lastPublished, lastPublished.duration(to: now) < interval {
            return nil
        }
        lastPublished = now
        sequence &+= 1
        return sequence
    }
}

private actor ScanAggregationStore {
    private let aggregator: ScanAggregator
    private var diagnostics: [ScanDiagnostic] = []

    init(rootPath: String, rootDevice: UInt64, rootFileID: UInt64) {
        aggregator = ScanAggregator(rootPath: rootPath, rootDevice: rootDevice, rootFileID: rootFileID)
    }

    func consume(_ batch: DirectoryBatch) -> AggregateBatchResult {
        aggregator.consume(batch)
    }

    func record(_ diagnostic: ScanDiagnostic) {
        diagnostics.append(diagnostic)
    }

    func partial(generation: ScanGeneration, sequence: UInt64) -> PartialScanSnapshot {
        PartialScanSnapshot(
            generation: generation,
            sequence: sequence,
            rootPath: aggregator.rootPath,
            files: aggregator.fileCount,
            directories: aggregator.directoryCount,
            allocatedBytes: aggregator.allocatedBytes
        )
    }

    func progress(generation: ScanGeneration, path: String) -> ScanProgress {
        ScanProgress(
            generation: generation,
            phase: .scanning,
            files: aggregator.fileCount,
            directories: aggregator.directoryCount,
            allocatedBytes: aggregator.allocatedBytes,
            currentPath: path
        )
    }

    func completion(generation: ScanGeneration) -> ScanCompletion {
        ScanCompletion(
            generation: generation,
            index: aggregator.finalizedIndex(),
            diagnostics: diagnostics
        )
    }
}

final class ScanCoordinator: @unchecked Sendable {
    typealias EventHandler = @Sendable (ScanEvent) -> Void

    private let reader: any DirectoryReading
    private let workerCount: Int
    private let publishInterval: Duration
    private let cacheServices: CachedScanServices?
    private let stateLock = NSLock()
    private var nextGeneration: ScanGeneration = 0
    private var activeGeneration: ScanGeneration?
    private var tasks: [ScanGeneration: Task<Void, Never>] = [:]

    init(
        reader: any DirectoryReading = DirectoryReader(),
        workerCount: Int = 8,
        publishInterval: Duration = .milliseconds(150),
        cacheServices: CachedScanServices? = nil
    ) {
        self.reader = reader
        self.workerCount = min(8, max(2, workerCount))
        self.publishInterval = publishInterval
        self.cacheServices = cacheServices
    }

    convenience init(cacheServices: CachedScanServices) {
        self.init(reader: DirectoryReader(), workerCount: 8,
            publishInterval: .milliseconds(150), cacheServices: cacheServices)
    }

    func start(
        root: URL,
        priorityRoots: [URL],
        onEvent: @escaping EventHandler
    ) -> ScanHandle {
        stateLock.lock()
        nextGeneration &+= 1
        let generation = nextGeneration
        let previous = activeGeneration.flatMap { tasks[$0] }
        activeGeneration = generation
        stateLock.unlock()
        previous?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: generation, root: root,
                priorityRoots: priorityRoots, onEvent: onEvent)
        }
        stateLock.lock()
        tasks[generation] = task
        stateLock.unlock()

        return ScanHandle(generation: generation) { [weak self] in
            self?.cancel(generation: generation)
        }
    }

    func resume(
        root: URL,
        priorityRoots: [URL],
        onEvent: @escaping EventHandler
    ) -> ScanHandle {
        stateLock.lock()
        nextGeneration &+= 1
        let generation = nextGeneration
        let previous = activeGeneration.flatMap { tasks[$0] }
        activeGeneration = generation
        stateLock.unlock()
        previous?.cancel()

        let services = cacheServices ?? Self.defaultCacheServices(
            reader: reader, workerCount: workerCount
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runResume(generation: generation, root: root,
                priorityRoots: priorityRoots, services: services, onEvent: onEvent)
        }
        stateLock.lock()
        tasks[generation] = task
        stateLock.unlock()
        return ScanHandle(generation: generation) { [weak self] in
            self?.cancel(generation: generation)
        }
    }

    private static func defaultCacheServices(
        reader: any DirectoryReading,
        workerCount: Int
    ) -> CachedScanServices {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Roomy", isDirectory: true)
        return .live(directory: applicationSupport, reader: reader, workerCount: workerCount)
    }

    private func runResume(
        generation: ScanGeneration,
        root: URL,
        priorityRoots: [URL],
        services: CachedScanServices,
        onEvent: @escaping EventHandler
    ) async {
        do {
            let volume = try services.identity(root)
            let loadResult = services.load(volume.uuid, root.path)
            switch loadResult {
            case .hit(let cached) where Self.matches(cached, volume: volume, root: root):
                publish(.cached(CachedScanPublication(generation: generation,
                    index: cached.index, trust: .validating)), generation: generation, onEvent: onEvent)
                let events: EventBatch
                do {
                    events = try await services.events(cached.metadata.lastEventID, root)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let checkpoint = services.currentCheckpoint(root)
                    try await completeFullScan(generation: generation, root: root,
                        priorityRoots: priorityRoots, volume: volume, checkpoint: checkpoint,
                        trust: .stale, services: services, onEvent: onEvent)
                    removeTask(generation: generation)
                    return
                }
                try Task.checkCancellation()
                switch IncrementalScanPlanner().plan(
                    snapshot: cached.metadata, volume: volume, events: events
                ) {
                case .reuse:
                    let metadata = Self.metadata(volume: volume, eventID: events.endID,
                        storeUUID: events.storeUUID, diagnostics: cached.metadata.diagnostics)
                    let reconciled = CachedScan(index: cached.index, metadata: metadata)
                    try commit(reconciled, volume: volume.uuid, root: root,
                        generation: generation, services: services)
                    try Task.checkCancellation()
                    publish(.validation(ScanValidation(generation: generation, trust: .fresh)),
                        generation: generation, onEvent: onEvent)
                    publish(.completed(ScanCompletion(generation: generation,
                        index: cached.index, diagnostics: cached.metadata.diagnostics)),
                        generation: generation, onEvent: onEvent)
                case .incremental(let paths):
                    let roots = IndexPatcher().rescanRoots(paths, in: cached.index)
                    var replacements: [String: ScanIndex] = [:]
                    var diagnostics = cached.metadata.diagnostics
                    for path in roots {
                        try Task.checkCancellation()
                        let completion = try await scanWithProgress(
                            URL(fileURLWithPath: path), priorityRoots: [], generation: generation,
                            services: services, onEvent: onEvent)
                        replacements[path] = completion.index
                        diagnostics.append(contentsOf: completion.diagnostics)
                    }
                    let patched = try IndexPatcher().replaceSubtrees(
                        in: cached.index, with: replacements
                    )
                    try Task.checkCancellation()
                    let reconciled = CachedScan(index: patched,
                        metadata: Self.metadata(volume: volume, eventID: events.endID,
                            storeUUID: events.storeUUID, diagnostics: diagnostics))
                    try commit(reconciled, volume: volume.uuid, root: root,
                        generation: generation, services: services)
                    try Task.checkCancellation()
                    publish(.validation(ScanValidation(generation: generation, trust: .fresh)),
                        generation: generation, onEvent: onEvent)
                    publish(.completed(ScanCompletion(generation: generation,
                        index: patched, diagnostics: diagnostics)), generation: generation, onEvent: onEvent)
                case .full:
                    try await completeFullScan(generation: generation, root: root,
                        priorityRoots: priorityRoots, volume: volume,
                        checkpoint: (events.endID, events.storeUUID),
                        trust: .stale, services: services, onEvent: onEvent)
                }
            case .hit, .miss:
                let checkpoint = services.currentCheckpoint(root)
                try await completeFullScan(generation: generation, root: root,
                    priorityRoots: priorityRoots, volume: volume, checkpoint: checkpoint,
                    trust: .unavailable, services: services, onEvent: onEvent)
            }
        } catch is CancellationError {
            publish(.cancelled(generation), generation: generation, onEvent: onEvent)
        } catch {
            publish(.failed(generation, error.localizedDescription),
                generation: generation, onEvent: onEvent)
        }
        removeTask(generation: generation)
    }

    private func completeFullScan(
        generation: ScanGeneration,
        root: URL,
        priorityRoots: [URL],
        volume: VolumeIdentity,
        checkpoint: (eventID: UInt64, storeUUID: UUID?),
        trust: CacheTrustState,
        services: CachedScanServices,
        onEvent: @escaping EventHandler
    ) async throws {
        publish(.validation(ScanValidation(generation: generation, trust: trust)),
            generation: generation, onEvent: onEvent)
        let completion = try await scanWithProgress(root, priorityRoots: priorityRoots,
            generation: generation, services: services, onEvent: onEvent)
        try Task.checkCancellation()
        let cached = CachedScan(index: completion.index,
            metadata: Self.metadata(volume: volume, eventID: checkpoint.eventID,
                storeUUID: checkpoint.storeUUID, diagnostics: completion.diagnostics))
        try commit(cached, volume: volume.uuid, root: root,
            generation: generation, services: services)
        try Task.checkCancellation()
        publish(.validation(ScanValidation(generation: generation, trust: .fresh)),
            generation: generation, onEvent: onEvent)
        publish(.completed(ScanCompletion(generation: generation,
            index: completion.index, diagnostics: completion.diagnostics)),
            generation: generation, onEvent: onEvent)
    }

    private func scanWithProgress(
        _ root: URL,
        priorityRoots: [URL],
        generation: ScanGeneration,
        services: CachedScanServices,
        onEvent: @escaping EventHandler
    ) async throws -> ScanCompletion {
        try await services.scan(root, priorityRoots) { [weak self] event in
            guard let self else { return }
            switch event {
            case .progress(let value):
                self.publish(.progress(ScanProgress(generation: generation, phase: value.phase,
                    files: value.files, directories: value.directories,
                    allocatedBytes: value.allocatedBytes, currentPath: value.currentPath)),
                    generation: generation, onEvent: onEvent)
            case .partial(let value):
                self.publish(.partial(PartialScanSnapshot(generation: generation,
                    sequence: value.sequence, rootPath: value.rootPath,
                    files: value.files, directories: value.directories,
                    allocatedBytes: value.allocatedBytes)), generation: generation, onEvent: onEvent)
            default: break
            }
        }
    }

    private func commit(
        _ cached: CachedScan,
        volume: UUID,
        root: URL,
        generation: ScanGeneration,
        services: CachedScanServices
    ) throws {
        try services.save(cached, volume, root.path) { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.isActive(generation)
        }
    }

    private func isActive(_ generation: ScanGeneration) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeGeneration == generation
    }

    private static func matches(_ cached: CachedScan, volume: VolumeIdentity, root: URL) -> Bool {
        let snapshot = cached.metadata
        return snapshot.schemaVersion == SnapshotFormat.schema &&
        snapshot.volumeUUID == volume.uuid &&
        snapshot.rootDeviceID == volume.deviceID &&
        snapshot.filesystem == volume.filesystem &&
        snapshot.permissionScope == volume.permissionScope &&
        URL(fileURLWithPath: cached.index.rootPath).standardizedFileURL.path ==
            root.standardizedFileURL.path
    }

    private static func metadata(volume: VolumeIdentity, eventID: UInt64,
                                 storeUUID: UUID?, diagnostics: [ScanDiagnostic]) -> SnapshotMetadata {
        SnapshotMetadata(volumeUUID: volume.uuid, rootDeviceID: volume.deviceID,
            filesystem: volume.filesystem, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            permissionScope: volume.permissionScope, lastEventID: eventID, completedAt: Date(),
            eventStoreUUID: storeUUID, diagnostics: diagnostics)
    }

    private func cancel(generation: ScanGeneration) {
        stateLock.lock()
        let task = tasks[generation]
        stateLock.unlock()
        task?.cancel()
    }

    private func run(
        generation: ScanGeneration,
        root: URL,
        priorityRoots: [URL],
        onEvent: @escaping EventHandler
    ) async {
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            publish(.failed(generation, String(cString: strerror(errno))),
                generation: generation, onEvent: onEvent)
            removeTask(generation: generation)
            return
        }

        let rootDevice = UInt64(UInt32(bitPattern: rootStat.st_dev))
        let scheduler = DirectoryScheduler(descriptorLimit: 64)
        let pending = PendingDirectoryCount()
        let terminal = ScanTerminalState()
        let publication = ScanPublicationState(interval: publishInterval)
        let store = ScanAggregationStore(rootPath: root.path, rootDevice: rootDevice,
            rootFileID: rootStat.st_ino)
        let priorityPaths = priorityRoots.map { $0.standardizedFileURL.path }

        await scheduler.enqueue(DirectoryTask(id: 0, path: root.path, parentID: 0,
            rootDevice: rootDevice,
            expectedIdentity: FileIdentity(deviceID: rootDevice, fileID: rootStat.st_ino),
            priority: .high))

        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask { [reader] in
                        let buffer = AttrBuffer()
                        while !Task.isCancelled, let work = await scheduler.next() {
                            let terminalFailure = await terminal.failure
                            if Task.isCancelled || terminalFailure != nil {
                                await scheduler.complete(work)
                                break
                            }
                            do {
                                let fd = try openDir(work.path)
                                var openedStat = stat()
                                guard fstat(fd, &openedStat) == 0 else {
                                    let number = errno
                                    close(fd)
                                    throw BulkError.other(number)
                                }
                                let openedIdentity = FileIdentity(
                                    deviceID: UInt64(UInt32(bitPattern: openedStat.st_dev)),
                                    fileID: openedStat.st_ino
                                )
                                guard work.expectedIdentity == nil || work.expectedIdentity == openedIdentity else {
                                    close(fd)
                                    throw BulkError.identityChanged
                                }
                                let batch: DirectoryBatch
                                do {
                                    batch = try reader.read(fd: fd, parentID: work.parentID,
                                        rootDevice: work.rootDevice, buffer: buffer,
                                        shouldContinue: { !Task.isCancelled })
                                } catch {
                                    close(fd)
                                    throw error
                                }
                                close(fd)

                                if Task.isCancelled {
                                    await scheduler.complete(work)
                                    break
                                }

                                let result = await store.consume(batch)
                                let drained = await pending.completed(discovered: result.directories.count)
                                for directory in result.directories {
                                    let path = URL(fileURLWithPath: work.path)
                                        .appendingPathComponent(directory.name).path
                                    let priority: ScanPriority = Self.isPrioritized(path, roots: priorityPaths)
                                        ? .high : .normal
                                    await scheduler.enqueue(DirectoryTask(id: directory.entryID, path: path,
                                        parentID: directory.entryID, rootDevice: rootDevice,
                                        expectedIdentity: directory.identity, priority: priority))
                                }
                                await scheduler.complete(work)
                                if drained { await scheduler.finish() }

                                if !Task.isCancelled,
                                   let sequence = await publication.nextSequenceIfDue() {
                                    let progress = await store.progress(generation: generation, path: work.path)
                                    let partial = await store.partial(generation: generation, sequence: sequence)
                                    self.publish(.progress(progress), generation: generation, onEvent: onEvent)
                                    self.publish(.partial(partial), generation: generation, onEvent: onEvent)
                                }
                            } catch {
                                if case BulkError.cancelled = error {
                                    await scheduler.complete(work)
                                    break
                                }
                                let diagnostic = DirectoryReader.diagnostic(for: error, path: work.path)
                                await store.record(diagnostic)
                                if diagnostic.kind == .volumeDisconnected {
                                    await terminal.fail("扫描卷已断开")
                                    await scheduler.complete(work, diagnostic: diagnostic)
                                    await scheduler.abort()
                                    break
                                }
                                let drained = await pending.completed(discovered: 0)
                                await scheduler.complete(work, diagnostic: diagnostic)
                                if drained { await scheduler.finish() }
                            }
                        }
                    }
                }
            }
        } onCancel: {
            Task.detached {
                await scheduler.finish()
            }
        }

        if let terminalFailure = await terminal.failure {
            publish(.failed(generation, terminalFailure), generation: generation, onEvent: onEvent)
        } else if Task.isCancelled {
            onEvent(.cancelled(generation))
        } else {
            let completion = await store.completion(generation: generation)
            publish(.completed(completion), generation: generation, onEvent: onEvent)
        }
        removeTask(generation: generation)
    }

    private static func isPrioritized(_ path: String, roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func publish(
        _ event: ScanEvent,
        generation: ScanGeneration,
        onEvent: EventHandler
    ) {
        stateLock.lock()
        let active = activeGeneration == generation
        stateLock.unlock()
        if active { onEvent(event) }
    }

    private func removeTask(generation: ScanGeneration) {
        stateLock.lock()
        tasks[generation] = nil
        stateLock.unlock()
    }
}

enum IndexScanError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class IndexScanContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(
        _ continuation: CheckedContinuation<ScanCompletion, Error>,
        with result: Result<ScanCompletion, Error>
    ) {
        lock.lock()
        guard !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class IndexScanHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: ScanHandle?
    private var cancellationRequested = false

    func install(_ handle: ScanHandle) {
        lock.lock()
        self.handle = handle
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { handle.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let installed = handle
        lock.unlock()
        installed?.cancel()
    }
}

func runIndexScan(
    root: URL,
    priorityRoots: [URL] = [],
    reader: any DirectoryReading = DirectoryReader(),
    workerCount: Int = 8,
    onEvent: ScanCoordinator.EventHandler? = nil
) async throws -> ScanCompletion {
    let coordinator = ScanCoordinator(reader: reader, workerCount: workerCount)
    let gate = IndexScanContinuationGate()
    let handleBox = IndexScanHandleBox()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let handle = coordinator.start(root: root, priorityRoots: priorityRoots) { event in
                _ = coordinator
                onEvent?(event)
                switch event {
                case .completed(let completion):
                    gate.resume(continuation, with: .success(completion))
                case .cancelled:
                    gate.resume(continuation, with: .failure(CancellationError()))
                case .failed(_, let message):
                    gate.resume(continuation, with: .failure(IndexScanError.failed(message)))
                case .cached, .validation, .progress, .partial:
                    break
                }
            }
            handleBox.install(handle)
        }
    } onCancel: {
        handleBox.cancel()
    }
}
