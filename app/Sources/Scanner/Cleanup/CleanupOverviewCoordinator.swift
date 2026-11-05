// SPDX-License-Identifier: GPL-3.0-only
// 深度目录统计按需执行：清单发出去之后不再无条件把整个家目录和系统区域走一遍。
// 只有两个入口会请求一次 ——「按文件夹看」和「更新空间分析」；同一代扫描里两个入口共用同一个任务，
// 结果给 folders / overview / growth 三处使用，不重复深度 walk。
//
// 一次扫描 = 一代 generation。登记范围（prepare）只留在内存里，不把可执行授权写到磁盘；
// 新扫描开始或取消（invalidate）让旧一代立刻失效，正在跑的遍历尽快停、排队里的一代在启动前就跳过。
// 取消和没跑完的结果不交付：不写空间变化历史，也不写首屏缓存。

import Foundation

/// 一次深度统计的结果。complete = 这次遍历跑到了结尾（不是取消/提前中断）。
/// captureID/event 由协调器在真实 walk 结束时写入：每次实际采样唯一，交付时随结果一起走。
struct CleanupOverviewResult: Sendable {
    let generation: UInt64
    let dirs: [String: UInt64]
    let rootTotals: [String: UInt64]
    let unreadable: [String]
    let complete: Bool
    var captureID: String = ""
    var event: SpaceGrowthEvent = .scan
    var capturedAt: Date = Date()
}

/// 这一代深度统计处在哪一步
enum CleanupOverviewPhase: String, Sendable {
    case idle      // 登记了范围，还没有人请求
    case queued    // 已请求，排在串行队列里等前一个任务
    case running   // 正在遍历
    case ready     // 本次结果可用
    case failed    // 没跑完，可以重试
    case expired   // 这一代已作废（新扫描 / 取消），结果不再使用
}

/// 请求一次的结果
enum CleanupOverviewOutcome: String, Sendable {
    case started   // 新开了一次遍历
    case joined    // 复用正在跑或排队的那一次
    case ready     // 已经有本次结果，直接用
    case noScan    // 没有新鲜的扫描：先完成清理扫描，不静默扫家目录
}

/// 给页面看的状态快照
struct CleanupOverviewStatus: Sendable {
    let phase: CleanupOverviewPhase
    let generation: UInt64
    let startedAt: Date?
    let finishedAt: Date?
    let message: String?
    /// 这一代是否已经有完整结果
    let complete: Bool
    /// 本次扫描里真正启动过几次遍历（诊断与测试用；未请求时为 0）
    let runs: Int
}

final class CleanupOverviewCoordinator: @unchecked Sendable {
    /// 真正做遍历：shouldContinue 为 false 时尽快返回，结果标成不完整
    typealias Walk = (_ shouldContinue: @escaping () -> Bool) -> CleanupOverviewResult
    /// 只有完整、且这一代仍然有效的结果才会交过来（写历史、写缓存、推事件）
    typealias Deliver = (CleanupOverviewResult) -> Void

    private final class Job {
        let generation: UInt64
        /// 每次实际采样一个唯一 ID；刷新会新建 Job，不复用旧 ID/结果
        let captureID = UUID().uuidString
        let event: SpaceGrowthEvent
        let walk: Walk
        let deliver: Deliver
        var cancelled = false
        init(generation: UInt64, event: SpaceGrowthEvent, walk: @escaping Walk, deliver: @escaping Deliver) {
            self.generation = generation; self.event = event; self.walk = walk; self.deliver = deliver
        }
    }

    private let lock = NSLock()
    /// 串行队列：同一时间只有一个深度遍历在跑，过时的任务在启动前就跳过，不和新任务争 IO
    private let queue: DispatchQueue
    private var job: Job?
    private var phase: CleanupOverviewPhase = .idle
    private var startedAt: Date?
    private var finishedAt: Date?
    private var message: String?
    private var stored: CleanupOverviewResult?
    private var runs = 0
    private var observer: ((CleanupOverviewStatus) -> Void)?

    init(queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(label: "app.roomy.overview", qos: .utility)
    }

    /// 每次阶段变化时回调一次（页面据此刷新状态，不必轮询）。在锁外调用。
    func observe(_ handler: @escaping (CleanupOverviewStatus) -> Void) {
        lock.lock(); observer = handler; lock.unlock()
    }

    private func publish() {
        lock.lock()
        let status = CleanupOverviewStatus(phase: phase, generation: job?.generation ?? 0, startedAt: startedAt,
                                           finishedAt: finishedAt, message: message, complete: stored != nil, runs: runs)
        let handler = observer
        lock.unlock()
        handler?(status)
    }

    /// 一次扫描结束、清单已经能用时登记这一代要统计的范围。只登记，不开始。
    /// 旧一代立刻失效：它的结果已经没有用处。event 默认 .scan，清理后重新测量时用 refresh(event: .cleanup)。
    func prepare(generation: UInt64, event: SpaceGrowthEvent = .scan,
                 walk: @escaping Walk, deliver: @escaping Deliver) {
        lock.lock()
        job?.cancelled = true
        job = Job(generation: generation, event: event, walk: walk, deliver: deliver)
        phase = .idle
        startedAt = nil; finishedAt = nil; message = nil; stored = nil
        runs = 0                     // 次数按代统计：旧一代跑过几次不算到新一代头上
        lock.unlock()
        publish()
    }

