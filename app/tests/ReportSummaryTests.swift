// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func entry(_ id: String, _ size: UInt64, path: String?, tier: CleanupTier, reversible: Bool,
                   selectable: Bool = true, approx: Bool = false, protected: Bool? = nil) -> CleanupEntry {
    var e = CleanupEntry(id: id, title: id, size: size, estimateIsApprox: approx, evidence: "fixture", actionLabel: "x",
                         reversible: reversible, risk: .green, selectable: selectable, defaultChecked: false, source: "test")
    e.path = path; e.tier = tier; e.userProtected = protected
    return e
}

@main
struct ReportSummaryTests {
    static func main() throws {
        func tier(_ s: ReportSummary, _ t: CleanupTier) -> ReportSummary.Tier { s.tiers.first { $0.key == t.rawValue }! }

        // 基本拆分：A 可找回 10 + 找不回 5，B 可找回 20；只有找不回的立刻释放
        let basic = ReportSummary.compute(entries: [
            entry("a1", 10, path: "/a", tier: .obsolete, reversible: true),
            entry("a2", 5, path: "/b", tier: .obsolete, reversible: false),
            entry("b1", 20, path: "/c", tier: .rebuildable, reversible: true),
        ], free: 22)
        precondition(tier(basic, .obsolete).bytes == 15 && tier(basic, .obsolete).reversibleBytes == 10 && tier(basic, .obsolete).permanentBytes == 5, "\(basic)")
        precondition(tier(basic, .rebuildable).bytes == 20 && basic.total.bytes == 35 && !basic.total.approx)
        precondition(basic.freeAfterA == 27 && basic.freeAfterAB == 27, "\(String(describing: basic.freeAfterA)) \(String(describing: basic.freeAfterAB))")
        precondition(basic.pendingTrashBytes == 10 && basic.pendingTrashBytesAB == 30)
        precondition(basic.trashNote.contains("移入废纸篓") && basic.trashNote.contains("清空废纸篓后才释放"), basic.trashNote)
        precondition(basic.trashNoteAB.contains("移入废纸篓") && basic.trashNoteAB != basic.trashNote)

        // 嵌套路径只算一次，归外层那一行的档位；各档相加 = 总量
        let childInB = ReportSummary.compute(entries: [
            entry("c", 4, path: "/p/c", tier: .obsolete, reversible: false),
            entry("p", 10, path: "/p", tier: .rebuildable, reversible: false),
        ], free: 100)
        precondition(childInB.total.bytes == 10 && childInB.tiers.reduce(0, { $0 + $1.bytes }) == 10, "\(childInB)")
        precondition(tier(childInB, .rebuildable).bytes == 10 && tier(childInB, .obsolete).bytes == 0)
        precondition(childInB.freeAfterA == 104 && childInB.freeAfterAB == 110, "子树只算一次")

        // 可找回的外层包着找不回的内层：内层字节随外层进废纸篓，不算释放
        let trashParent = ReportSummary.compute(entries: [
            entry("p", 10, path: "/p", tier: .obsolete, reversible: true),
            entry("c", 4, path: "/p/c", tier: .obsolete, reversible: false),
        ], free: 100)
        precondition(tier(trashParent, .obsolete).permanentBytes == 0 && trashParent.freeAfterA == 100 && trashParent.pendingTrashBytes == 10, "\(trashParent)")

        // 清 A+B 后的可用空间不会比只清 A 后更少（B 外层可找回、A 内层找不回）
        let mixed = ReportSummary.compute(entries: [
            entry("p", 10, path: "/p", tier: .rebuildable, reversible: true),
            entry("c", 4, path: "/p/c", tier: .obsolete, reversible: false),
        ], free: 100)
        precondition(mixed.freeAfterA == 104, "\(String(describing: mixed.freeAfterA))")
        precondition(mixed.freeAfterAB! >= mixed.freeAfterA!, "A+B \(String(describing: mixed.freeAfterAB)) below A \(String(describing: mixed.freeAfterA))")

        // 没有路径的估算项（Docker）叠加在上面，并把该档标成估算；用户保护的和零大小的不算
        let docker = ReportSummary.compute(entries: [
            entry("d", 7, path: nil, tier: .obsolete, reversible: false, approx: true),
            entry("p", 3, path: "/p", tier: .obsolete, reversible: false, protected: true),
            entry("z", 0, path: "/z", tier: .obsolete, reversible: false),
        ], free: 10)
        precondition(tier(docker, .obsolete).bytes == 7 && tier(docker, .obsolete).approx && docker.total.approx, "\(docker)")

        // 数据卷可用空间未知：不编造清理后的数字
        let unknown = ReportSummary.compute(entries: [entry("a", 5, path: "/a", tier: .obsolete, reversible: false)], free: nil)
        precondition(unknown.freeAfterA == nil && unknown.freeAfterAB == nil && tier(unknown, .obsolete).bytes == 5)

        // 缺失档位按 C；不可选的行只计大小、不计释放
        let noTier = ReportSummary.compute(entries: [
            { var e = entry("n", 9, path: "/n", tier: .review, reversible: false); e.tier = nil; return e }(),
            entry("l", 6, path: "/l", tier: .locked, reversible: false, selectable: false),
        ], free: 1)
        precondition(tier(noTier, .review).bytes == 9 && tier(noTier, .locked).bytes == 6 && noTier.freeAfterA == 1, "\(noTier)")

        // Codable 往返
        let data = try JSONEncoder().encode(basic)
        let decoded = try JSONDecoder().decode(ReportSummary.self, from: data)
        precondition(decoded == basic)
        print("ReportSummaryTests OK")
    }
}
