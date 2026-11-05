// SPDX-License-Identifier: GPL-3.0-only
// 每次实际清理成功都对应一次新的 post-cleanup 采样：即使上一次 cleanup walk 还在跑，
// 第二次 refresh(.cleanup) 也必须取消替换它，而不是 joined 复用旧采样。
import Foundation

@main
struct PostCleanupCaptureTests {
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Int] = [:]
        func bump(_ key: String) { lock.lock(); storage[key, default: 0] += 1; lock.unlock() }
        func add(_ key: String, _ delta: Int) { lock.lock(); storage[key, default: 0] += delta; lock.unlock() }
        func set(_ key: String, _ value: Int) { lock.lock(); storage[key] = value; lock.unlock() }
        func setMax(_ key: String, _ value: Int) {
            lock.lock(); storage[key] = max(storage[key] ?? 0, value); lock.unlock()
        }
        func get(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return storage[key] ?? 0 }
    }

    static func result(_ generation: UInt64, complete: Bool) -> CleanupOverviewResult {
        CleanupOverviewResult(generation: generation, dirs: [:], rootTotals: [:], unreadable: [], complete: complete)
    }

    static func waitFor(_ what: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(2_000)
        }
        preconditionFailure("timed out waiting for \(what)")
    }

    static func main() {
        // ① 第二次实际成功清理发生在第一份 cleanup walk 仍在跑时：
        //    必须 started、旧 shouldContinue=false、只交付最新一次、active 最大 1。
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.post-cleanup"))
            let box = Box()
            let entered = DispatchSemaphore(value: 0)
            let check = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var delivered: [CleanupOverviewResult] = []

            coordinator.prepare(generation: 21, event: .cleanup, walk: { shouldContinue in
                let attempt = box.get("walk")
                box.bump("walk")
                box.add("active", 1)
                box.setMax("maxActive", box.get("active"))
                defer { box.add("active", -1) }
                if attempt == 0 {
                    entered.signal()
                    check.wait()
                    box.set("oldStillCurrent", shouldContinue() ? 1 : 0)
                    release.wait()
                }
                return result(21, complete: true)
            }, deliver: { value in
                // 先落数组再抬计数：测试看到 deliver==1 时数组一定已写入。
                lock.lock(); delivered.append(value); lock.unlock()
                box.bump("deliver")
            })

            // 先悲观置 1：只有第一份 walk 真正观察到 shouldContinue=false 才会变 0。
            box.set("oldStillCurrent", 1)
            precondition(coordinator.request() == .started)
            entered.wait()
            precondition(coordinator.refresh(event: .cleanup) == .started,
                         "第二次 cleanup 必须替换仍在跑的第一份 cleanup 采样")
            check.signal()
            waitFor("old shouldContinue false") { box.get("oldStillCurrent") == 0 }
            release.signal()
            waitFor("latest cleanup delivered") { box.get("deliver") == 1 }

            precondition(box.get("walk") == 2, "release 后应实际跑第二次 walk")
            precondition(box.get("deliver") == 1, "只交付最新一次")
            precondition(box.get("maxActive") == 1, "串行队列不能并行两份 walk")
            lock.lock(); let values = delivered; lock.unlock()
            precondition(values.count == 1)
            precondition(values[0].event == .cleanup)
            precondition(!values[0].captureID.isEmpty, "新 walk 必须带自己的 captureID")
        }

        // ② 同一 running 采样期间重复 .scan 仍合并，不重复读盘。
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.scan-join"))
            let box = Box()
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)

            coordinator.prepare(generation: 22, event: .scan, walk: { _ in
                box.bump("walk")
                entered.signal()
                release.wait()
                return result(22, complete: true)
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            entered.wait()
            precondition(coordinator.refresh(event: .scan) == .joined)
            precondition(coordinator.refresh(event: .scan) == .joined)
            release.signal()
            waitFor("scan delivered") { box.get("deliver") == 1 }
            precondition(box.get("walk") == 1, "重复 scan 刷新不能重复执行")
            precondition(box.get("deliver") == 1)
        }

        print("post cleanup capture ok")
    }
}
