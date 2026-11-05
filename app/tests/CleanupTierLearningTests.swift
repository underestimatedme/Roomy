// SPDX-License-Identifier: MPL-2.0
import Foundation

private func check(_ value: Bool, _ message: String = "", line: UInt = #line) {
    precondition(value, "line \(line): \(message)")
}

@main struct CleanupTierLearningTests {
    static let now = Date()
    /// Noon of yesterday (local): always before `now`, and minutes either side stay on the same local date.
    static let base = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now.addingTimeInterval(-86400))!
    static let key = CleanupPreferenceKey(owner: "tool:npmCache", kind: "tool-cache", scope: CleanupPreferenceKey.digest("/fixture/.npm"))
    static let other = CleanupPreferenceKey(owner: "docker", kind: "volume", scope: CleanupPreferenceKey.digest("old-db"))

    static func entry(_ id: String, key: CleanupPreferenceKey?, tier: CleanupTier, reversible: Bool = true) -> CleanupEntry {
        let selectable = tier != .locked
        var e = CleanupEntry(id: id, title: id, size: 10, estimateIsApprox: false, evidence: "fixture", actionLabel: "进废纸篓",
            reversible: reversible, risk: .amber, selectable: selectable, defaultChecked: tier == .obsolete && selectable, source: "rule")
        e.tier = tier; e.tierReason = "出厂"; e.preferenceKey = key
        return e
    }

    /// `days` are spread 2 days apart from `base` so local dates never collide; `minutesEarlier` stays on the same date.
    static func deletions(_ key: CleanupPreferenceKey, days: [Int], tier: CleanupTier? = .review, reversible: Bool? = true,
                          minutesEarlier: Double = 0) -> [CleanupPreferenceEvent] {
        days.map { day in
            let batch = CleanupPreferenceBatch(id: UUID().uuidString, generation: "g")
            return CleanupPreferenceEvent.deletion(batch: batch, candidateID: "c-\(day)", title: "npm", path: nil, key: key,
                at: base.addingTimeInterval(-Double(day) * 2 * 86400 - minutesEarlier * 60), tier: tier, reversible: reversible)
        }
    }

    static func declines(_ key: CleanupPreferenceKey, days: [Int]) -> [CleanupPreferenceEvent] {
        days.map { day in
            CleanupPreferenceEvent.declined(batch: .init(id: UUID().uuidString, generation: "g"), key: key, title: "npm", path: nil,
                at: base.addingTimeInterval(-Double(day) * 2 * 86400))
        }
    }

    static func snapshot(_ events: [CleanupPreferenceEvent], overrides: [CleanupTierOverride] = []) -> CleanupPreferenceSnapshot {
        var s = CleanupPreferenceSnapshot(); s.events = events; s.overrides = overrides; s.tierHistory = overrides
        return s
    }

    static func main() throws {
        // promotesAfterThreeDays
        do {
            let changes = CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3])),
                                                      entries: [entry("a", key: key, tier: .review)], now: now)
            check(changes.count == 1, "\(changes)")
            check(changes.first?.tier == .rebuildable && changes.first?.fromTier == .review && changes.first?.origin == .learned)
            check(changes.first?.key == key)
            check(changes.first?.reason == "近 90 天你在 3 个不同日期清理过同类内容", changes.first?.reason ?? "nil")
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2])),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty, "2 days is not enough")
            // B → A for reversible content, one step only
            let b = CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3, 4], tier: .rebuildable)),
                                                entries: [entry("a", key: key, tier: .rebuildable)], now: now)
            check(b.count == 1 && b[0].tier == .obsolete && b[0].reason.contains("4 个不同日期"), "\(b)")
            // already A: nothing to promote
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3])),
                                              entries: [entry("a", key: key, tier: .obsolete)], now: now).isEmpty)
            // events older than the 90-day window do not count
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 50])),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty, "window")
            // learning off → nothing
            var off = snapshot(deletions(key, days: [1, 2, 3])); off.enabled = false
            check(CleanupTierLearning.changes(snapshot: off, entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
            // a row with a safety hold is never raised
            var held = entry("a", key: key, tier: .review); held.safetyHold = true
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3])), entries: [held], now: now).isEmpty)
            // an effective protection blocks promotion
            var protected = snapshot(deletions(key, days: [1, 2, 3]))
            protected.events.append(.init(id: "p", batchID: "pb", candidateID: "a", title: "npm", path: nil, key: key,
                                          kind: .protection, at: now.addingTimeInterval(-60), localDay: ""))
            check(CleanupTierLearning.changes(snapshot: protected, entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
            // a restored batch no longer counts (revoked) and blocks promotion
            var restored = snapshot(deletions(key, days: [1, 2, 3, 4]))
            restored.events[0].revokedAt = now.addingTimeInterval(-60); restored.events[0].restoredAt = now.addingTimeInterval(-60)
            let r = CleanupTierLearning.changes(snapshot: restored, entries: [entry("a", key: key, tier: .review)], now: now)
            check(r.allSatisfy { $0.tier != .rebuildable }, "restore blocks promotion: \(r)")
            // events recorded before this key's latest tier change do not promote it again
            let learned = CleanupTierOverride(key: key, tier: .rebuildable, fromTier: .review, origin: .learned,
                                              reason: "x", at: now.addingTimeInterval(-60))
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3]), overrides: [learned]),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty, "no cascade")
        }

        // sameDayCountsOnce
        do {
            let sameDay = deletions(key, days: [1, 1, 1]) + deletions(key, days: [1], minutesEarlier: 90)
            check(CleanupTierLearning.changes(snapshot: snapshot(sameDay), entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
            let twoDays = sameDay + deletions(key, days: [2])
            check(CleanupTierLearning.changes(snapshot: snapshot(twoDays), entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
        }

        // irreversibleCapsAtB
        do {
            let events = deletions(key, days: [1, 2, 3], tier: .rebuildable, reversible: false)
            check(CleanupTierLearning.changes(snapshot: snapshot(events),
                                              entries: [entry("a", key: key, tier: .rebuildable, reversible: false)], now: now).isEmpty)
            // current row irreversible even if events are not
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3], tier: .rebuildable)),
                                              entries: [entry("a", key: key, tier: .rebuildable, reversible: false)], now: now).isEmpty)
            // latest event irreversible even if the row is reversible
            check(CleanupTierLearning.changes(snapshot: snapshot(events),
                                              entries: [entry("a", key: key, tier: .rebuildable)], now: now).isEmpty)
            // C → B is still allowed for irreversible content
            let c = CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3], reversible: false)),
                                                entries: [entry("a", key: key, tier: .review, reversible: false)], now: now)
            check(c.count == 1 && c[0].tier == .rebuildable, "\(c)")
        }

        // declinedDemotes
        do {
            let d = CleanupTierLearning.changes(snapshot: snapshot(declines(key, days: [1, 2, 3])),
                                                entries: [entry("a", key: key, tier: .obsolete)], now: now)
            check(d.count == 1 && d[0].tier == .rebuildable && d[0].fromTier == .obsolete, "\(d)")
            check(d[0].reason == "你 3 次取消勾选这一项", d[0].reason)
            check(CleanupTierLearning.changes(snapshot: snapshot(declines(key, days: [1, 2])),
                                              entries: [entry("a", key: key, tier: .obsolete)], now: now).isEmpty)
            check(CleanupTierLearning.changes(snapshot: snapshot(declines(key, days: [1, 2, 3])),
                                              entries: [entry("a", key: key, tier: .rebuildable)], now: now).isEmpty, "only A demotes")
            // a learned A from an earlier promotion is demoted the same way
            let learned = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .rebuildable, origin: .learned,
                                              reason: "x", at: now.addingTimeInterval(-30 * 86400))
            let viaOverride = CleanupTierLearning.changes(snapshot: snapshot(declines(key, days: [1, 2, 3]), overrides: [learned]),
                                                          entries: [entry("a", key: key, tier: .rebuildable)], now: now)
            check(viaOverride.count == 1 && viaOverride[0].tier == .rebuildable, "\(viaOverride)")
        }

        // restoreDemotes
        do {
            var events = deletions(key, days: [1])
            events[0].revokedAt = now.addingTimeInterval(-60); events[0].restoredAt = now.addingTimeInterval(-60)
            let a = CleanupTierLearning.changes(snapshot: snapshot(events), entries: [entry("a", key: key, tier: .obsolete)], now: now)
            check(a.count == 1 && a[0].tier == .rebuildable && a[0].reason == "你恢复过这一类内容", "\(a)")
            let b = CleanupTierLearning.changes(snapshot: snapshot(events), entries: [entry("a", key: key, tier: .rebuildable)], now: now)
            check(b.count == 1 && b[0].tier == .review, "\(b)")
            check(CleanupTierLearning.changes(snapshot: snapshot(events), entries: [entry("a", key: key, tier: .review)], now: now).isEmpty,
                  "nothing below C")
            // a restore older than the key's latest change was already handled
            let after = CleanupTierOverride(key: key, tier: .rebuildable, fromTier: .obsolete, origin: .learned, reason: "x", at: now.addingTimeInterval(-30))
            check(CleanupTierLearning.changes(snapshot: snapshot(events, overrides: [after]),
                                              entries: [entry("a", key: key, tier: .obsolete)], now: now).isEmpty)
            // a learned override whose row is not in this list (CLI restore) still moves down
            let before = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .rebuildable, origin: .learned, reason: "x",
                                             at: now.addingTimeInterval(-10 * 86400))
            let absent = CleanupTierLearning.changes(snapshot: snapshot(events, overrides: [before]), entries: [], now: now)
            check(absent.count == 1 && absent[0].tier == .rebuildable && absent[0].key == key, "\(absent)")
            // A restored key that was never overridden and is not in this list (rescanned or CLI restore) starts from
            // the tier recorded on the restored event.
            var factoryA = deletions(key, days: [1], tier: .obsolete)
            factoryA[0].revokedAt = now.addingTimeInterval(-60); factoryA[0].restoredAt = now.addingTimeInterval(-60)
            let fromEvent = CleanupTierLearning.changes(snapshot: snapshot(factoryA), entries: [], now: now)
            check(fromEvent.count == 1 && fromEvent[0].tier == .rebuildable && fromEvent[0].fromTier == .obsolete
                  && fromEvent[0].key == key && fromEvent[0].reason == "你恢复过这一类内容", "\(fromEvent)")
            let manualKept = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .review, origin: .manual, reason: "r",
                                                 at: now.addingTimeInterval(-60 * 86400))
            check(CleanupTierLearning.changes(snapshot: snapshot(factoryA, overrides: [manualKept]), entries: [], now: now).isEmpty)
            var off = snapshot(factoryA); off.enabled = false
            check(CleanupTierLearning.changes(snapshot: off, entries: [], now: now).isEmpty)
            var factoryC = factoryA; factoryC[0].tier = .review
            check(CleanupTierLearning.changes(snapshot: snapshot(factoryC), entries: [], now: now).isEmpty, "nothing below C")
            // Pre-upgrade (tierless) restores never move tiers, but still block promotion.
            var legacy = deletions(key, days: [1], tier: nil, reversible: nil)
            legacy[0].revokedAt = now.addingTimeInterval(-60); legacy[0].restoredAt = now.addingTimeInterval(-60)
            check(CleanupTierLearning.changes(snapshot: snapshot(legacy), entries: [entry("a", key: key, tier: .obsolete)], now: now).isEmpty)
            check(CleanupTierLearning.changes(snapshot: snapshot(legacy), entries: [], now: now).isEmpty)
            let legacyLearned = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .rebuildable, origin: .learned, reason: "x",
                                                    at: now.addingTimeInterval(-10 * 86400))
            check(CleanupTierLearning.changes(snapshot: snapshot(legacy, overrides: [legacyLearned]), entries: [], now: now).isEmpty)
            check(CleanupTierLearning.changes(snapshot: snapshot(legacy + deletions(key, days: [2, 3, 4])),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty, "old restore blocks promotion")
        }

        // manualBlocks
        do {
            let manual = CleanupTierOverride(key: key, tier: .review, fromTier: .review, origin: .manual, reason: "撤销习惯调整",
                                             at: now.addingTimeInterval(-60 * 86400))
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3]), overrides: [manual]),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
            var restored = deletions(key, days: [1]); restored[0].restoredAt = now.addingTimeInterval(-60); restored[0].revokedAt = now.addingTimeInterval(-60)
            let manualA = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .review, origin: .manual, reason: "r",
                                              at: now.addingTimeInterval(-60 * 86400))
            check(CleanupTierLearning.changes(snapshot: snapshot(restored + declines(key, days: [2, 3, 4]), overrides: [manualA]),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
            // other keys are unaffected by this key's manual override
            let o = CleanupTierLearning.changes(snapshot: snapshot(deletions(other, days: [1, 2, 3]), overrides: [manual]),
                                                entries: [entry("a", key: key, tier: .review), entry("b", key: other, tier: .review)], now: now)
            check(o.count == 1 && o[0].key == other)
        }

        // legacyEventsIgnored
        do {
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3, 4, 5], tier: nil, reversible: nil)),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
            // a pre-upgrade JSON event decodes without tier/reversible
            let legacy = #"{"id":"x","batchID":"b","candidateID":"c","title":"t","key":{"owner":"o","kind":"k","scope":"s"},"kind":"deletion","at":0,"localDay":"2026-10-01"}"#
            let decoded = try JSONDecoder().decode(CleanupPreferenceEvent.self, from: Data(legacy.utf8))
            check(decoded.tier == nil && decoded.reversible == nil)
            // promotion still requires obsolete-free tiers: events recorded at A never promote
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3], tier: .obsolete)),
                                              entries: [entry("a", key: key, tier: .review)], now: now).isEmpty)
        }

        // lockedUnchanged
        do {
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3])),
                                              entries: [entry("a", key: key, tier: .locked)], now: now).isEmpty)
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3])),
                                              entries: [entry("a", key: key, tier: .review), entry("b", key: key, tier: .locked)], now: now).isEmpty,
                  "a locked row with the same key blocks the key")
            var restored = deletions(key, days: [1]); restored[0].restoredAt = now.addingTimeInterval(-60)
            check(CleanupTierLearning.changes(snapshot: snapshot(restored), entries: [entry("a", key: key, tier: .locked)], now: now).isEmpty)
            check(CleanupTierLearning.changes(snapshot: snapshot(deletions(key, days: [1, 2, 3])),
                                              entries: [entry("a", key: nil, tier: .review)], now: now).isEmpty, "keyless")
        }

        print("CleanupTierLearningTests passed")
    }
}
