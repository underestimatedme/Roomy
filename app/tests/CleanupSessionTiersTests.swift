// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func check(_ value: Bool, _ message: String = "", line: UInt = #line) {
    precondition(value, "line \(line): \(message)")
}

@main struct CleanupSessionTiersTests {
    static func entry(_ id: String, key: CleanupPreferenceKey?, tier: CleanupTier, hold: Bool = false) -> CleanupEntry {
        let selectable = tier != .locked
        var e = CleanupEntry(id: id, title: id, size: 10, estimateIsApprox: false, evidence: "fixture", actionLabel: "进废纸篓",
            reversible: true, risk: .amber, selectable: selectable, defaultChecked: tier == .obsolete && selectable, source: "rule")
        e.tier = tier; e.tierReason = "出厂"; e.preferenceKey = key
        if hold { e.safetyHold = true }
        return e
    }
    static func list(_ entries: [CleanupEntry]) -> CleanupList {
        CleanupList(candidates: entries.map { CleanupCandidate(entry: $0, action: nil) })
    }
    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    static func main() throws {
        let key = CleanupPreferenceKey(owner: "go", kind: "goBuildCache", scope: CleanupPreferenceKey.digest("/fixture"))

        // 决策：有键 → 记住；无键 → 仅本次；同档 → 不写
        check(try CleanupTierMove.decide(entry: entry("a", key: key, tier: .review), to: .rebuildable) == .remember(key, from: .review))
        check(try CleanupTierMove.decide(entry: entry("b", key: nil, tier: .review), to: .obsolete) == .sessionOnly)
        check(try CleanupTierMove.decide(entry: entry("a", key: key, tier: .rebuildable), to: .rebuildable) == .unchanged)
        check(try CleanupTierMove.decide(entry: entry("b", key: nil, tier: .obsolete), to: .obsolete) == .unchanged)

        // 锁定条目、锁定目标、安全降级条目都拒绝（有键无键一样）
        check(message { _ = try CleanupTierMove.decide(entry: entry("l", key: key, tier: .locked), to: .obsolete) } == "不能删的项目不能换档")
        check(message { _ = try CleanupTierMove.decide(entry: entry("a", key: key, tier: .review), to: .locked) } == "不能删的项目不能换档")
        check(message { _ = try CleanupTierMove.decide(entry: entry("h", key: key, tier: .review, hold: true), to: .obsolete) } == CleanupTierAdjustments.holdRefusal)
        check(message { _ = try CleanupTierMove.decide(entry: entry("h", key: nil, tier: .review, hold: true), to: .obsolete) } == CleanupTierAdjustments.holdRefusal)

        // 会话换档：重建后仍在，reset 后清除
        var tiers = CleanupSessionTiers()
        tiers.set(id: "b", tier: .obsolete)
        let first = list([entry("a", key: nil, tier: .review), entry("b", key: nil, tier: .review)])
        let applied = tiers.apply(to: first).entries
        check(applied[0].tier == .review && applied[0].tierReason == "出厂", "other entries untouched")
        check(applied[1].tier == .obsolete && applied[1].defaultChecked && applied[1].tierReason?.contains("仅本次") == true)
        let rebuilt = list([entry("a", key: nil, tier: .review), entry("b", key: nil, tier: .review), entry("c", key: nil, tier: .review)])
        check(tiers.apply(to: rebuilt).entries[1].tier == .obsolete, "survives rebuild")
        check(tiers.apply(to: rebuilt).entries[2].tier == .review)
        tiers.reset()
        check(tiers.apply(to: rebuilt).entries.allSatisfy { $0.tier == .review }, "reset clears session tiers")

        // 重建后条目变成锁定 / 安全降级：会话换档不得抬高
        tiers.set(id: "x", tier: .obsolete); tiers.set(id: "y", tier: .obsolete)
        let guarded = tiers.apply(to: list([entry("x", key: nil, tier: .locked), entry("y", key: nil, tier: .review, hold: true)])).entries
        check(guarded[0].tier == .locked && guarded[0].selectable == false, "locked stays locked")
        check(guarded[1].tier == .review && !guarded[1].defaultChecked, "held stays at review")
        var protected = entry("p", key: nil, tier: .review); protected.userProtected = true
        tiers.set(id: "p", tier: .obsolete)
        check(tiers.apply(to: list([protected])).entries[0].defaultChecked == false, "protected is never default-checked")
        print("CleanupSessionTiersTests ok")
    }
}
