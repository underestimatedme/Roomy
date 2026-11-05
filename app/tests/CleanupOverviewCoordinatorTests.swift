// SPDX-License-Identifier: MPL-2.0
// 深度统计按需执行的并发行为：不请求就不走、两个入口共用一次、旧任务不污染新一代、
// 不完整的结果不交付、失败能重试。全部用注入的假 walk，不碰真实家目录、不启用后台服务。
import Foundation

@main
struct CleanupOverviewCoordinatorTests {
    /// 计数与记录都过锁：walk 在协调器自己的队列上跑，测试线程同时在读
    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Int] = [:]
        func bump(_ key: String) { lock.lock(); storage[key, default: 0] += 1; lock.unlock() }
        func add(_ key: String, _ delta: Int) { lock.lock(); storage[key, default: 0] += delta; lock.unlock() }
        func setMax(_ key: String, _ value: Int) {
            lock.lock(); storage[key] = max(storage[key] ?? 0, value); lock.unlock()
        }
        func get(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return storage[key] ?? 0 }
    }

    static func result(_ generation: UInt64, complete: Bool, dirs: [String: UInt64] = [:]) -> CleanupOverviewResult {
        CleanupOverviewResult(generation: generation, dirs: dirs, rootTotals: dirs, unreadable: [], complete: complete)
    }

    static func waitFor(_ what: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            usleep(2_000)
        }
        preconditionFailure("timed out waiting for \(what)")
    }

    static func main() throws {
        // ① 未请求：登记了范围也不遍历
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.idle"))
            let box = Box()
            coordinator.prepare(generation: 1, walk: { _ in box.bump("walk"); return result(1, complete: true) },
                                deliver: { _ in box.bump("deliver") })
            let status = coordinator.status()
            precondition(status.phase == .idle)
            precondition(status.runs == 0)
            precondition(box.get("walk") == 0, "登记计划不等于开始遍历")
        }

        // ② 两个入口（按文件夹看 / 更新空间分析）共用同一次遍历
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.share"))
            let box = Box()
            let release = DispatchSemaphore(value: 0)
            let entered = DispatchSemaphore(value: 0)
            coordinator.prepare(generation: 7, walk: { _ in
                box.bump("walk"); entered.signal(); release.wait()
                return result(7, complete: true, dirs: ["/Users/x/a": 1_024])
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            entered.wait()
            precondition(coordinator.request() == .joined, "进行中的请求必须复用，不重复遍历")
            release.signal()
            waitFor("ready and delivered") { coordinator.status().phase == .ready && box.get("deliver") == 1 }

            precondition(box.get("walk") == 1)
            precondition(box.get("deliver") == 1)
            precondition(coordinator.request() == .ready, "已有本次结果就直接用")
            precondition(box.get("walk") == 1, "复用结果不能再走一遍")
            precondition(coordinator.result()?.dirs["/Users/x/a"] == 1_024)
        }

        // ③ 旧任务结束时不碰新一代的状态：新代仍在排队，第二次请求 joined，真实新 walk 只有一次
        do {
            let queue = DispatchQueue(label: "test.generation")
            let coordinator = CleanupOverviewCoordinator(queue: queue)
            let box = Box()
            let entered1 = DispatchSemaphore(value: 0), release1 = DispatchSemaphore(value: 0)
            let blockerEntered = DispatchSemaphore(value: 0), blocker = DispatchSemaphore(value: 0)

            coordinator.prepare(generation: 1, walk: { _ in
                box.bump("walk1"); entered1.signal(); release1.wait()
                return result(1, complete: false)      // 被作废的旧任务
            }, deliver: { _ in box.bump("deliver1") })
            precondition(coordinator.request() == .started)
            entered1.wait()

            // 新一代登记并请求，队列中间再放一个阻塞块，让新任务停在"排队中"
            coordinator.prepare(generation: 2, walk: { _ in
                box.bump("walk2")
                return result(2, complete: true)
            }, deliver: { _ in box.bump("deliver2") })
            queue.async { blockerEntered.signal(); blocker.wait() }
            precondition(coordinator.request() == .started)

            release1.signal()                        // 旧任务现在才结束
            blockerEntered.wait()
            waitFor("new generation queued") { coordinator.status().phase == .queued }
            let queued = coordinator.status()
            precondition(queued.generation == 2, "旧任务结束后状态必须仍属于新一代")
            precondition(queued.runs == 0, "旧任务跑过几次不算到新一代头上")
            precondition(coordinator.request() == .joined, "排队中再请求必须复用，不能重复启动")

            blocker.signal()
            waitFor("new generation ready") {
                coordinator.status().phase == .ready && box.get("deliver2") == 1
            }
            precondition(box.get("walk2") == 1, "新一代只真正遍历一次")
            precondition(box.get("walk1") == 1)
            precondition(box.get("deliver1") == 0, "旧一代的结果不交付")
            precondition(box.get("deliver2") == 1)
            precondition(coordinator.status().runs == 1)
        }

        // ④ 没跑完的结果不交付；失败之后可以重试
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.retry"))
            let box = Box()
            coordinator.prepare(generation: 3, walk: { _ in
                let attempt = box.get("walk")
                box.bump("walk")
                return result(3, complete: attempt > 0)   // 第一次不完整，第二次完整
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            waitFor("failed") { coordinator.status().phase == .failed }
            precondition(box.get("deliver") == 0, "部分结果不能写历史/缓存")
            precondition(coordinator.result() == nil)

            precondition(coordinator.request() == .started, "失败后重试要重开一次遍历")
            waitFor("ready after retry") { coordinator.status().phase == .ready && box.get("deliver") == 1 }
            precondition(box.get("walk") == 2)
            precondition(box.get("deliver") == 1, "只有完整结果交付一次")
        }

        // ⑤ 取消：walk 观察到 shouldContinue 变 false 尽快停，结果作废、不交付
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.cancel"))
            let box = Box()
            let entered = DispatchSemaphore(value: 0)
            coordinator.prepare(generation: 4, walk: { shouldContinue in
                entered.signal()
                var spins = 0
                while shouldContinue() && spins < 200_000 {
                    spins += 1
                    usleep(200)
                }
                box.bump("stopped")
                return result(4, complete: shouldContinue())
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            entered.wait()
            coordinator.invalidate()
            waitFor("walk stopped") { box.get("stopped") == 1 }
            waitFor("expired") { coordinator.status().phase == .expired }
            precondition(box.get("deliver") == 0, "取消后的结果不能当完整报告写出去")
            precondition(coordinator.result() == nil)
            precondition(coordinator.request() == .noScan, "作废之后没有可统计的扫描，必须先扫描")
        }

        // ⑥ ready 后显式刷新必须重新走一遍，而不是复用旧结果；每次采样 ID 唯一、事件正确
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.refresh"))
            let box = Box()
            let lock = NSLock()
            var delivered: [CleanupOverviewResult] = []
            coordinator.prepare(generation: 10, walk: { _ in
                box.bump("walk")
                return result(10, complete: true, dirs: ["/Users/x/a": UInt64(box.get("walk"))])
            }, deliver: { value in
                box.bump("deliver")
                lock.lock(); delivered.append(value); lock.unlock()
            })

            precondition(coordinator.request() == .started)
            waitFor("first ready") {
                coordinator.status().phase == .ready && box.get("deliver") == 1
            }
            guard let first = coordinator.result() else { preconditionFailure("first result missing") }
            precondition(first.event == .scan)
            precondition(!first.captureID.isEmpty)

            precondition(coordinator.refresh(event: .scan) == .started, "ready 后刷新必须重新 walk")
            waitFor("second ready") {
                coordinator.status().phase == .ready && box.get("walk") == 2 && box.get("deliver") == 2
            }
            guard let second = coordinator.result() else { preconditionFailure("second result missing") }
            precondition(second.event == .scan)
            precondition(second.captureID != first.captureID, "每次实际采样必须有唯一 captureID")
            precondition(box.get("deliver") == 2)
            precondition(coordinator.status().runs == 2, "同代刷新累计两次真实遍历")
            precondition(coordinator.request() == .ready, "刷新完成后普通 request 仍复用结果")
            precondition(box.get("walk") == 2, "普通 request 不能再启动一次")

            lock.lock(); let values = delivered; lock.unlock()
            precondition(values.count == 2 && values[0].captureID != values[1].captureID)
        }

        // ⑦ 扫描刷新遇到进行中的任务必须合并，不重复读盘
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.refresh.join"))
            let box = Box()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            coordinator.prepare(generation: 11, walk: { _ in
                box.bump("walk"); entered.signal(); release.wait()
                return result(11, complete: true)
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            entered.wait()
            precondition(coordinator.refresh(event: .scan) == .joined, "进行中的扫描刷新必须合并")
            release.signal()
            waitFor("joined ready") { coordinator.status().phase == .ready && box.get("deliver") == 1 }
            precondition(box.get("walk") == 1)
            precondition(box.get("deliver") == 1)
        }

        // ⑧ cleanup 刷新替换 pre-clean 采样：旧结果不交付，新结果标 cleanup；串行 active <= 1
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.cleanup.supersede"))
            let box = Box()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var delivered: [CleanupOverviewResult] = []
            coordinator.prepare(generation: 12, walk: { _ in
                let attempt = box.get("walk")
                box.bump("walk")
                box.add("active", 1)
                box.setMax("maxActive", box.get("active"))
                defer { box.add("active", -1) }
                if attempt == 0 {
                    entered.signal()
                    release.wait()
                }
                return result(12, complete: true, dirs: ["/Users/x/a": UInt64(attempt + 1)])
            }, deliver: { value in
                box.bump("deliver")
                lock.lock(); delivered.append(value); lock.unlock()
            })

            precondition(coordinator.request() == .started)
            entered.wait()
            precondition(coordinator.refresh(event: .cleanup) == .started, "cleanup 必须替换 pre-clean 采样")
            release.signal()
            waitFor("cleanup delivered") { box.get("deliver") == 1 }
            precondition(box.get("walk") == 2)
            precondition(box.get("maxActive") == 1, "串行队列不能同时跑两个 walk")

            lock.lock(); let values = delivered; lock.unlock()
            precondition(values.count == 1)
            precondition(values[0].event == .cleanup, "pre-clean 结果不能标成 cleanup")
            precondition(!values[0].captureID.isEmpty)
        }

        // ⑨ 取消后没有当前扫描代：refresh 也只能 noScan，不能偷偷扫 HOME
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.refresh.closed"))
            let box = Box()
            let entered = DispatchSemaphore(value: 0)
            coordinator.prepare(generation: 13, walk: { shouldContinue in
                box.bump("walk"); entered.signal()
                var spins = 0
                while shouldContinue() && spins < 200_000 {
                    spins += 1
                    usleep(200)
                }
                box.bump("stopped")
                return result(13, complete: shouldContinue())
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            entered.wait()
            coordinator.invalidate()
            waitFor("old walk stopped") { box.get("stopped") == 1 }
            waitFor("expired") { coordinator.status().phase == .expired }
            precondition(coordinator.refresh(event: .scan) == .noScan)
            precondition(coordinator.refresh(event: .cleanup) == .noScan)
            precondition(box.get("walk") == 1)
            precondition(box.get("deliver") == 0)
            precondition(coordinator.result() == nil)
        }

        // ⑩ cleanup 刷新拿到部分结果：不存、不交付，保留扫描基线；之后还能重新刷新
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.cleanup.partial"))
            let box = Box()
            coordinator.prepare(generation: 14, walk: { _ in
                let attempt = box.get("walk")
                box.bump("walk")
                return result(14, complete: attempt != 1)   // 第一次 scan 完整，第二次 cleanup 不完整
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            waitFor("scan ready") { coordinator.status().phase == .ready }
            precondition(box.get("deliver") == 1)
            precondition(coordinator.refresh(event: .cleanup) == .started)
            waitFor("cleanup failed") { coordinator.status().phase == .failed }
            precondition(coordinator.result() == nil, "部分 cleanup 结果不能存成基线")
            precondition(box.get("deliver") == 1, "失败的 cleanup 不能交付")

            precondition(coordinator.refresh(event: .scan) == .started)
            waitFor("scan retry ready") { coordinator.status().phase == .ready }
            precondition(box.get("deliver") == 2)
        }

        // ⑪ cleanup 从 ready 开始时也换新 ID/event，不复用 scan 的 capture
        do {
            let coordinator = CleanupOverviewCoordinator(queue: DispatchQueue(label: "test.cleanup.id"))
            let box = Box()
            coordinator.prepare(generation: 15, walk: { _ in
                box.bump("walk")
                return result(15, complete: true)
            }, deliver: { _ in box.bump("deliver") })

            precondition(coordinator.request() == .started)
            waitFor("scan ready") { coordinator.status().phase == .ready }
            guard let scan = coordinator.result() else { preconditionFailure("scan result missing") }
            precondition(scan.event == .scan)

            precondition(coordinator.refresh(event: .cleanup) == .started)
            waitFor("cleanup ready") { coordinator.status().phase == .ready && box.get("walk") == 2 }
            guard let cleanup = coordinator.result() else { preconditionFailure("cleanup result missing") }
            precondition(cleanup.event == .cleanup)
            precondition(cleanup.captureID != scan.captureID, "cleanup 不能复用 scan 的 captureID")
            precondition(box.get("deliver") == 2)
        }

        print("cleanup overview coordinator ok")
    }
}
