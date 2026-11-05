// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

func automationError(_ message: String, transient: Bool = false) -> NSError {
    NSError(domain: "RoomyAutomation", code: transient ? 2 : 1, userInfo: [NSLocalizedDescriptionKey: message])
}
// Retry only recognized pre-action temporary failures. Unknown errors fail closed.
func automationIsTransient(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == "RoomyAutomation" { return error.code == 2 }
    if error.domain == NSPOSIXErrorDomain { return [EAGAIN, EINTR, ETIMEDOUT, EBUSY].contains(Int32(error.code)) }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return [EAGAIN, EINTR, ETIMEDOUT, EBUSY].contains(Int32(underlying.code))
    }
    return false
}
enum AutomationMode: String, Codable { case confirm, automatic }
enum AutomationMetric: String, Codable { case usedPercent, availableGB }
/// CLI cleanup is an explicit new authorization; old automatic rules never inherit it.
enum AutomationTask: String, Codable { case scan, cliCleanup }
struct AutomationScope: Codable, Equatable {
    enum Kind: String, Codable { case appCache, derivedObjects }
    var kind: Kind
    var path: String
    var title: String
}
struct AutomationVolume: Codable, Equatable {
    var id: String
    var path: String
    var total: UInt64
    var available: UInt64
}
struct AutomationRule: Codable, Equatable {
    var id = UUID().uuidString
    var title: String
    var enabled = true
    var revision = 1
    var days: Int?
    var repeats: Bool
    var metric: AutomationMetric?
    var threshold: Double?
    var mode: AutomationMode
    var scopes: [AutomationScope]
    /// Optional so rules written before scheduled scans still decode. Never inferred from empty scopes.
    var task: AutomationTask?
    var volumeID: String
    var createdAt: Date
    var updatedAt: Date
    init(title: String, days: Int?, repeats: Bool, metric: AutomationMetric?, threshold: Double?, mode: AutomationMode, scopes: [AutomationScope], volumeID: String, now: Date, task: AutomationTask? = nil) {
        self.title = title; self.days = days; self.repeats = repeats; self.metric = metric
        self.threshold = threshold; self.mode = mode; self.scopes = scopes; self.volumeID = volumeID
        self.task = task
        createdAt = now; updatedAt = now
    }
    /// A capacity trigger never authorizes deletion. Only a rule without any schedule is a pure capacity rule:
    /// it may omit scopes, and a missing scope never turns an old time-or-capacity combination into a timed cleanup.
    var capacityOnly: Bool { metric != nil && days == nil }
    /// Explicit marker only. An empty scope list is not evidence of a scan rule.
    var isScanRule: Bool { task == .scan }
    func validate() throws {
        guard UUID(uuidString: id) != nil, revision > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 120, !volumeID.isEmpty, scopes.count <= 100,
              days != nil || metric != nil, days.map({ (1...3650).contains($0) }) ?? true,
              (metric == nil) == (threshold == nil), createdAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite else { throw automationError("自动清理规则不完整或参数无效") }
        if isScanRule {
            // A scheduled scan is read-only: no capacity trigger, no cache scope, and never automatic mode.
            guard days != nil, metric == nil, threshold == nil, mode == .confirm, scopes.isEmpty else {
                throw automationError("定时扫描规则不能包含容量条件、清理范围或自动删除")
            }
            return
        }
        if task == .cliCleanup {
            guard days != nil, metric == nil, threshold == nil, mode == .automatic, !scopes.isEmpty else {
                throw automationError("命令行定时清理需要明确的间隔和缓存范围，不能包含容量条件")
            }
        }
        if capacityOnly {
            // New reminder rules stay confirm. An old record that still carries scopes keeps its stored mode so the
            // record stays readable; the worker never prepares or executes a capacity reason either way.
            guard mode == .confirm || !scopes.isEmpty else { throw automationError("容量不足提醒只做提醒，不能设为自动清理") }
        } else {
            // Timed rules, and old time-or-capacity combinations, still require an explicit authorized cache scope.
            guard !scopes.isEmpty else { throw automationError("按时间自动清理必须选择缓存范围") }
        }
        if let metric, let threshold {
            guard threshold.isFinite, threshold > 0,
                  metric != .usedPercent || (1...99).contains(threshold) else { throw automationError("磁盘阈值无效") }
        }
        for scope in scopes {
            let components = scope.path.split(separator: "/")
            guard scope.path.hasPrefix("/"), !scope.path.contains("\0"), !components.contains(".."),
                  !components.contains("."), components.count >= 3,
                  !scope.path.hasSuffix("/"), !scope.path.contains("//") else { throw automationError("清理范围路径无效") }
        }
        guard Set(scopes.map(\.path)).count == scopes.count else { throw automationError("清理范围重复") }
    }
}
struct AutomationRuntime: Codable, Equatable {
    var nextDue: Date?
    var lastObserved: Date?
    var cooldownUntil: Date?
    var activeRunID: String?
    var spaceLatched = false
    var recoverySamples = 0
    var retryAt: Date?
    var failures = 0
    var blocker: String?
}
