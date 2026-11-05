// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private struct DisconnectingReader: DirectoryReading {
    func read(fd: Int32, parentID: EntryID, rootDevice: UInt64,
              buffer: AttrBuffer, shouldContinue: @Sendable () -> Bool) throws -> DirectoryBatch {
        throw BulkError.other(ENODEV)
    }
}

private final class DisconnectEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanEvent] = []
    func append(_ event: ScanEvent) { lock.lock(); values.append(event); lock.unlock() }
    func snapshot() -> [ScanEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

@main
struct VolumeDisconnectTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-disconnect-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let finished = DispatchSemaphore(value: 0)
        let events = DisconnectEvents()
        let coordinator = ScanCoordinator(reader: DisconnectingReader(), workerCount: 2)
        _ = coordinator.start(root: root, priorityRoots: []) { event in
            events.append(event)
            if case .failed = event { finished.signal() }
            if case .completed = event { finished.signal() }
        }
        precondition(finished.wait(timeout: .now() + 2) == .success)
        let captured = events.snapshot()
        precondition(captured.contains { if case .failed = $0 { return true }; return false })
        precondition(!captured.contains { if case .completed = $0 { return true }; return false })
        print("volume disconnect terminal ok")
    }
}
