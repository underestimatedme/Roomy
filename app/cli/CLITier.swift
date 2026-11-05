// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// `roomy tier ...`: list, set, undo and reset tier adjustments. Mutations are previews unless `apply` is true,
/// and only then call `prepare` (global lease) and `confirm` (terminal confirmation).
enum CLITier {
    static func parseTier(_ text: String) throws -> CleanupTier {
        guard let tier = CleanupTierAdjustments.tier(letter: text) else { throw cliError("档位只能是 A、B、C") }
        return tier
    }

    private static func line(_ row: [String: Any]) -> String {
        let at = (row["at"] as? String).map { "  " + $0 } ?? ""
        return "\(row["keyID"] as? String ?? "")  \(cliSafeText(row["label"] as? String ?? ""))  "
            + "\(row["fromTierLetter"] as? String ?? "") \(row["fromTierTitle"] as? String ?? "") → "
            + "\(row["tierLetter"] as? String ?? "") \(row["tierTitle"] as? String ?? "")  \(row["originText"] as? String ?? "")"
            + "\n  依据：\(cliSafeText(row["reason"] as? String ?? ""))\(at)"
    }

    static func list(store: CleanupPreferenceStore, titles: [String: String] = [:]) throws -> CLIResponse {
        let snapshot = try store.snapshot()
        let payload = CleanupTierAdjustments.payload(snapshot, titles: titles)
        let overrides = payload["overrides"] as? [[String: Any]] ?? [], history = payload["history"] as? [[String: Any]] ?? []
        var text = overrides.isEmpty ? "还没有档位调整。" : "档位调整（\(overrides.count) 项）：\n" + overrides.map(line).joined(separator: "\n")
        if !history.isEmpty { text += "\n\n最近记录（新的在前）：\n" + history.suffix(20).reversed().map(line).joined(separator: "\n") }
        return CLIResponse(data: payload, text: text)
    }

    private static func finish(_ message: String, data: [String: Any], apply: Bool, prepare: () throws -> Void,
                               confirm: (String) throws -> Void, action: () throws -> Void) throws -> CLIResponse {
        guard apply else {
            var preview = data; preview["executionAuthorized"] = false
            return CLIResponse(data: preview, text: message + "\n未执行；添加 --apply 执行。")
        }
        try prepare()
        try confirm(message)
        try action()
        var done = data; done["executionAuthorized"] = true
        return CLIResponse(data: done, text: "已完成：" + message)
    }

    static func set(entry: CleanupEntry, tier: CleanupTier, apply: Bool, store: CleanupPreferenceStore,
                    prepare: () throws -> Void, confirm: (String) throws -> Void) throws -> CLIResponse {
        let from = entry.tier ?? .review
        let key: CleanupPreferenceKey
        switch try CleanupTierMove.decide(entry: entry, to: tier) {
        case .unchanged:
            return CLIResponse(data: ["executionAuthorized": false, "unchanged": true], text: CleanupTierAdjustments.unchangedNotice + "：" + cliSafeText(entry.title))
        case .sessionOnly:
            throw cliError("这个项目没有可记住的类别，不能换档")
        case .remember(let remembered, _):
            key = remembered
        }
        let message = "将「\(cliSafeText(entry.title))」从 \(CleanupTierAdjustments.letter(from)) \(from.title) 调到 \(CleanupTierAdjustments.letter(tier)) \(tier.title)；之后同类项目都按这一档显示。"
        return try finish(message, data: ["keyID": key.id, "tier": tier.rawValue, "fromTier": from.rawValue], apply: apply,
                          prepare: prepare, confirm: confirm) {
            try store.setTier(key: key, tier: tier, from: from, origin: .manual, reason: "你调整过")
        }
    }

    static func undo(keyID: String, apply: Bool, store: CleanupPreferenceStore,
                     prepare: () throws -> Void, confirm: (String) throws -> Void) throws -> CLIResponse {
        guard let current = try store.snapshot().overrides.first(where: { $0.keyID == keyID }) else { throw cliError("没有这条档位调整，先用 roomy tier list 查看") }
        let target = current.origin == .learned ? "固定在原来的 \(current.fromTier.title)" : "恢复为默认档位"
        let message = "撤销 \(cliSafeText(CleanupTierAdjustments.label(current.key)))（\(current.fromTier.title) → \(current.tier.title)，\(CleanupTierAdjustments.originText(current.origin))）：\(target)。"
        return try finish(message, data: ["keyID": keyID], apply: apply, prepare: prepare, confirm: confirm) {
            try store.undoOverride(keyID: keyID)
        }
    }

    static func reset(apply: Bool, store: CleanupPreferenceStore,
                      prepare: () throws -> Void, confirm: (String) throws -> Void) throws -> CLIResponse {
        let manual = try store.snapshot().overrides.filter { $0.origin == .manual }
        if manual.isEmpty { return CLIResponse(data: ["count": 0, "executionAuthorized": false], text: "没有手动调整可重置。") }
        let message = "重置全部 \(manual.count) 条手动调整，回到默认档位；Roomy 按你的习惯做的调整保留。"
        return try finish(message, data: ["count": manual.count], apply: apply, prepare: prepare, confirm: confirm) {
            try store.resetManualOverrides()
        }
    }
}
