// SPDX-License-Identifier: GPL-3.0-only
// 报告的"结论"：各档大小（拆成可找回 / 找不回）、只清 A 后和清 A+B 后的可用空间。
// 与网页端 cleanup-core.js 的 reportSummary 同一套口径：
//   · 嵌套路径只算一次，归外层那一行的档位；各档相加 = 总量
//   · 没有文件系统路径的行（Docker 对象等）无法去重，叠加在上面并把该档标成估算
//   · 只有找不回（直接删除）的字节会立刻释放；进废纸篓的在同一个卷上，清空废纸篓后才释放
//   · 清 A+B 后的可用空间不会比只清 A 后更少

import Foundation

struct ReportSummary: Codable, Equatable {
    struct Tier: Codable, Equatable {
        let key: String
        let bytes: UInt64
        let reversibleBytes: UInt64
        let permanentBytes: UInt64
        let approx: Bool
    }
    struct Total: Codable, Equatable {
        let bytes: UInt64
        let approx: Bool
    }

    let tiers: [Tier]
    let total: Total
    /// 数据卷可用空间量不出来时为 nil：不编造清理后的数字
    let freeAfterA: UInt64?
    let freeAfterAB: UInt64?
    let pendingTrashBytes: UInt64
    let pendingTrashBytesAB: UInt64
    let trashNote: String
    let trashNoteAB: String

    static func compute(entries: [CleanupEntry], free: UInt64?) -> ReportSummary {
        let order = Dictionary(uniqueKeysWithValues: CleanupTier.allCases.enumerated().map { ($1, $0) })
        func tier(_ e: CleanupEntry) -> CleanupTier { e.tier ?? .review }
        // 稳定排序：同档保持原顺序（同路径同大小时先出现的那行胜出）
        let sized = entries.enumerated()
            .filter { $0.element.userProtected != true && $0.element.size > 0 }
            .sorted { (a, b) in
                let x = order[tier(a.element)]!, y = order[tier(b.element)]!
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)

        func attribute(_ rows: [CleanupEntry]) -> [CleanupEntry] {
            outermost(rows.filter(isLocated)) + rows.filter { !isLocated($0) }
        }
        func sum(_ rows: [CleanupEntry]) -> UInt64 { rows.reduce(0) { $0 &+ $1.size } }
        func split(_ rows: [CleanupEntry]) -> (reversible: UInt64, permanent: UInt64) {
            let eligible = rows.filter(\.selectable)
            return (sum(eligible.filter(\.reversible)), sum(eligible.filter { !$0.reversible }))
        }
        func approx(_ rows: [CleanupEntry]) -> Bool { rows.contains { $0.estimateIsApprox || !isLocated($0) } }

        let counted = attribute(sized)
        let tiers = CleanupTier.allCases.map { meta -> Tier in
            let rows = counted.filter { tier($0) == meta }
            let s = split(rows)
            return Tier(key: meta.rawValue, bytes: sum(rows), reversibleBytes: s.reversible, permanentBytes: s.permanent, approx: approx(rows))
        }
        func upTo(_ keep: [CleanupTier]) -> (reversible: UInt64, permanent: UInt64) {
            split(attribute(sized.filter { keep.contains(tier($0)) }))
        }
        let a = upTo([.obsolete]), ab = upTo([.obsolete, .rebuildable])
        func note(_ bytes: UInt64) -> String {
            bytes > 0 ? "其中 \(format(bytes)) 移入废纸篓，清空废纸篓后才释放" : ""
        }
        let afterA = free.map { $0 &+ a.permanent }
        let afterAB = free.map { max($0 &+ ab.permanent, $0 &+ a.permanent) }
        return ReportSummary(tiers: tiers, total: Total(bytes: sum(counted), approx: approx(counted)),
                             freeAfterA: afterA, freeAfterAB: afterAB,
                             pendingTrashBytes: a.reversible, pendingTrashBytesAB: ab.reversible,
                             trashNote: note(a.reversible), trashNoteAB: note(ab.reversible))
    }

    // MARK: 路径去重

    private static func isLocated(_ e: CleanupEntry) -> Bool {
        guard e.size > 0, let path = e.path, path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    private static func normalize(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.isEmpty { return "/" }
        parts.insert("", at: 0)
        return parts.joined(separator: "/")
    }

    /// 嵌套的路径只留最外层；同一路径出现两次留大的（相同大小留先出现的）
    private static func outermost(_ rows: [CleanupEntry]) -> [CleanupEntry] {
        var byPath: [String: CleanupEntry] = [:], order: [String] = []
        for e in rows {
            guard let raw = e.path else { continue }
            let path = normalize(raw)
            if let cur = byPath[path] {
                if e.size > cur.size { byPath[path] = e }
            } else { byPath[path] = e; order.append(path) }
        }
        return order.compactMap { path in
            var parent = path
            while parent != "/" {
                let cut = parent.lastIndex(of: "/")!
                parent = cut == parent.startIndex ? "/" : String(parent[..<cut])
                if byPath[parent] != nil { return nil }
            }
            return byPath[path]
        }
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
