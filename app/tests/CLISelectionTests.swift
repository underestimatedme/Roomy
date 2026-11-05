// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct CLISelectionTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-cli-selection-" + UUID().uuidString
        try fm.createDirectory(atPath: root + "/cache", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let path = root + "/cache/item"
        try Data("original".utf8).write(to: URL(fileURLWithPath: path))
        func snapshot() -> CleanupList {
            let item = ScanItem.trashTarget(path: path, name: "sample", size: 8, rule: "fixture", evidence: "fixture", risk: .green)
            return CleanupList(candidates: [CleanupCandidate(source: "fixture", key: path, title: "sample", size: 8, evidence: "fixture", risk: .green, action: .trash(item: item), tier: .rebuildable, tierReason: "fixture tier proof")])
        }
        let native = snapshot()
        let scoped = CLISelection.scoped(native).entries[0]
        precondition(scoped.tier == .rebuildable && scoped.tierReason == "fixture tier proof", "CLI must preserve tier evidence")
        let before = CLISelection.scoped(native).entries[0].id
        try fm.moveItem(atPath: path, toPath: root + "/original")
        try Data("replaced".utf8).write(to: URL(fileURLWithPath: path))
        precondition(CLISelection.scoped(snapshot()).entries[0].id != before, "old CLI preview must not authorize a replacement")
        let current = snapshot(), leaf = CLISelection.scoped(current).entries[0].id
        try fm.moveItem(atPath: root + "/cache", toPath: root + "/old-cache")
        try fm.createDirectory(atPath: root + "/cache", withIntermediateDirectories: true)
        try fm.moveItem(atPath: root + "/old-cache/item", toPath: path)
        precondition(CLISelection.scoped(snapshot()).entries[0].id != leaf, "replacement parent must invalidate CLI ID even with preserved leaf")
        let a = CLISelection.scoped(snapshot(), context: "original app identity").entries[0].id
        let b = CLISelection.scoped(snapshot(), context: "replacement app identity").entries[0].id
        precondition(a != b, "app identity must bind association selection")
        let opaque = CleanupCandidate(source: "fixture", key: "docker", title: "docker", size: 1, evidence: "fixture", risk: .amber, action: .dockerRemove(kind: .volume, id: "v1"))
        precondition(CLISelection.scoped(CleanupList(candidates: [opaque])).entries[0].selectable, "CLI JSON advertises irreversible tool actions as executable (separate DELETE confirmation)")
        let lockedOpaque = opaque.locked("正被进程使用")
        let scopedLocked = CLISelection.scoped(CleanupList(candidates: [lockedOpaque])).entries[0]
        precondition(!scopedLocked.selectable && scopedLocked.tier == .locked, "locked entries stay non-selectable in the CLI")
        // 安全降级（safetyHold）和锁定原因必须穿过 CLI 的 scoped：否则 CLI 会把它当普通 C 行，手动 A 覆盖会生效
        let key = CleanupPreferenceKey(owner: "fixture", kind: "path", scope: CleanupPreferenceKey.digest(path))
        let base = snapshot()
        var keyed = base.candidates[0]; keyed.entry.preferenceKey = key; keyed.entry.lockReason = "fixture lock reason"
        let held = keyed.requiringReview(RunningOwners.unverifiedReason)
        let heldScoped = CLISelection.scoped(CleanupList(candidates: [held])).entries[0]
        precondition(heldScoped.safetyHold == true, "CLI scoped must keep safetyHold: \(String(describing: heldScoped.safetyHold))")
        precondition(heldScoped.lockReason == "fixture lock reason", "CLI scoped must keep lockReason")
        let prefs = root + "/prefs"
        try fm.createDirectory(atPath: prefs, withIntermediateDirectories: true)
        let store = CleanupPreferenceStore(directory: URL(fileURLWithPath: prefs))
        try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "fixture", now: Date())
        let decorated = CleanupPreferenceLearning(store: store, source: .cli).decorate([heldScoped])[0]
        precondition(decorated.tier == .review && !decorated.defaultChecked, "held row stays C without default check in the CLI: \(String(describing: decorated.tier))")
        do { _ = try CleanupTierMove.decide(entry: decorated, to: .obsolete); preconditionFailure("tier set must refuse a held row") }
        catch { precondition(error.localizedDescription == CleanupTierAdjustments.holdRefusal, error.localizedDescription) }
        print("CLI stale selection protection ok")
    }
}
