// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Presentation of tier overrides for the settings page and the CLI. Pure formatting: it never changes a tier.
enum CleanupTierAdjustments {
    static let refusal = "不能删的项目不能换档"
    static let holdRefusal = "这一项因安全原因暂时保持在“确认后清”，不能换档"
    static let unchangedNotice = "已经在这一档"

    /// A/B/C map to obsolete/rebuildable/review. `.locked` is never a valid target.
    static func tier(letter: String) -> CleanupTier? {
        switch letter.uppercased() {
        case "A": return .obsolete
        case "B": return .rebuildable
        case "C": return .review
        default: return nil
        }
    }

    static func letter(_ tier: CleanupTier) -> String {
        switch tier {
        case .obsolete: return "A"
        case .rebuildable: return "B"
        case .review: return "C"
        case .locked: return "-"
        }
    }

    static func originText(_ origin: CleanupTierOverride.Origin) -> String {
        origin == .manual ? "你调整过" : "Roomy 按你的习惯调整"
    }

    /// `titles` maps preference key ids to the title of a current list entry; otherwise the key's owner and kind are shown.
    static func label(_ key: CleanupPreferenceKey, titles: [String: String] = [:]) -> String {
        if let title = titles[key.id], !title.isEmpty { return title }
        let owner = key.owner.hasPrefix("tool:") ? String(key.owner.dropFirst(5)) : key.owner
        return owner + " · " + key.kind
    }

    static func row(_ override: CleanupTierOverride, titles: [String: String] = [:]) -> [String: Any] {
        ["keyID": override.keyID, "label": label(override.key, titles: titles),
         "tier": override.tier.rawValue, "tierTitle": override.tier.title, "tierLetter": letter(override.tier),
         "fromTier": override.fromTier.rawValue, "fromTierTitle": override.fromTier.title, "fromTierLetter": letter(override.fromTier),
         "origin": override.origin.rawValue, "originText": originText(override.origin), "reason": override.reason,
         "at": ISO8601DateFormatter().string(from: override.at)]
    }

    /// Current adjustments plus the recent history (newest last, as stored).
    static func payload(_ snapshot: CleanupPreferenceSnapshot, titles: [String: String] = [:]) -> [String: Any] {
        ["overrides": snapshot.overrides.map { row($0, titles: titles) },
         "history": snapshot.tierHistory.map { row($0, titles: titles) }]
    }

    static func titles(of entries: [CleanupEntry]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries { if let key = entry.preferenceKey, result[key.id] == nil { result[key.id] = entry.title } }
        return result
    }
}
