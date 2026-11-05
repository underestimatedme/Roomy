// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct CleanupTierTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func item(_ rule: String, age: Int = 120, undo: Bool = true,
                  proof: CleanupEvidenceSnapshot? = nil) -> ScanItem {
            ScanItem(name: "sample", path: "/sample/cache", size: 10, atimeDays: nil,
                mtimeDays: age, rule: rule, evidence: "sample", risk: .green, gentle: nil,
                hard: "移到废纸篓", undo: undo, note: "", rebuild: .free, cleanupEvidence: proof)
        }
        func candidate(_ tier: CleanupTier = .review, risk: Risk = .green) -> CleanupCandidate {
            CleanupCandidate(source: "rule", key: "sample", title: "sample", size: 10,
                evidence: "proof", risk: risk, action: .trash(item: item("sample")),
                tier: tier, tierReason: "classified proof")
        }
        precondition(!candidate().entry.defaultChecked, "green alone cannot preselect unknown content")
        precondition(candidate(.obsolete).entry.defaultChecked)
        precondition(!candidate(.rebuildable).entry.defaultChecked, "useful caches require explicit selection")
        precondition(candidate(.obsolete, risk: .amber).entry.defaultChecked, "A 档即使 amber 也默认勾选")
        let irreversible = CleanupCandidate(source: "runtime", key: "runtime", title: "runtime", size: 10,
            evidence: "proof", risk: .green, action: .simctlDeleteRuntime(id: "runtime"), tier: .obsolete)
        precondition(irreversible.entry.defaultChecked, "A 档不可撤回项也默认勾选")

        precondition(CleanupTier.locked.title == "不能删" && CleanupTier.obsolete.title == "放心清")
        precondition(CleanupTier.rebuildable.title == "可选清" && CleanupTier.review.title == "确认后清")
        let locked = candidate(.obsolete).locked("Xcode 正在运行，关闭后重新扫描").entry
        precondition(locked.tier == .locked && !locked.selectable && !locked.defaultChecked && locked.lockReason == "Xcode 正在运行，关闭后重新扫描")
        precondition(candidate(.obsolete).locked("x").action == nil && locked.actionLabel == "")
        let moved = candidate(.review).retiered(.obsolete, reason: "你调整过").entry
        precondition(moved.tier == .obsolete && moved.defaultChecked && moved.tierReason == "你调整过")
        precondition(!candidate(.obsolete).retiered(.rebuildable, reason: "x").entry.defaultChecked)
        let lockedByRetier = candidate(.obsolete).retiered(.locked, reason: "占用").entry
        precondition(lockedByRetier.tier == .locked && !lockedByRetier.selectable && !lockedByRetier.defaultChecked)
        let unknown = try JSONDecoder().decode(CleanupTier.self, from: Data("\"weird\"".utf8))
        precondition(unknown == .review)

        var original = candidate(.obsolete)
        original.entry.category = "devcache"; original.entry.group = "group"
        original.entry.userProtected = true; original.entry.path = "/sample/cache"
        let sized = original.withSize(20).entry
        precondition(sized.tier == .obsolete && sized.tierReason == "classified proof")
        precondition(sized.category == "devcache" && sized.group == "group" && sized.userProtected == true)
        precondition(sized.path == "/sample/cache")
        original.entry.lockReason = "keep"
        precondition(original.withSize(20).entry.lockReason == "keep" && original.requiringReview("r").entry.lockReason == "keep")
        precondition(original.retiered(.rebuildable, reason: "r").entry.lockReason == "keep")
        precondition(original.retiered(.rebuildable, reason: "r").entry.group == "group" && original.retiered(.rebuildable, reason: "r").entry.userProtected == true)
        let review = original.requiringReview("正在使用").entry
        precondition(review.tier == .review && !review.defaultChecked)
        precondition(review.category == "devcache" && review.path == original.entry.path && review.userProtected == true)

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let roundTrip = try decoder.decode(CleanupEntry.self, from: encoder.encode(sized))
        precondition(roundTrip == sized)
        var json = try JSONSerialization.jsonObject(with: encoder.encode(sized)) as! [String: Any]
        precondition(json["lockReason"] == nil, "nil lockReason is omitted when encoding")
        json.removeValue(forKey: "tier"); json.removeValue(forKey: "tierReason")
        let legacy = try decoder.decode(CleanupEntry.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(legacy.tier == nil)
        json["tier"] = "future-value"
        let future = try decoder.decode(CleanupEntry.self, from: JSONSerialization.data(withJSONObject: json))
        precondition(future.tier == .review)

        for rule in ["包管理器缓存", "Maven 仓库", "Go 构建缓存", "Go 模块缓存", "自动更新残留", "安装临时目录", "JetBrains 旧版本缓存与日志"] {
            precondition(CleanupTierPolicy.forRule(item(rule), now: now).tier == .review,
                "a rule name and root age cannot establish complete content or inactivity: \(rule)")
        }
        precondition(CleanupTierPolicy.forRule(item("Roomy 旧扫描快照"), now: now).tier == .obsolete)
        precondition(CleanupTierPolicy.forRule(item("unknown"), now: now).tier == .review)
        precondition(CleanupTierPolicy.forRule(item("Gradle 缓存", undo: false), now: now).tier == .review)
        precondition(CleanupTierPolicy.forRule(item("Codex 会话"), now: now).tier == .review)
        precondition(CleanupTierPolicy.forRule(item("Xcode DerivedData"), now: now).tier == .review,
            "root mtime and rule names cannot prove that a mixed parent is obsolete")
        let oldProof = CleanupEvidenceSnapshot(version: 1, fingerprint: "old", kind: "xcodeGenerated",
            newestModifiedAt: Int64(now.timeIntervalSince1970) - 91 * 86400)
        let recentProof = CleanupEvidenceSnapshot(version: 1, fingerprint: "new", kind: "xcodeGenerated",
            newestModifiedAt: Int64(now.timeIntervalSince1970) - 86400)
        precondition(CleanupTierPolicy.forRule(item("Xcode 生成缓存", proof: oldProof), now: now).tier == .obsolete)
        precondition(CleanupTierPolicy.forRule(item("Xcode 生成缓存", age: 900, proof: recentProof), now: now).tier == .rebuildable,
            "complete-tree activity overrides an old root timestamp")
        precondition(CleanupTierPolicy.forRule(item("Xcode 生成缓存", proof: .init(version: 1, fingerprint: "legacy")), now: now).tier == .review)
        print("CleanupTierTests passed: independent defaults, conservative JSON, rule evidence and metadata preservation")
    }
}
