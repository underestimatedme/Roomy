// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct AutomationEnvironment {
    /// Only the independent CLI host opts in; the GUI host and legacy rules remain unchanged.
    var allowsCLICleanup = false
    var sharedStateDirectory: URL?
    var recordScheduledOutcome: (AutomationItem, CleanupOutcome) throws -> Void = { _, _ in }
    var volume: () -> AutomationVolume? = { AutomationDiscovery.volume() }
    var discover: (AutomationRule) throws -> [CleanupCandidate] = { try AutomationDiscovery.discover(rule: $0) }
    /// Read-only scheduled scan. It returns a display-only summary and never a cleanup authorization.
    var scan: (URL) throws -> AutomationScanSummary = { try AutomationDiscovery.scan(directory: $0) }
    // Host must install its entitlement check. A bare core worker never gains execution authority.
    var access: () throws -> Void = { throw automationError("后台执行权限尚未配置") }
    var notify: (AutomationRun) -> Bool = { _ in false }
    var cleanup = CleanupEnvironment()
    var perform: (AutomationItem, CleanupEnvironment) -> CleanupOutcome = { snapshot, env in
        let candidate = snapshot.candidate
        return CleanupRunner.run(ids: [candidate.entry.id], list: CleanupList(candidates: [candidate]), env: env, progress: { _ in }).outcomes[0]
    }
}

