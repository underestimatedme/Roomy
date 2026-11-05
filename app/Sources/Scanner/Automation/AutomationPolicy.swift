// SPDX-License-Identifier: MPL-2.0
import Foundation

enum AutomationPolicy {
    static let interval: TimeInterval = 900
    static let day: TimeInterval = 86400
    static func evaluate(rule: AutomationRule, runtime: inout AutomationRuntime, volume: AutomationVolume?, now: Date) -> [String] {
        guard rule.enabled, runtime.blocker == nil else { return [] }
        if let previous = runtime.lastObserved, now < previous.addingTimeInterval(-300) {
            runtime.blocker = "系统时间回拨，请校准后恢复规则"; return []
        }
        runtime.lastObserved = max(runtime.lastObserved ?? now, now)
        guard let volume, volume.id == rule.volumeID, volume.total > 0, volume.available <= volume.total else {
            runtime.blocker = "磁盘不可读取或身份变化，请检查后恢复规则"; return []
        }
        var space = false
        if let metric = rule.metric, let threshold = rule.threshold {
            let value = capacityValue(metric, volume: volume)
            space = metric == .usedPercent ? value >= threshold : value < threshold
            let recovered = metric == .usedPercent ? value <= max(0, threshold - 3) : value >= threshold + 5
            runtime.recoverySamples = recovered ? min(2, runtime.recoverySamples + 1) : 0
            if runtime.recoverySamples == 2 { runtime.spaceLatched = false }
        }
        guard runtime.activeRunID == nil, runtime.cooldownUntil.map({ now >= $0 }) ?? true,
              runtime.retryAt.map({ now >= $0 }) ?? true else { return [] }
        var reasons: [String] = []
        // A rule without a schedule can only ever be triggered by capacity.
        if let due = runtime.nextDue, rule.days != nil, now >= due { reasons.append("time") }
        if space && !runtime.spaceLatched { reasons.append("space"); runtime.spaceLatched = true }
        return reasons
    }
    static func finish(rule: inout AutomationRule, runtime: inout AutomationRuntime, now: Date) {
        runtime.activeRunID = nil; runtime.cooldownUntil = now.addingTimeInterval(day)
        runtime.retryAt = nil; runtime.failures = 0
        if !rule.repeats { rule.enabled = false; runtime.nextDue = nil }
        else { runtime.nextDue = rule.days.map { now.addingTimeInterval(Double($0)*day) } }
    }
    /// Decimal GB, identical to the threshold comparison above (available / 1e9).
    static func decimalGB(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes)/1_000_000_000) }
    /// The metric value used by both the trigger and the post-access recheck.
    static func capacityValue(_ metric: AutomationMetric, volume: AutomationVolume) -> Double {
        metric == .usedPercent ? 100 * (1 - Double(volume.available)/Double(volume.total)) : Double(volume.available)/1_000_000_000
    }
    /// The actual capacity condition right now, without the trigger hysteresis. nil = unusable rule or volume.
    static func belowThreshold(rule: AutomationRule, volume: AutomationVolume) -> Bool? {
        guard let metric = rule.metric, let threshold = rule.threshold,
              volume.total > 0, volume.available <= volume.total else { return nil }
        let value = capacityValue(metric, volume: volume)
        return metric == .usedPercent ? value >= threshold : value < threshold
    }
    /// Recorded when the permission check outlasted the low-capacity reading: no fake "below threshold" text.
    static func recoveredMessage(rule: AutomationRule, volume: AutomationVolume) -> String {
        switch (rule.metric, rule.threshold) {
        case (.availableGB?, let threshold?):
            return "本轮检查时容量已恢复：当前剩余 \(decimalGB(volume.available))（提醒阈值 \(String(format: "%.1f GB", threshold))），不发送提醒，本轮按已恢复跳过。"
        case (.usedPercent?, let threshold?):
            return String(format: "本轮检查时容量已恢复：当前已用 %.0f%%（提醒阈值 %.0f%%），不发送提醒，本轮按已恢复跳过。",
                          capacityValue(.usedPercent, volume: volume), threshold)
        default:
            return "本轮检查时容量已恢复，不发送提醒，本轮按已恢复跳过。"
        }
    }
    static let reminderTitle = "磁盘空间不足"
    /// Capacity triggers only notify. The text must never claim that anything was cleaned.
    static func reminderMessage(rule: AutomationRule, volume: AutomationVolume?) -> String {
        var text: String
        switch (rule.metric, rule.threshold) {
        case (.availableGB?, let threshold?):
            // Format the stored threshold directly. Old records may hold any finite Double, and converting a large
            // one to an integer byte count would trap.
            let limit = String(format: "%.1f GB", threshold)
            text = volume.map { "当前剩余 \(decimalGB($0.available))，低于提醒阈值 \(limit)。" }
                ?? "当前剩余空间无法读取，提醒阈值为 \(limit)。"
        case (.usedPercent?, let threshold?):
            // An unreadable or unusable volume stays unknown instead of being reported as 0%.
            if let volume, volume.total > 0 {
                let used = 100 * (1 - Double(volume.available)/Double(volume.total))
                text = String(format: "当前已用 %.0f%%，达到提醒阈值 %.0f%%。", used, threshold)
            } else {
                text = String(format: "当前已用比例无法读取，提醒阈值为 %.0f%%。", threshold)
            }
        default:
            text = volume.map { "当前剩余 \(decimalGB($0.available))。" } ?? "当前剩余空间无法读取。"
        }
        text += "本次只发出提醒，没有扫描或删除任何文件；请打开应用查看空间并自行选择要清理的内容。"
        if rule.days != nil {
            // Keep the wording aligned with the UI: this capacity trigger only reminds, the time condition is still
            // evaluated exactly as before, and a separate rule is an addition rather than a replacement.
            text += "该规则同时含定时条件：本次只是容量提醒，定时条件仍按原规则计算；如需自动清理请新建独立的按时间规则。"
        }
        return text
    }
    static func fail(runtime: inout AutomationRuntime, message: String, now: Date, permanent: Bool) {
        runtime.activeRunID = nil; runtime.failures += 1
        if permanent || runtime.failures > 3 { runtime.blocker = message; runtime.retryAt = nil }
        else { runtime.retryAt = now.addingTimeInterval([1800.0, 7200, 86400][runtime.failures - 1]) }
    }
}
