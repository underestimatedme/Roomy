// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// What a manual "move to tier X" request should do for one list entry.
enum CleanupTierMove: Equatable {
    /// The entry has a category key: persist a manual override (from the tier shown now).
    case remember(CleanupPreferenceKey, from: CleanupTier)
    /// No key: change only this entry for the current scan.
    case sessionOnly
    /// Already on the requested tier: nothing to write.
    case unchanged

    /// Locked entries and locked targets are refused; rows held at C for safety cannot be moved (an override
    /// would be written but never applied).
    static func decide(entry: CleanupEntry, to tier: CleanupTier) throws -> CleanupTierMove {
        guard entry.tier != .locked, tier != .locked else { throw failure(CleanupTierAdjustments.refusal) }
        guard entry.safetyHold != true else { throw failure(CleanupTierAdjustments.holdRefusal) }
        let shown = entry.tier ?? .review
        if shown == tier { return .unchanged }
        if let key = entry.preferenceKey { return .remember(key, from: shown) }
        return .sessionOnly
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "RoomyTier", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Tier changes for entries without a category key. Kept per entry id for the current scan: re-applied whenever the
/// list is rebuilt, dropped on `reset()`. Locked and safety-held rows are never touched.
struct CleanupSessionTiers {
    private(set) var tiers: [String: CleanupTier] = [:]

    mutating func reset() { tiers = [:] }
    mutating func set(id: String, tier: CleanupTier) { tiers[id] = tier }

    func apply(to list: CleanupList) -> CleanupList {
        guard !tiers.isEmpty else { return list }
        var result = list
        for i in result.candidates.indices {
            let entry = result.candidates[i].entry
            guard let tier = tiers[entry.id], tier != .locked, entry.tier != .locked, entry.safetyHold != true else { continue }
            result.candidates[i].entry.tier = tier
            result.candidates[i].entry.tierReason = "你调整过（仅本次扫描）"
            result.candidates[i].entry.defaultChecked = tier == .obsolete && entry.selectable && entry.userProtected != true
        }
        return result
    }
}
