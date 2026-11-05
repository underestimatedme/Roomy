// SPDX-License-Identifier: MPL-2.0
import CoreFoundation
import Foundation

/// Shared input boundary for GUI rule saves and tests.
/// It only reads and writes rule data: it never starts a scan, registers background work, or changes the global pause.
enum AutomationRuleRequest {
    struct Saved: Equatable {
        var id: String
        var title: String
        var revision: Int
        var nextDue: Date?
        var rule: AutomationRule
    }

    private struct Draft {
        var existing: AutomationRule?
        var rule: AutomationRule
        var nextDue: Date?
    }

    private static let allowedKeys: Set<String> = [
        "id", "title", "task", "days", "repeats", "mode", "scopeIDs", "metric", "threshold",
    ]
    private static let scanTitle = "定时扫描"
    private static let capacityTitle = "磁盘空间提醒"

    static func make(args: [String: Any], volume: AutomationVolume, store: AutomationStore, now: Date = Date()) throws -> AutomationRule {
        try draft(args: args, volume: volume, store: store, now: now).rule
    }

    static func save(args: [String: Any], volume: AutomationVolume, store: AutomationStore, now: Date = Date()) throws -> Saved {
        let request = try draft(args: args, volume: volume, store: store, now: now)
        var saved = request.rule
        let nextDue = request.nextDue
        try store.update { database in
            var preservesUncertainWork = false
            if request.existing != nil {
                guard let index = database.rules.firstIndex(where: { $0.id == saved.id }) else {
                    throw automationError("要修改的规则已不存在")
                }
                // Keep identity and lifecycle fields from the stored record; only the revision advances.
                let stored = database.rules[index]
                guard stored.revision < Int.max else { throw automationError("规则版本号已达到上限") }
                preservesUncertainWork = database.runs.contains { $0.ruleID == saved.id && $0.intentID != nil }
                saved.revision = stored.revision + 1
                saved.createdAt = stored.createdAt
                saved.enabled = stored.enabled
                saved.updatedAt = now
                try saved.validate()
                database.rules[index] = saved
                database.invalidateRuns(ruleID: saved.id, message: "规则已修改，旧的确认已失效")
            } else {
                try saved.validate()
                database.rules.append(saved)
            }
            var runtime = database.runtimes[saved.id] ?? AutomationRuntime()
            runtime.nextDue = nextDue
            if request.existing != nil && !preservesUncertainWork {
                // A normal edit clears stale failures so the new schedule can take effect. An unresolved intent
                // keeps the safety block, and invalidateRuns never erases the historical intent or results.
                runtime.blocker = nil
                runtime.retryAt = nil
                runtime.failures = 0
                runtime.activeRunID = nil
            }
            database.runtimes[saved.id] = runtime
        }
        return Saved(id: saved.id, title: saved.title, revision: saved.revision, nextDue: nextDue, rule: saved)
    }

