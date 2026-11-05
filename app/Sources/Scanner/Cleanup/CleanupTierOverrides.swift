// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A user's (manual) or Roomy's (learned) decision to show a category in another tier.
/// Overrides only change presentation and default selection; they never grant cleanup authority.
struct CleanupTierOverride: Codable, Equatable {
    enum Origin: String, Codable { case manual, learned }
    let key: CleanupPreferenceKey
    let tier: CleanupTier
    let fromTier: CleanupTier
    let origin: Origin
    let reason: String
    let at: Date
    var keyID: String { key.id }
}

enum CleanupTierOverrides {
    /// `.locked` entries ("不能删") always win. Everything else is matched by `preferenceKey.id`.
    static func apply(_ entries: [CleanupEntry], overrides: [CleanupTierOverride]) -> [CleanupEntry] {
        guard !overrides.isEmpty else { return entries }
        var byID: [String: CleanupTierOverride] = [:]
        for override in overrides where override.tier != .locked { byID[override.keyID] = override }
        return entries.map { entry in
            // 安全降级的条目保持 C 档；覆盖记录仍保留，条件解除后才生效
            guard entry.tier != .locked, entry.safetyHold != true, let key = entry.preferenceKey, let override = byID[key.id] else { return entry }
            var result = entry
            result.tier = override.tier
            result.tierReason = override.origin == .manual ? "你调整过" : "Roomy 按你的习惯调整：" + override.reason
            // 同一个键可能先在可找回的动作下学到 A，后来变成不可撤回的动作：自动调整最多到 B，不默认勾选
            if override.origin == .learned, override.tier == .obsolete, !entry.reversible {
                result.tier = .rebuildable
                result.tierReason = "Roomy 按你的习惯调整：" + override.reason + "；找不回的内容最多自动调到可选清"
            }
            result.defaultChecked = result.tier == .obsolete && result.selectable && result.userProtected != true
            return result
        }
    }
}
