// SPDX-License-Identifier: MPL-2.0
import Foundation

enum ScanPriority: UInt8, Codable, Sendable {
    case high
    case normal
}

struct DirectoryTask: Hashable, Codable, Sendable {
    let id: UInt64
    let path: String
    let parentID: EntryID
    let rootDevice: UInt64
    let expectedIdentity: FileIdentity?
    let priority: ScanPriority

    init(id: UInt64, path: String, parentID: EntryID, rootDevice: UInt64,
         expectedIdentity: FileIdentity? = nil, priority: ScanPriority) {
        self.id = id
        self.path = path
        self.parentID = parentID
        self.rootDevice = rootDevice
        self.expectedIdentity = expectedIdentity
        self.priority = priority
    }
}

private struct FIFO<Element> {
    private var storage: [Element] = []
    private var head = 0

    var isEmpty: Bool { head >= storage.count }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        if head >= 1024 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: false)
        head = 0
    }
}

actor DirectoryScheduler {
    let descriptorLimit: Int

    private var high = FIFO<DirectoryTask>()
    private var normal = FIFO<DirectoryTask>()
    private var waiters: [CheckedContinuation<DirectoryTask?, Never>] = []
    private var leasedTaskIDs: Set<UInt64> = []
    private var highBudget = 4
    private var isFinished = false

    private(set) var openLeaseCount = 0
    private(set) var peakOpenLeaseCount = 0
    private(set) var diagnostics: [ScanDiagnostic] = []

    init(descriptorLimit: Int = 64) {
        precondition(descriptorLimit > 0)
        self.descriptorLimit = descriptorLimit
    }

    func enqueue(_ task: DirectoryTask) {
        guard !isFinished else { return }
        switch task.priority {
        case .high: high.append(task)
        case .normal: normal.append(task)
        }
        resumeWaiters()
    }

    func next() async -> DirectoryTask? {
        if let task = leaseNextIfAvailable() {
            return task
        }
        if isFinished && queuesAreEmpty {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func complete(_ task: DirectoryTask, diagnostic: ScanDiagnostic? = nil) {
        guard leasedTaskIDs.remove(task.id) != nil else { return }
        openLeaseCount -= 1
        if let diagnostic {
            diagnostics.append(diagnostic)
        }
        resumeWaiters()
    }

    func finish() {
        isFinished = true
        resumeWaiters()
    }

    func abort() {
        isFinished = true
        high.removeAll()
        normal.removeAll()
        resumeWaiters()
    }

    private var queuesAreEmpty: Bool {
        high.isEmpty && normal.isEmpty
    }

    private func resumeWaiters() {
        while !waiters.isEmpty {
            if let task = leaseNextIfAvailable() {
                let waiter = waiters.removeFirst()
                waiter.resume(returning: task)
            } else if isFinished && queuesAreEmpty {
                let pending = waiters
                waiters.removeAll(keepingCapacity: false)
                for waiter in pending {
                    waiter.resume(returning: nil)
                }
                return
            } else {
                return
            }
        }
    }

    private func leaseNextIfAvailable() -> DirectoryTask? {
        guard openLeaseCount < descriptorLimit else { return nil }
        guard let task = popNext() else { return nil }
        guard leasedTaskIDs.insert(task.id).inserted else {
            preconditionFailure("directory task IDs must be unique")
        }
        openLeaseCount += 1
        peakOpenLeaseCount = max(peakOpenLeaseCount, openLeaseCount)
        return task
    }

    private func popNext() -> DirectoryTask? {
        if !high.isEmpty && !normal.isEmpty {
            if highBudget > 0 {
                highBudget -= 1
                return high.popFirst()
            }
            highBudget = 4
            return normal.popFirst()
        }
        if !high.isEmpty {
            return high.popFirst()
        }
        if !normal.isEmpty {
            highBudget = 4
            return normal.popFirst()
        }
        return nil
    }
}

struct WorkerPolicy: Sendable {
    private(set) var workerCount = 4
    private var slowSamples = 0
    private var fastSamples = 0

    mutating func sample(batchLatency: Duration) -> Int {
        if batchLatency > .milliseconds(40) {
            slowSamples += 1
            fastSamples = 0
            if slowSamples >= 3 {
                workerCount = max(2, workerCount - 1)
                slowSamples = 0
            }
        } else if batchLatency < .milliseconds(10) {
            fastSamples += 1
            slowSamples = 0
            if fastSamples >= 5 {
                workerCount = min(6, workerCount + 1)
                fastSamples = 0
            }
        } else {
            slowSamples = 0
            fastSamples = 0
        }
        return workerCount
    }
}