    private static func draft(args: [String: Any], volume: AutomationVolume, store: AutomationStore, now: Date) throws -> Draft {
        for key in args.keys where !allowedKeys.contains(key) {
            throw automationError("未知规则参数：\(key)")
        }
        guard !volume.id.isEmpty else { throw automationError("磁盘标识无效") }
        guard volume.total > 0, volume.available <= volume.total else { throw automationError("磁盘容量数据无效") }

        var existing: AutomationRule?
        var id = UUID().uuidString
        var createdAt = now
        var revision = 1
        var enabled = true
        if let requestedID = try string(args["id"], key: "id", allowEmpty: false) {
            guard UUID(uuidString: requestedID) != nil else { throw automationError("规则标识无效") }
            guard let stored = try store.read().rules.first(where: { $0.id == requestedID }) else {
                throw automationError("要修改的规则已不存在")
            }
            existing = stored
            id = stored.id
            createdAt = stored.createdAt
            revision = stored.revision
            enabled = stored.enabled
        }

        let requestedTask = try string(args["task"], key: "task", allowEmpty: false)
        if let requestedTask, requestedTask != AutomationTask.scan.rawValue {
            throw automationError("未知的自动化任务类型")
        }
        let isScan = requestedTask != nil

        let requestedTitle = try string(args["title"], key: "title", allowEmpty: false)
        let title = requestedTitle ?? existing?.title ?? (isScan ? scanTitle : capacityTitle)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120 else {
            throw automationError("规则名称无效")
        }

        let mode = try string(args["mode"], key: "mode", allowEmpty: false)
        guard mode == AutomationMode.confirm.rawValue else {
            throw automationError("新规则只能使用确认模式，不能自动删除")
        }

        let scopeIDs = try stringArray(args["scopeIDs"], key: "scopeIDs")
        guard scopeIDs.isEmpty else {
            throw automationError("本批规则不能绑定清理范围，扫描只读取候选")
        }

        var days: Int?
        var repeats = true
        var metric: AutomationMetric?
        var threshold: Double?
        var nextDue: Date?
        let requestedRepeats = try boolean(args["repeats"], key: "repeats")

        if isScan {
            guard let rawDays = value(args, "days") else { throw automationError("定时扫描必须设置天数") }
            let scanDays = try integer(rawDays, key: "days", range: 1...3650)
            days = scanDays
            repeats = requestedRepeats ?? existing?.repeats ?? true
            if let rawMetric = value(args, "metric") {
                guard let text = try string(rawMetric, key: "metric", allowEmpty: true), text.isEmpty else {
                    throw automationError("定时扫描不能包含容量条件")
                }
            }
            if value(args, "threshold") != nil { throw automationError("定时扫描不能包含容量阈值") }
            nextDue = now.addingTimeInterval(Double(scanDays) * 86400)
        } else {
            if value(args, "days") != nil { throw automationError("容量提醒不能同时设置定时天数") }
            repeats = requestedRepeats ?? existing?.repeats ?? true
            guard let rawMetric = value(args, "metric"),
                  let metricText = try string(rawMetric, key: "metric", allowEmpty: false),
                  metricText == AutomationMetric.availableGB.rawValue else {
                throw automationError("容量提醒必须使用 availableGB")
            }
            metric = .availableGB
            guard let rawThreshold = value(args, "threshold") else { throw automationError("容量提醒必须设置阈值") }
            let parsedThreshold = try number(rawThreshold, key: "threshold")
            guard parsedThreshold > 0 else { throw automationError("磁盘阈值无效") }
            guard parsedThreshold <= 100_000 else { throw automationError("磁盘阈值过大") }
            // Keep the original handler's recovery margin: the 5 GB hysteresis must still fit under the disk total.
            let totalGB = Double(volume.total) / 1_000_000_000
            guard parsedThreshold + 5 <= totalGB else {
                throw automationError("容量阈值过高：需为容量恢复预留 5 GB")
            }
            threshold = parsedThreshold
            nextDue = nil
        }

        var rule = AutomationRule(title: title, days: days, repeats: repeats, metric: metric, threshold: threshold,
                                  mode: .confirm, scopes: [], volumeID: volume.id, now: now,
                                  task: isScan ? .scan : nil)
        rule.id = id
        rule.createdAt = createdAt
        rule.updatedAt = now
        rule.revision = revision
        rule.enabled = enabled
        try rule.validate()
        return Draft(existing: existing, rule: rule, nextDue: nextDue)
    }

    private static func value(_ args: [String: Any], _ key: String) -> Any? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        return raw
    }

    private static func string(_ value: Any?, key: String, allowEmpty: Bool) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw automationError("规则参数 \(key) 类型无效") }
        guard text.count <= 1024 else { throw automationError("规则参数 \(key) 过长") }
        if !allowEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw automationError("规则参数 \(key) 为空")
        }
        return text
    }

    private static func stringArray(_ value: Any?, key: String) throws -> [String] {
        guard let value, !(value is NSNull) else { return [] }
        guard let array = value as? [Any], array.count <= 100 else {
            throw automationError("规则参数 \(key) 类型无效")
        }
        return try array.map { item in
            guard let text = item as? String, !text.isEmpty, text.count <= 1024 else {
                throw automationError("规则参数 \(key) 类型无效")
            }
            return text
        }
    }

    private static func boolean(_ value: Any?, key: String) throws -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw automationError("规则参数 \(key) 类型无效")
        }
        return number.boolValue
    }

    private static func integer(_ value: Any?, key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value, !(value is NSNull) else { throw automationError("规则参数 \(key) 缺失") }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw automationError("规则参数 \(key) 类型无效")
        }
        let parsed = number.doubleValue
        guard parsed.isFinite, parsed.rounded() == parsed,
              parsed >= Double(range.lowerBound), parsed <= Double(range.upperBound) else {
            throw automationError("规则参数 \(key) 超出范围")
        }
        return Int(parsed)
    }

    private static func number(_ value: Any?, key: String) throws -> Double {
        guard let value, !(value is NSNull) else { throw automationError("规则参数 \(key) 缺失") }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw automationError("规则参数 \(key) 类型无效")
        }
        let parsed = number.doubleValue
        guard parsed.isFinite else { throw automationError("规则参数 \(key) 类型无效") }
        return parsed
    }
}
