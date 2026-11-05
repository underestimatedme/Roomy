// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Moves categories between tiers from the user's own manual cleanup habits.
/// Pure policy: it reads a snapshot and returns learned overrides; the store enforces manual-wins and generation.
enum CleanupTierLearning {
    static let minimumDays = 3

    static func changes(snapshot: CleanupPreferenceSnapshot, entries: [CleanupEntry], now: Date) -> [CleanupTierOverride] {
        guard snapshot.enabled else { return [] }
        let events = CleanupPreferencePolicy.current(snapshot.events, now: now)
        let eventsByKey = Dictionary(grouping: events.filter { $0.key != nil }) { $0.key!.id }
        var overrideByKey: [String: CleanupTierOverride] = [:]
        for override in snapshot.overrides { overrideByKey[override.keyID] = override }
        // The latest set or undo for a key: evidence older than it has already been acted on.
        var lastChange: [String: Date] = [:]
        for change in snapshot.overrides + snapshot.tierHistory {
            lastChange[change.keyID] = max(lastChange[change.keyID] ?? .distantPast, change.at)
        }

        // Rows as the user sees them now (overrides applied; idempotent if the caller already decorated).
        var groups: [String: [CleanupEntry]] = [:]
        var order: [String] = []
        for entry in CleanupTierOverrides.apply(entries, overrides: snapshot.overrides) {
            guard let key = entry.preferenceKey else { continue }
            if groups[key.id] == nil { order.append(key.id) }
            groups[key.id, default: []].append(entry)
        }

        var result: [CleanupTierOverride] = []
        for id in order {
            guard overrideByKey[id]?.origin != .manual, let rows = groups[id], let key = rows.first?.preferenceKey else { continue }
            let tiers = Set(rows.map { $0.tier ?? .review })
            // "不能删" and safety-held rows never move; rows of one key that disagree are left alone.
            guard tiers.count == 1, let tier = tiers.first, tier != .locked,
                  !rows.contains(where: { $0.safetyHold == true }) else { continue }
            let decision = decide(tier: tier, events: eventsByKey[id] ?? [], since: lastChange[id] ?? .distantPast,
                                  irreversibleNow: rows.contains { !$0.reversible })
            if let decision {
                result.append(.init(key: key, tier: decision.tier, fromTier: tier, origin: .learned, reason: decision.reason, at: now))
            }
        }
        // A restored key whose rows are not in this list (rescanned away, or CLI restore) still steps down: from its
        // learned tier, or else from the tier the user saw when cleaning it. Manual keys are the user's decision.
        for id in eventsByKey.keys.sorted() where groups[id] == nil && overrideByKey[id]?.origin != .manual {
            let since = lastChange[id] ?? .distantPast
            guard let latest = restoredEvents(eventsByKey[id] ?? [], since: since).max(by: { $0.restoredAt! < $1.restoredAt! }),
                  let key = latest.key else { continue }
            let learned = overrideByKey[id]
            guard let from = learned?.tier ?? latest.tier, let lower = from.lowered else { continue }
            result.append(.init(key: learned?.key ?? key, tier: lower, fromTier: from, origin: .learned,
                                reason: "你恢复过这一类内容", at: now))
        }
        return result
    }

    /// Restores that may move a tier: newer than the key's latest change and recorded after tiers existed.
    /// Older (tierless) restores still block promotion, but never trigger a change on their own.
    private static func restoredEvents(_ events: [CleanupPreferenceEvent], since: Date) -> [CleanupPreferenceEvent] {
        events.filter { $0.tier != nil && ($0.restoredAt ?? .distantPast) > since }
    }

    /// At most one step per call. Restore and declined (moving down) take precedence over promotion.
    private static func decide(tier: CleanupTier, events: [CleanupPreferenceEvent], since: Date,
                               irreversibleNow: Bool) -> CleanupTierDecision? {
        if !restoredEvents(events, since: since).isEmpty, let lower = tier.lowered {
            return .init(tier: lower, reason: "你恢复过这一类内容")
        }
        if tier == .obsolete {
            let days = Set(events.filter { $0.kind == .declined && $0.tier == .obsolete && $0.revokedAt == nil && $0.at > since }
                .map(\.localDay)).count
            return days >= minimumDays ? .init(tier: .rebuildable, reason: "你 \(days) 次取消勾选这一项") : nil
        }
        // Promotion: no restore in the window, no active protection.
        guard !events.contains(where: { $0.restoredAt != nil || ($0.kind == .protection && $0.revokedAt == nil) }),
              let higher = tier.raised else { return nil }
        let deletions = events.filter { $0.kind == .deletion }
        let revokedBatches = Set(deletions.filter { $0.revokedAt != nil }.map(\.batchID))
        let eligible = deletions.filter {
            $0.revokedAt == nil && !revokedBatches.contains($0.batchID) && $0.at > since
                && ($0.tier == .review || $0.tier == .rebuildable)
        }
        let days = Set(eligible.map(\.localDay)).count
        guard days >= minimumDays else { return nil }
        if higher == .obsolete {
            // Content that cannot be recovered never becomes default-checked by learning.
            let latest = deletions.filter { $0.tier != nil }.max { $0.at < $1.at }
            if irreversibleNow || latest?.reversible == false || eligible.contains(where: { $0.reversible == false }) { return nil }
        }
        return .init(tier: higher, reason: "近 90 天你在 \(days) 个不同日期清理过同类内容")
    }
}

private extension CleanupTier {
    /// C → B → A. `.locked` never moves.
    var raised: CleanupTier? {
        switch self {
        case .review: return .rebuildable
        case .rebuildable: return .obsolete
        case .obsolete, .locked: return nil
        }
    }

    /// A → B → C. Learning never moves anything into `.locked`.
    var lowered: CleanupTier? {
        switch self {
        case .obsolete: return .rebuildable
        case .rebuildable: return .review
        case .review, .locked: return nil
        }
    }
}