final class AutomationWorker {
    let store: AutomationStore
    var environment: AutomationEnvironment
    init(store: AutomationStore, environment: AutomationEnvironment) { self.store = store; self.environment = environment }
    private var sharedState: URL { environment.sharedStateDirectory ?? store.directory }
    private func serialized<T>(_ body: () throws -> T) throws -> T {
        _ = try store.read()
        let lease = try OperationLease.acquire(path: store.directory.appendingPathComponent("automation-worker.lock").path)
        return try withExtendedLifetime(lease, body)
    }
    func tick(now: Date = Date()) throws {
        try serialized {
            try store.update { db in
                // Exclusive worker lock proves these are left by a terminated worker, not a live run.
                for index in db.runs.indices where db.runs[index].status == .running || (db.runs[index].intentID != nil && db.runs[index].acknowledgedAt == nil) {
                    let id = db.runs[index].ruleID
                    db.runs[index].status = .needsAttention
                    db.runs[index].message = "上次执行中断，结果可能不确定；请核对废纸篓与记录后恢复规则"
                    db.runtimes[id]?.blocker = db.runs[index].message
                    db.runtimes[id]?.activeRunID = nil
                }
                db.runs.removeAll { $0.status.terminal && $0.status != .needsAttention && $0.intentID == nil && now.timeIntervalSince($0.updatedAt) > 90*86400 }
            }
            let initial = try store.read()
            guard !initial.paused else { return }
            for original in initial.rules where original.enabled {
                var claimed: String?
                try store.update { db in
                    guard !db.paused, let index = db.rules.firstIndex(where: { $0.id == original.id }), db.rules[index].enabled else { return }
                    var rule = db.rules[index]
                    var runtime = db.runtimes[rule.id] ?? AutomationRuntime(nextDue: rule.days.map { rule.updatedAt.addingTimeInterval(Double($0)*86400) })
                    if let active = runtime.activeRunID, db.runs.contains(where: { $0.id == active && $0.status == .scanning }) {
                        guard runtime.retryAt.map({ now >= $0 }) ?? true else { return }
                        runtime.retryAt = nil
                        claimed = active
                    } else {
                        let volume = environment.volume()
                        let reasons = AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now)
                        if !reasons.isEmpty {
                            // Every trigger is claimed as a scan first; only a passed permission check may turn it
                            // into a capacity reminder or a cleanup plan.
                            var run = AutomationRun(ruleID: rule.id, revision: rule.revision, title: rule.title, createdAt: now, updatedAt: now, reasons: reasons)
                            run.status = .scanning
                            // A scheduled scan is claimed as read-only from the first moment.
                            if rule.isScanRule { run.scanOnly = true }
                            db.runs.append(run); runtime.activeRunID = run.id; claimed = run.id
                        }
                    }
                    db.rules[index] = rule
                    db.runtimes[rule.id] = runtime
                }
                if let claimed {
                    let queuedDB = try store.read()
                    guard let queued = queuedDB.runs.first(where: { $0.id == claimed }),
                          let queuedRule = queuedDB.rules.first(where: { $0.id == queued.ruleID }) else { continue }
                    do {
                        if queued.isScanOnly == true || queuedRule.isScanRule {
                            // The permission boundary is checked first; a scheduled scan only reads and summarizes.
                            try environment.access()
                            try scan(runID: claimed, now: now)
                        } else if queued.reasons.contains("space") {
                            // Capacity keeps priority over every legacy mode: it only records a reminder.
                            try environment.access()
                            try remind(runID: claimed, now: now)
                        } else if queuedRule.task == .cliCleanup && environment.allowsCLICleanup {
                            try environment.access()
                            try prepare(runID: claimed, now: now)
                            if let plan = try store.read().runs.first(where: { $0.id == claimed }), plan.status == .awaitingConfirmation {
                                try execute(runID: claimed, token: plan.token, ids: plan.items.map(\.id), now: now, automatic: true)
                            }
                        } else if queuedRule.mode == .automatic {
                            // Old automatic rules keep their data but never prepare or perform again.
                            try blockLegacyAutomatic(runID: claimed, now: now)
                        } else {
                            try environment.access()
                            try prepare(runID: claimed, now: now)
                        }
                    } catch {
                        let error = error as NSError
                        if error.domain == "RoomyOperation" && error.code == 2 {
                            try store.update { db in
                                guard let i = db.runs.firstIndex(where: { $0.id == claimed }), db.runs[i].status == .awaitingConfirmation else { return }
                                db.runs[i].status = .scanning; db.runs[i].message = "其他操作正在执行，下次后台检查重试"
                                db.runtimes[db.runs[i].ruleID]?.retryAt = now.addingTimeInterval(900)
                            }
                        } else { try fail(runID: claimed, message: error.localizedDescription, now: now, permanent: !automationIsTransient(error)) }
                    }
                }
            }
            try deliverNotifications()
        }
    }
    func refresh(runID: String, now: Date = Date()) throws {
        try serialized {
            let run = try store.read().runs.first(where: { $0.id == runID })
            guard run?.isScanOnly != true else { throw automationError("定时扫描只读，没有可刷新的清理清单") }
            try environment.access(); try prepare(runID: runID, now: now)
        }
    }
    func approve(runID: String, token: String, ids: [String], now: Date = Date()) throws {
        try serialized {
            let run = try store.read().runs.first(where: { $0.id == runID })
            guard run?.isScanOnly != true else { throw automationError("定时扫描只读，不能确认清理") }
            do { try execute(runID: runID, token: token, ids: ids, now: now, automatic: false) }
            catch {
                if try store.read().runs.contains(where: { $0.id == runID && $0.status == .running }) {
                    try fail(runID: runID, message: error.localizedDescription, now: now)
                }
                throw error
            }
        }
    }
    func skip(runID: String, now: Date = Date()) throws {
        try store.update { db in
            guard let index = db.runs.firstIndex(where: { $0.id == runID }), !db.runs[index].status.terminal else { return }
            db.runs[index].status = db.runs[index].intentID == nil ? .skipped : .needsAttention
            db.runs[index].message = db.runs[index].intentID == nil ? "用户跳过本轮" : "已停止后续项目；当前操作结果待核对"
            db.runs[index].updatedAt = now
            Self.finish(database: &db, runID: runID, now: now)
        }
    }
    func acknowledge(runID: String, now: Date = Date()) throws {
        try serialized {
            try store.update { db in
                guard let index = db.runs.firstIndex(where: { $0.id == runID }), db.runs[index].status == .needsAttention,
                      db.runs[index].intentID != nil else { throw automationError("没有需要核对的不确定操作") }
                db.runs[index].acknowledgedAt = now
                db.runs[index].message += "；用户已人工核对，可按需恢复规则"
            }
        }
    }
    private func context(_ db: AutomationDatabase, runID: String) throws -> (AutomationRule, AutomationRun) {
        guard !db.paused, let run = db.runs.first(where: { $0.id == runID }), !run.status.terminal,
              let rule = db.rules.first(where: { $0.id == run.ruleID }), rule.enabled, rule.revision == run.revision,
              db.runtimes[rule.id]?.blocker == nil, db.runtimes[rule.id]?.activeRunID == runID else {
            throw automationError("规则已暂停、修改或任务已结束，请刷新")
        }
        return (rule, run)
    }
    /// A capacity trigger only records a reminder: no discover, no prepare, no deletion, no cleanup plan.
    private func remind(runID: String, now: Date) throws {
        // access() may wait on a permission prompt for a long time. Re-read the volume afterwards and check the
        // actual metric again: a disk that recovered meanwhile must not receive the old low-capacity text.
        let volume = environment.volume()
        var failure: String?
        try store.update { db in
            // The permission check runs outside this update, so the user may have paused the worker, disabled or
            // edited the rule meanwhile. Apply the same context gate as prepare/execute before touching anything.
            guard let (rule, run) = try? context(db, runID: runID) else { return }
            // A run that already carries an intent or results is not a clean scan; leave it visible for review
            // instead of rewriting it into a completed reminder.
            guard run.status == .scanning, run.intentID == nil, run.outcomes.isEmpty,
                  let index = db.runs.firstIndex(where: { $0.id == runID }) else { return }
            // From here this is a clean capacity round: mark it as a reminder before any failure branch, so a
            // failed/unknown volume is recorded in-app and never sent as a "low space" system notification.
            // Older runs with an intent or outcomes returned above and keep their generic attention semantics.
            db.runs[index].reminderOnly = true
            // An unreadable volume or a different volume is unknown, never 0 GB: fail closed with the existing policy.
            guard let current = volume, current.id == rule.volumeID, current.total > 0, current.available <= current.total else {
                failure = volume == nil
                    ? "无法读取当前磁盘容量，本轮不发送提醒；请检查后恢复规则"
                    : "磁盘身份或容量读数已变化，本轮不发送提醒；请检查后恢复规则"
                return
            }
            guard let low = AutomationPolicy.belowThreshold(rule: rule, volume: current) else {
                failure = "容量提醒阈值无效，本轮不发送提醒；请检查规则"
                return
            }
            if low {
                db.runs[index].status = .completed
                db.runs[index].message = AutomationPolicy.reminderMessage(rule: rule, volume: current)
            } else {
                // Recovered while waiting for access: record the round as skipped, never notify. The time condition
                // of an old OR rule is not silently turned into a scan or cleanup here.
                db.runs[index].status = .skipped
                db.runs[index].message = AutomationPolicy.recoveredMessage(rule: rule, volume: current)
            }
            db.runs[index].updatedAt = now
            db.runs[index].notified = false
            Self.finish(database: &db, runID: runID, now: now)
        }
        if let failure { try fail(runID: runID, message: failure, now: now, permanent: true) }
    }
    /// A scheduled scan is read-only. It publishes a display-only summary, never an item, token or deletion.
    private func scan(runID: String, now: Date) throws {
        let initial = try store.read()
        // access() may wait; a rule paused or edited meanwhile must not start scanning.
        guard let (rule, _) = try? context(initial, runID: runID), rule.isScanRule else { return }
        guard validVolume(for: rule) else {
            throw automationError("磁盘不可读取或身份变化，本轮未扫描；请检查后恢复规则")
        }
        let summary = try environment.scan(store.directory)
        try summary.validate()
        // The scan can take a while. Re-read the rule and the volume before publishing anything.
        guard (try? context(store.read(), runID: runID)) != nil else { return }
        guard validVolume(for: rule) else {
            throw automationError("磁盘身份或容量读数已变化，本轮扫描未完成；请检查后恢复规则")
        }
        try store.update { db in
            guard let (_, run) = try? context(db, runID: runID), run.status == .scanning,
                  run.intentID == nil, run.items.isEmpty, run.outcomes.isEmpty, run.freedBytes == 0,
                  let index = db.runs.firstIndex(where: { $0.id == runID }) else { return }
            db.runs[index].scanSummary = summary
            db.runs[index].status = .completed
            db.runs[index].message = Self.scanMessage(summary)
            db.runs[index].updatedAt = now
            db.runs[index].notified = false
            db.runs[index].freedBytes = 0
            Self.finish(database: &db, runID: runID, now: now)
        }
    }
    private func validVolume(for rule: AutomationRule) -> Bool {
        guard let volume = environment.volume(), volume.id == rule.volumeID,
              volume.total > 0, volume.available <= volume.total else { return false }
        return true
    }
    private static func scanMessage(_ summary: AutomationScanSummary) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(clamping: summary.estimatedBytes), countStyle: .file)
        guard summary.itemCount > 0 else { return "定时扫描完成：未发现可清理项；没有删除任何文件。" }
        return "定时扫描完成：发现 \(summary.itemCount) 项，可处理 \(summary.actionableCount) 项，估算 \(bytes)；没有删除任何文件，请打开应用自行选择。"
    }
    /// Legacy automatic rules stay visible with their history, but a timed trigger no longer prepares or performs.
    private func blockLegacyAutomatic(runID: String, now: Date) throws {
        try store.update { db in
            guard let index = db.runs.firstIndex(where: { $0.id == runID }), !db.runs[index].status.terminal else { return }
            db.runs[index].status = .needsAttention
            db.runs[index].message = "旧自动清理已暂停，请新建定时扫描规则"
            db.runs[index].updatedAt = now
            db.runs[index].notified = false
            let id = db.runs[index].ruleID
            var runtime = db.runtimes[id] ?? AutomationRuntime()
            AutomationPolicy.fail(runtime: &runtime, message: db.runs[index].message, now: now, permanent: true)
            db.runtimes[id] = runtime
        }
    }
    private func prepare(runID: String, now: Date) throws {
        let (rule, _) = try context(store.read(), runID: runID)
        let started = Date()
        let candidates = try environment.discover(rule)
        let protection = CleanupProtectionStore(url: sharedState.appendingPathComponent("protected-cleanup.json"))
        let list = try protection.apply(to: CleanupList(candidates: candidates))
        var items: [AutomationItem] = []
        for scope in rule.scopes {
            guard Date().timeIntervalSince(started) <= 300 else { throw automationError("范围扫描超时，未授权任何清理", transient: true) }
            guard let candidate = list.candidates.first(where: { $0.entry.path == scope.path }), candidate.entry.selectable else { continue }
            // A partial inventory is never a deletion authorization.
            items.append(try AutomationItem.capture(candidate, scope: scope))
        }
        try store.update { db in
            let (_, run) = try context(db, runID: runID)
            guard run.status != .running, let index = db.runs.firstIndex(where: { $0.id == runID }) else { throw automationError("任务正在执行") }
            db.runs[index].items = items; db.runs[index].token = UUID().uuidString; db.runs[index].updatedAt = now
            db.runs[index].status = items.isEmpty ? .skipped : .awaitingConfirmation
            db.runs[index].message = items.isEmpty ? "没有符合授权范围且检查通过的缓存；可能正在使用、受保护或证据不足" : "等待确认；仅移入废纸篓"
            if items.isEmpty { Self.finish(database: &db, runID: runID, now: now) }
        }
    }
    private func execute(runID: String, token: String, ids: [String], now: Date, automatic: Bool) throws {
        try environment.access()
        let lease = try OperationLease.acquire(path: sharedState.appendingPathComponent("operation.lock").path)
        try withExtendedLifetime(lease) {
            let (rule, run) = try context(store.read(), runID: runID)
            guard !run.isScanOnly else { throw automationError("定时扫描只读，不能执行清理") }
            // Reminders are records, not work items. Legacy space/OR retries must not gain execution here either.
            guard !run.isReminder else { throw automationError("该记录只是容量提醒，没有可执行的清理项") }
            // Old automatic rules are stopped independently of the tick branch.
            guard !automatic || (environment.allowsCLICleanup && rule.task == .cliCleanup && rule.mode == .automatic && run.reasons == ["time"]) else {
                throw automationError("此任务未授权命令行定时清理")
            }
            guard run.status == .awaitingConfirmation, run.token == token, now >= run.updatedAt,
                  now.timeIntervalSince(run.updatedAt) <= 86400, !ids.isEmpty, Set(ids).count == ids.count,
                  !automatic || rule.mode == .automatic else { throw automationError("确认已过期或无效，请刷新清单并重新确认") }
            let selected = run.items.filter { ids.contains($0.id) }
            guard selected.count == ids.count, selected.allSatisfy({ rule.scopes.contains($0.scope) && $0.item.path == $0.scope.path && $0.unchanged() }) else {
                throw automationError("文件或范围已经变化，请刷新清单并重新确认")
            }
            // Fresh classification must still recognize every target; cached JSON never establishes ownership.
            let live = try environment.discover(rule)
            for item in selected {
                guard let candidate = live.first(where: { $0.entry.path == item.item.path }),
                      let current = try? AutomationItem.capture(candidate, scope: item.scope), current.fingerprint == item.fingerprint,
                      current.parents == item.parents else { throw automationError("当前缓存归属、内容或运行状态已变化，请刷新") }
            }
            let ledger = TrashLedger(url: sharedState.appendingPathComponent("pending-trash.json"))
            try ledger.validateForRecording()
            let protection = CleanupProtectionStore(url: sharedState.appendingPathComponent("protected-cleanup.json"))
            _ = try protection.all()
            let before = environment.volume()?.available
            try store.update { db in
                _ = try context(db, runID: runID)
                let i = db.runs.firstIndex { $0.id == runID }!
                db.runs[i].status = .running; db.runs[i].message = "正在检查并移入废纸篓"
            }
            for item in selected {
                // Cancellation/edit is reread between every filesystem action.
                let fresh = try store.read()
                guard let (_, current) = try? context(fresh, runID: runID), current.status == .running else { break }
                try environment.access()
                guard validVolume(for: rule) else { throw automationError("执行前磁盘身份或容量读数已变化，已停止") }
                guard item.unchanged() else {
                    try append(.init(id: item.id, ok: false, message: "扫描后内容变化，已跳过", bytes: 0), runID: runID); continue
                }
                guard try !protection.blocks(path: item.item.path) else {
                    try append(.init(id: item.id, ok: false, message: "项目已被保护，已跳过", bytes: 0), runID: runID); continue
                }
                try store.update { db in
                    _ = try context(db, runID: runID)
                    let i = db.runs.firstIndex { $0.id == runID }!; db.runs[i].intentID = item.id
                }
                var guarded = environment.cleanup
                let move = guarded.trash
                guarded.trash = { path in
                    guard path == item.item.path, item.unchanged() else { throw automationError("执行前目录内容变化，已跳过") }
                    return try move(path)
                }
                let outcome = environment.perform(item, guarded)
                if outcome.ok {
                    guard let destination = outcome.trashedTo else { throw automationError("执行结果缺少恢复位置，已停止；请核对废纸篓") }
                    try ledger.recordChecked([TrashedItem(path: destination, bytes: outcome.bytes, title: item.item.name, originalPath: item.item.path)])
                }
                if automatic { try environment.recordScheduledOutcome(item, outcome) }
                try append(outcome, runID: runID)
            }
            try store.update { db in
                guard let i = db.runs.firstIndex(where: { $0.id == runID }), db.runs[i].status == .running else { return }
                let results = db.runs[i].outcomes
                db.runs[i].status = results.count == selected.count && results.allSatisfy(\.ok) ? .completed : .partial
                db.runs[i].message = "已处理 \(results.filter(\.ok).count) 项，跳过或失败 \(selected.count-results.filter(\.ok).count) 项；移入废纸篓不等于释放空间"
                db.runs[i].updatedAt = now; db.runs[i].notified = false
                if let before, let after = environment.volume()?.available, after > before { db.runs[i].freedBytes = after-before }
                Self.finish(database: &db, runID: runID, now: now)
            }
        }
    }
    private func append(_ outcome: CleanupOutcome, runID: String) throws {
        try store.update { db in
            guard let index = db.runs.firstIndex(where: { $0.id == runID }) else { throw automationError("运行记录丢失") }
            db.runs[index].outcomes.append(outcome); db.runs[index].intentID = nil
        }
    }
    private func fail(runID: String, message: String, now: Date, permanent: Bool = true) throws {
        try store.update { db in
            guard let i = db.runs.firstIndex(where: { $0.id == runID }), !db.runs[i].status.terminal else { return }
            let uncertain = db.runs[i].intentID != nil || db.runs[i].status == .running
            db.runs[i].status = .needsAttention; db.runs[i].message = (uncertain ? "执行中断，结果可能不确定；" : "") + message
            db.runs[i].updatedAt = now; db.runs[i].notified = false
            let id = db.runs[i].ruleID
            var runtime = db.runtimes[id] ?? AutomationRuntime()
            // An unsuccessful pre-action scan has not consumed its space event.
            if !uncertain && db.runs[i].reasons.contains("space") { runtime.spaceLatched = false }
            AutomationPolicy.fail(runtime: &runtime, message: db.runs[i].message, now: now, permanent: permanent || uncertain)
            if let retryAt = runtime.retryAt {
                db.runs[i].message += "；约 \(Int(retryAt.timeIntervalSince(now) / 60)) 分钟后重试"
            }
            db.runtimes[id] = runtime
        }
    }
    private static func finish(database db: inout AutomationDatabase, runID: String, now: Date) {
        guard let run = db.runs.first(where: { $0.id == runID }), let i = db.rules.firstIndex(where: { $0.id == run.ruleID }),
              db.rules[i].revision == run.revision else { return }
        var runtime = db.runtimes[run.ruleID] ?? AutomationRuntime()
        AutomationPolicy.finish(rule: &db.rules[i], runtime: &runtime, now: now); db.runtimes[run.ruleID] = runtime
    }
    private func deliverNotifications() throws {
        for run in try store.read().runs where !run.notified && run.status != .scanning && run.status != .running && run.status != .skipped {
            // A capacity reminder record only notifies when the capacity really was low (completed). A failed or
            // unknown volume stays visible in the app with its blocker, but must not produce a "low space" system
            // notification. Runs with an intent/results are not marked reminderOnly and keep the generic attention notice.
            if run.isReminder && run.status != .completed { continue }
            if environment.notify(run) {
                try store.update { db in if let i = db.runs.firstIndex(where: { $0.id == run.id && $0.status == run.status }) { db.runs[i].notified = true } }
            }
        }
    }
}
