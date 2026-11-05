// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct AutomationScanRuleTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp/roomy-automation-scan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutomationStore(directory: root)
        let volume = AutomationVolume(id: "fixture", path: "/", total: 1_000_000_000_000, available: 100_000_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let file = root.appendingPathComponent("automation.json")

        // 1. Default scheduled scan: no cache scope, no deletion consent.
        let scanRequest = try json("""
        {"task":"scan","title":"定时扫描","days":7,"repeats":true,"mode":"confirm","scopeIDs":[],"metric":""}
        """)
        let draft = try AutomationRuleRequest.make(args: scanRequest, volume: volume, store: store, now: now)
        precondition(draft.isScanRule && draft.scopes.isEmpty && draft.mode == .confirm, "scan rule must be read-only")
        precondition(draft.days == 7 && draft.repeats && draft.metric == nil && draft.threshold == nil)
        let saved = try AutomationRuleRequest.save(args: scanRequest, volume: volume, store: store, now: now)
        precondition(saved.rule.revision == 1)
        precondition(saved.nextDue == now.addingTimeInterval(7 * 86400), "scan nextDue must be now + N days")
        precondition(saved.rule.isScanRule && saved.rule.repeats)

        var database = try store.read()
        precondition(database.paused, "creating a rule must not unpause background automation")
        precondition(database.rules.count == 1 && database.rules[0].id == saved.id)
        precondition(database.rules[0].task == .scan && database.rules[0].days == 7)
        precondition(sameDate(database.runtimes[saved.id]?.nextDue, saved.nextDue))
        // The persisted file is a real JSON document, not just an in-memory value.
        let onDisk = try JSONDecoder().decode(AutomationDatabase.self, from: Data(contentsOf: file))
        precondition(onDisk.rules.first?.task == .scan && onDisk.rules.first?.scopes.isEmpty == true)

        // 2. An edit with an unresolved intent keeps the safety block and all history.
        var uncertainRunID = ""
        try store.update { db in
            db.paused = false
            db.rules[0].enabled = false
            var confirmation = AutomationRun(ruleID: saved.id, revision: saved.revision, title: saved.rule.title, createdAt: now, updatedAt: now, reasons: ["time"])
            confirmation.status = .awaitingConfirmation
            var uncertain = AutomationRun(ruleID: saved.id, revision: saved.revision, title: saved.rule.title, createdAt: now, updatedAt: now, reasons: ["time"])
            uncertain.status = .running
            uncertain.intentID = "uncertain-intent"
            uncertain.freedBytes = 4096
            uncertainRunID = uncertain.id
            var finished = AutomationRun(ruleID: saved.id, revision: saved.revision, title: saved.rule.title, createdAt: now, updatedAt: now, reasons: ["time"])
            finished.status = .completed
            finished.freedBytes = 8192
            db.runs = [confirmation, uncertain, finished]
            var runtime = db.runtimes[saved.id] ?? AutomationRuntime()
            runtime.blocker = "旧权限错误"
            runtime.retryAt = now.addingTimeInterval(3600)
            runtime.failures = 2
            runtime.activeRunID = uncertain.id
            db.runtimes[saved.id] = runtime
        }
        let beforeEdit = try store.read()
        let confirmationToken = beforeEdit.runs[0].token
        let uncertainToken = beforeEdit.runs[1].token
        let finishedToken = beforeEdit.runs[2].token

        let editNow = now.addingTimeInterval(86400)
        let editRequest = try json("""
        {"id":"\(saved.id)","task":"scan","title":"定时扫描","days":14,"repeats":true,"mode":"confirm","scopeIDs":[],"metric":""}
        """)
        let edited = try AutomationRuleRequest.save(args: editRequest, volume: volume, store: store, now: editNow)
        precondition(edited.id == saved.id && edited.rule.revision == saved.rule.revision + 1)
        precondition(sameDate(edited.rule.createdAt, saved.rule.createdAt))
        precondition(edited.rule.enabled == false, "editing must preserve the stored enabled state")
        precondition(edited.nextDue == editNow.addingTimeInterval(14 * 86400))

        database = try store.read()
        precondition(!database.paused, "editing a rule must not change the global pause")
        precondition(database.rules.count == 1 && database.rules[0].days == 14)
        precondition(sameDate(database.runtimes[saved.id]?.nextDue, edited.nextDue))
        precondition(database.runtimes[saved.id]?.blocker == "旧权限错误", "unresolved intent must keep the safety block")
        precondition(sameDate(database.runtimes[saved.id]?.retryAt, now.addingTimeInterval(3600)))
        precondition(database.runtimes[saved.id]?.failures == 2)
        precondition(database.runtimes[saved.id]?.activeRunID == uncertainRunID)
        precondition(database.runs.count == 3)
        precondition(database.runs[0].status == .skipped, "old confirmation must be invalidated")
        precondition(database.runs[0].token != confirmationToken)
        precondition(database.runs[1].status == .needsAttention && database.runs[1].intentID == "uncertain-intent")
        precondition(database.runs[1].token != uncertainToken && database.runs[1].freedBytes == 4096,
                     "uncertain intent and result must be preserved")
        precondition(database.runs[2].status == .completed && database.runs[2].freedBytes == 8192)
        precondition(database.runs[2].token == finishedToken, "terminal result must not be rewritten")

        // 2b. A second edit still increments and keeps the unresolved block.
        let editAgainNow = editNow.addingTimeInterval(86400)
        let editAgainRequest = try json("""
        {"id":"\(saved.id)","task":"scan","title":"定时扫描","days":21,"repeats":true,"mode":"confirm","scopeIDs":[],"metric":""}
        """)
        let editedAgain = try AutomationRuleRequest.save(args: editAgainRequest, volume: volume, store: store, now: editAgainNow)
        precondition(editedAgain.rule.revision == edited.rule.revision + 1)
        database = try store.read()
        precondition(database.rules[0].days == 21)
        precondition(database.runtimes[saved.id]?.blocker == "旧权限错误")
        precondition(database.runtimes[saved.id]?.activeRunID == uncertainRunID)
        precondition(database.runs.first(where: { $0.id == uncertainRunID })?.intentID == "uncertain-intent")

        // 3. Capacity reminders: explicit continuous, explicit once, and default continuous.
        let continuousRequest = try json("""
        {"title":"持续容量提醒","metric":"availableGB","threshold":20,"mode":"confirm","repeats":true}
        """)
        let continuous = try AutomationRuleRequest.save(args: continuousRequest, volume: volume, store: store, now: now)
        precondition(continuous.nextDue == nil && !continuous.rule.isScanRule && continuous.rule.task == nil)
        precondition(continuous.rule.days == nil && continuous.rule.repeats)
        precondition(continuous.rule.metric == .availableGB && continuous.rule.threshold == 20)

        let onceRequest = try json("""
        {"title":"单次容量提醒","metric":"availableGB","threshold":30,"mode":"confirm","repeats":false}
        """)
        let once = try AutomationRuleRequest.save(args: onceRequest, volume: volume, store: store, now: now)
        precondition(once.nextDue == nil && once.rule.repeats == false)

        let defaultRepeatRequest = try json("""
        {"title":"默认容量提醒","metric":"availableGB","threshold":40,"mode":"confirm"}
        """)
        let defaultRepeat = try AutomationRuleRequest.save(args: defaultRepeatRequest, volume: volume, store: store, now: now)
        precondition(defaultRepeat.nextDue == nil && defaultRepeat.rule.repeats, "capacity reminders default to continuous")

        database = try store.read()
        precondition(!database.paused)
        precondition(database.runtimes[continuous.id] != nil && database.runtimes[continuous.id]?.nextDue == nil)

        // 4. A normal error edit clears stale runtime state so the rule can run again.
        try store.update { db in
            guard db.rules.contains(where: { $0.id == continuous.id }) else { fatalError("continuous rule missing") }
            var stale = AutomationRun(ruleID: continuous.id, revision: continuous.rule.revision, title: continuous.rule.title, createdAt: now, updatedAt: now, reasons: ["space"])
            stale.status = .awaitingConfirmation
            db.runs.append(stale)
            var runtime = db.runtimes[continuous.id] ?? AutomationRuntime()
            runtime.blocker = "旧磁盘错误"
            runtime.retryAt = now.addingTimeInterval(7200)
            runtime.failures = 3
            runtime.activeRunID = stale.id
            db.runtimes[continuous.id] = runtime
        }
        let staleToken = try store.read().runs.first(where: { $0.ruleID == continuous.id })!.token

        let reviveNow = now.addingTimeInterval(2 * 86400)
        let reviveRequest = try json("""
        {"id":"\(continuous.id)","title":"持续容量提醒","metric":"availableGB","threshold":25,"mode":"confirm"}
        """)
        let revived = try AutomationRuleRequest.save(args: reviveRequest, volume: volume, store: store, now: reviveNow)
        precondition(revived.rule.revision == continuous.rule.revision + 1)
        precondition(revived.rule.repeats, "omitting repeats must preserve the stored continuous reminder")
        precondition(revived.nextDue == nil)
        database = try store.read()
        precondition(!database.paused)
        precondition(database.rules.first(where: { $0.id == continuous.id })?.threshold == 25)
        precondition(database.runtimes[continuous.id]?.blocker == nil)
        precondition(database.runtimes[continuous.id]?.retryAt == nil)
        precondition(database.runtimes[continuous.id]?.failures == 0)
        precondition(database.runtimes[continuous.id]?.activeRunID == nil)
        precondition(database.runs.first(where: { $0.ruleID == continuous.id })?.status == .skipped)
        precondition(database.runs.first(where: { $0.ruleID == continuous.id })?.token != staleToken)

        // 5. Volume and threshold boundaries.
        let zeroVolume = AutomationVolume(id: "fixture", path: "/", total: 0, available: 0)
        let badVolume = AutomationVolume(id: "fixture", path: "/", total: 10_000_000_000, available: 11_000_000_000)
        let smallVolume = AutomationVolume(id: "fixture", path: "/", total: 10_000_000_000, available: 5_000_000_000)
        try rejects("""
        {"task":"scan","days":7,"mode":"confirm"}
        """, volume: zeroVolume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":10,"mode":"confirm"}
        """, volume: zeroVolume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":10,"mode":"confirm"}
        """, volume: badVolume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":6,"mode":"confirm"}
        """, volume: smallVolume, store: store, now: now)
        // threshold 5 + 5 GB hysteresis == total 10 GB is the accepted boundary.
        let boundaryRequest = try json("""
        {"title":"边界容量提醒","metric":"availableGB","threshold":5,"mode":"confirm","repeats":false}
        """)
        let boundary = try AutomationRuleRequest.save(args: boundaryRequest, volume: smallVolume, store: store, now: now)
        precondition(boundary.rule.threshold == 5 && boundary.nextDue == nil)

        // 6. Automatic, mixed, unknown, usedPercent, and out-of-range requests are rejected.
        try rejects("""
        {"task":"cleanup","days":7,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"task":"scan","days":7,"mode":"automatic"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"task":"scan","days":7,"mode":"confirm","threshold":5}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"task":"scan","days":7,"mode":"confirm","scopeIDs":["cache"]}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"task":"scan","days":0,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"task":"scan","days":3651,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"task":"scan","days":7.5,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":10,"mode":"confirm","days":3}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":-1,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":"10","mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":200000,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"usedPercent","threshold":90,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"bogus","threshold":10,"mode":"confirm"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":10,"mode":"automatic"}
        """, volume: volume, store: store, now: now)
        try rejects("""
        {"metric":"availableGB","threshold":10,"mode":"confirm","consent":true}
        """, volume: volume, store: store, now: now)

        // 7. Revision overflow is rejected without changing the stored rule.
        try store.update { db in
            guard let index = db.rules.firstIndex(where: { $0.id == once.id }) else { fatalError("once rule missing") }
            db.rules[index].revision = Int.max
        }
        let overflowRequest = try json("""
        {"id":"\(once.id)","title":"单次容量提醒","metric":"availableGB","threshold":35,"mode":"confirm","repeats":false}
        """)
        do {
            _ = try AutomationRuleRequest.save(args: overflowRequest, volume: volume, store: store, now: now)
            fatalError("revision overflow must be rejected")
        } catch {}
        let afterOverflow = try store.read()
        precondition(afterOverflow.rules.first(where: { $0.id == once.id })?.revision == Int.max)
        precondition(afterOverflow.rules.first(where: { $0.id == once.id })?.threshold == 30)

        // 8. Old JSON without task/scanOnly/scanSummary, including usedPercent and scoped rules, stays readable.
        let oldCapacityID = UUID().uuidString
        let oldScopedID = UUID().uuidString
        let oldRunID = UUID().uuidString
        let oldToken = UUID().uuidString
        let stamp = now.timeIntervalSinceReferenceDate
        let oldJSON = """
        {"schema":1,"paused":true,"rules":[{"id":"\(oldCapacityID)","title":"旧容量提醒","enabled":true,"revision":1,"repeats":false,"metric":"usedPercent","threshold":90,"mode":"confirm","scopes":[],"volumeID":"fixture","createdAt":\(stamp),"updatedAt":\(stamp)},{"id":"\(oldScopedID)","title":"旧定时缓存","enabled":true,"revision":1,"days":7,"repeats":true,"mode":"confirm","scopes":[{"kind":"appCache","path":"/private/tmp/cache","title":"缓存"}],"volumeID":"fixture","createdAt":\(stamp),"updatedAt":\(stamp)}],"runtimes":{},"runs":[{"id":"\(oldRunID)","ruleID":"\(oldCapacityID)","revision":1,"title":"旧记录","createdAt":\(stamp),"updatedAt":\(stamp),"status":"completed","reasons":["space"],"token":"\(oldToken)","items":[],"outcomes":[],"message":"","notified":true,"freedBytes":0}]}
        """
        try Data(oldJSON.utf8).write(to: file)
        let old = try store.read()
        precondition(old.rules.count == 2)
        guard let oldCapacity = old.rules.first(where: { $0.id == oldCapacityID }),
              let oldScoped = old.rules.first(where: { $0.id == oldScopedID }) else { fatalError("old rules missing") }
        precondition(oldCapacity.task == nil && !oldCapacity.isScanRule && oldCapacity.capacityOnly)
        precondition(oldCapacity.metric == .usedPercent && oldCapacity.threshold == 90)
        precondition(oldScoped.task == nil && !oldScoped.isScanRule && oldScoped.days == 7 && oldScoped.scopes.count == 1)
        precondition(old.runs[0].scanOnly == nil && old.runs[0].scanSummary == nil && !old.runs[0].isScanOnly)

        // 9. A scan-only record is display-only and cannot gain a deletion entry.
        var scanRunID = ""
        try store.update { db in
            var scanRun = AutomationRun(ruleID: oldCapacityID, revision: 1, title: "只读扫描", createdAt: now, updatedAt: now, reasons: [])
            scanRun.status = .completed
            scanRun.scanOnly = true
            scanRun.scanSummary = AutomationScanSummary(
                scannedAt: now, itemCount: 12, actionableCount: 3, estimatedBytes: 2048,
                warnings: ["部分目录不可读"],
                preview: [AutomationScanSummary.Preview(title: "缓存", bytes: 1024)])
            scanRunID = scanRun.id
            db.runs.append(scanRun)
        }
        let scanDatabase = try store.read()
        guard let scanRecord = scanDatabase.runs.first(where: { $0.id == scanRunID }) else { fatalError("scan record missing") }
        precondition(scanRecord.isScanOnly && scanRecord.scanSummary?.itemCount == 12)
        precondition(scanRecord.items.isEmpty && scanRecord.outcomes.isEmpty && scanRecord.intentID == nil && scanRecord.freedBytes == 0)
        let validScanJSON = try Data(contentsOf: file)

        try mutate(file: file) { object in
            var runs = object["runs"] as! [[String: Any]]
            let index = runs.firstIndex { ($0["id"] as? String) == scanRunID }!
            runs[index]["intentID"] = "should-not-exist"
            object["runs"] = runs
        }
        do { _ = try store.read(); fatalError("scan record with intent must be rejected") } catch {}
        try validScanJSON.write(to: file)

        try mutate(file: file) { object in
            var runs = object["runs"] as! [[String: Any]]
            let index = runs.firstIndex { ($0["id"] as? String) == scanRunID }!
            runs[index]["status"] = "running"
            object["runs"] = runs
        }
        do { _ = try store.read(); fatalError("scan record pretending to run must be rejected") } catch {}
        try validScanJSON.write(to: file)

        try mutate(file: file) { object in
            var runs = object["runs"] as! [[String: Any]]
            let index = runs.firstIndex { ($0["id"] as? String) == scanRunID }!
            runs[index]["status"] = "awaitingConfirmation"
            object["runs"] = runs
        }
        do { _ = try store.read(); fatalError("scan record pretending to await confirmation must be rejected") } catch {}
        try validScanJSON.write(to: file)

        try mutate(file: file) { object in
            var runs = object["runs"] as! [[String: Any]]
            let index = runs.firstIndex { ($0["id"] as? String) == scanRunID }!
            runs[index]["freedBytes"] = 1
            object["runs"] = runs
        }
        do { _ = try store.read(); fatalError("scan record with freed bytes must be rejected") } catch {}
        try validScanJSON.write(to: file)

        let restored = try store.read()
        precondition(restored.runs.first(where: { $0.id == scanRunID })?.isScanOnly == true)

        print("AutomationScanRuleTests passed")
    }

    static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince(rhs)) < 0.001
    }

    static func json(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            fatalError("request fixture is not a JSON object")
        }
        return object
    }

    static func rejects(_ text: String, volume: AutomationVolume, store: AutomationStore, now: Date) throws {
        let args = try json(text)
        do {
            _ = try AutomationRuleRequest.save(args: args, volume: volume, store: store, now: now)
            fatalError("request should have been rejected: \(text)")
        } catch {}
    }

    static func mutate(file: URL, _ body: (inout [String: Any]) throws -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try body(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }
}
