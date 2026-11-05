// SPDX-License-Identifier: MPL-2.0
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@main
struct DirectorySchedulerTests {
    static func main() async throws {
        let fairness = DirectoryScheduler(descriptorLimit: 8)
        for id in 0..<8 {
            await fairness.enqueue(DirectoryTask(id: UInt64(id), path: "/high/\(id)",
                parentID: 0, rootDevice: 1, priority: .high))
            await fairness.enqueue(DirectoryTask(id: UInt64(100 + id), path: "/normal/\(id)",
                parentID: 0, rootDevice: 1, priority: .normal))
        }

        var firstSix: [ScanPriority] = []
        for _ in 0..<6 {
            let task = await fairness.next()!
            firstSix.append(task.priority)
            await fairness.complete(task)
        }
        require(firstSix.contains(.normal), "normal work should appear within six dequeues")

        let bounded = DirectoryScheduler(descriptorLimit: 8)
        for id in 0..<200 {
            await bounded.enqueue(DirectoryTask(id: UInt64(id), path: "/synthetic/\(id)",
                parentID: 0, rootDevice: 1, priority: .normal))
        }
        await bounded.finish()
        let processed = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    while let task = await bounded.next() {
                        try? await Task.sleep(for: .milliseconds(1))
                        await processed.increment()
                        await bounded.complete(task)
                    }
                }
            }
        }
        let processedCount = await processed.value
        let peakLeaseCount = await bounded.peakOpenLeaseCount
        require(processedCount == 200, "all queued tasks should complete")
        require(peakLeaseCount == 8, "descriptor leases should peak at configured limit")

        let races = DirectoryScheduler(descriptorLimit: 2)
        let fm = FileManager.default
        let vanished = fm.temporaryDirectory.appendingPathComponent("roomy-vanished-\(UUID().uuidString)")
        try fm.createDirectory(at: vanished, withIntermediateDirectories: true)
        await races.enqueue(DirectoryTask(id: 1, path: vanished.path,
            parentID: 0, rootDevice: 1, priority: .high))
        await races.enqueue(DirectoryTask(id: 2, path: "/survives",
            parentID: 0, rootDevice: 1, priority: .normal))
        try fm.removeItem(at: vanished)
        let removedTask = await races.next()!
        do {
            let fd = try openDir(removedTask.path)
            close(fd)
            require(false, "deleted directory should not open")
        } catch {
            await races.complete(removedTask,
                diagnostic: DirectoryReader.diagnostic(for: error, path: removedTask.path))
        }
        let survivor = await races.next()
        require(survivor?.id == 2, "a disappearing task should not stop later work")
        if let survivor { await races.complete(survivor) }
        await races.finish()
        let diagnostics = await races.diagnostics
        require(diagnostics.contains(where: { $0.kind == .disappeared }),
            "disappearing directory should be recorded")

        var policy = WorkerPolicy()
        for _ in 0..<15 { _ = policy.sample(batchLatency: .milliseconds(50)) }
        require(policy.workerCount == 2, "slow metadata should clamp workers to two")
        for _ in 0..<25 { _ = policy.sample(batchLatency: .milliseconds(5)) }
        require(policy.workerCount == 6, "fast metadata should clamp workers to six")
        print("directory scheduler ok")
    }
}