    /// 这一代作废（新扫描开始、用户取消）：正在跑的尽快停，结果不再交付，也不写历史/缓存
    func invalidate() {
        lock.lock()
        job?.cancelled = true
        job = nil
        phase = .expired
        startedAt = nil; finishedAt = nil
        message = "这一代扫描已作废，本次统计结果不采用"
        stored = nil
        lock.unlock()
        publish()
    }

    /// 请求一次。进行中/排队中复用，已有结果直接给，没有新鲜扫描就明说。
    @discardableResult
    func request() -> CleanupOverviewOutcome {
        lock.lock()
        guard let current = job else { lock.unlock(); return .noScan }
        switch phase {
        case .ready where stored != nil:
            lock.unlock(); return .ready
        case .running, .queued:
            lock.unlock(); return .joined
        default:
            break
        }
        // idle / failed / expired 都从这里重开一次（失败可以重试）。
        // 失败后的重试也是一次新的真实采样：换新 Job（新 captureID），不复用失败那次的标识。
        let mine: Job
        if phase == .failed {
            current.cancelled = true
            mine = Job(generation: current.generation, event: current.event,
                       walk: current.walk, deliver: current.deliver)
            job = mine
        } else {
            mine = current
        }
        phase = .queued
        startedAt = nil; finishedAt = nil; message = nil; stored = nil
        lock.unlock()
        publish()
        queue.async { [self] in run(mine) }
        return .started
    }

    /// 显式刷新：ready 时也真的重新 walk，不返回旧结果。
    /// · .scan：同一采样仍在 queued/running 时合并，避免重复读盘；否则新开一次采样。
    /// · .cleanup：每一次调用都代表一次不同且已成功的文件操作，必须取消并替换任何仍在
    ///   queued/running 的采样（即使当前也是 .cleanup），在同一串行队列里排一次真正清理后
    ///   的 fresh walk；每次新 Job 都有自己的 captureID，绝不把前一次清理前的数据当后基线。
    /// 没有登记过的扫描代时返回 noScan，绝不静默扫描 HOME。
    @discardableResult
    func refresh(event: SpaceGrowthEvent) -> CleanupOverviewOutcome {
        lock.lock()
        guard let current = job else { lock.unlock(); return .noScan }
        if event == .scan && (phase == .running || phase == .queued) {
            lock.unlock()
            return .joined
        }
        // 新 Job 沿用这一代的 walk/deliver 闭包，但换新的 captureID/event，不复用旧结果。
        current.cancelled = true
        let next = Job(generation: current.generation, event: event,
                       walk: current.walk, deliver: current.deliver)
        job = next
        phase = .queued
        startedAt = nil; finishedAt = nil; message = nil; stored = nil
        // runs 按这一代累计：刷新/重试都是同一代里真实启动过的遍历，不清零
        lock.unlock()
        publish()
        queue.async { [self] in run(next) }
        return .started
    }

    /// 当前这一代的状态。没有登记（还没扫描/已作废）时 phase 为 expired，generation 为 0。
    func status() -> CleanupOverviewStatus {
        lock.lock(); defer { lock.unlock() }
        return CleanupOverviewStatus(phase: phase, generation: job?.generation ?? 0, startedAt: startedAt,
                                     finishedAt: finishedAt, message: message, complete: stored != nil, runs: runs)
    }

    /// 只有 ready 的这一次结果
    func result() -> CleanupOverviewResult? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    /// 这份 capture 是否仍是当前采样：refresh/取消/换代之后，旧 Job 晚到的结果不再写外部状态。
    func isCurrent(captureID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let job else { return false }
        return !job.cancelled && job.captureID == captureID
    }

    private func run(_ mine: Job) {
        lock.lock()
        // 排队期间这一代被换掉或取消：启动前直接跳过，不占 IO
        guard self.job === mine, !mine.cancelled else {
            if self.job === mine {
                phase = .expired
                message = "这一代扫描已作废，本次统计结果不采用"
                lock.unlock()
                publish()
                return
            }
            lock.unlock()
            return
        }
        phase = .running
        startedAt = Date()
        runs += 1
        lock.unlock()
        publish()

        var value = mine.walk { [weak self] in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return !mine.cancelled && self.job === mine
        }
        // 采样真正结束的时间，不用 walk 开始前的时间，也不等交付时再取。
        let endedAt = Date()
        value.captureID = mine.captureID
        value.event = mine.event
        value.capturedAt = endedAt

        lock.lock()
        // 旧任务结束时新的一代可能已经登记/排队/在跑：旧任务不得改动新任务的任何状态，
        // 否则会把新任务的 queued 覆盖成 expired，下一次请求就会重复启动一次遍历
        guard self.job === mine else { lock.unlock(); return }
        guard !mine.cancelled else {
            phase = .expired
            finishedAt = endedAt
            message = "这一代扫描已作废，本次统计结果不采用"
            lock.unlock()
            publish()
            return
        }
        finishedAt = endedAt
        if value.complete {
            stored = value
            phase = .ready
            message = nil
        } else {
            stored = nil
            phase = .failed
            message = "统计没有跑完，可以重试"
        }
        lock.unlock()
        publish()

        // 取消或部分结果不交付：不写空间变化历史、不写首屏缓存
        guard value.complete else { return }
        // publish 之后可能已经有 refresh 取消/替换了这次采样；交付前再确认一次，
        // 外部写入（folders/缓存/历史）也各自带 capture 当前性检查。
        lock.lock()
        let stillCurrent = self.job === mine && !mine.cancelled
        lock.unlock()
        guard stillCurrent else { return }
        mine.deliver(value)
    }
}
