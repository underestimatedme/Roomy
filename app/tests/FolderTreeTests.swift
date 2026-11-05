// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct FolderTreeTests {
    static func entry(id: String, path: String, tier: CleanupTier, selectable: Bool, safetyHold: Bool? = nil,
                      userProtected: Bool? = nil) -> CleanupEntry {
        var e = CleanupEntry(id: id, title: "t-" + id, size: 1, estimateIsApprox: false, evidence: "fixture",
            actionLabel: "", reversible: true, risk: .green, selectable: selectable, defaultChecked: false, source: "fixture")
        e.path = path; e.tier = tier; e.safetyHold = safetyHold; e.userProtected = userProtected
        return e
    }

    static func main() {
        let dirs: [String: UInt64] = ["/h/a": 10, "/h/a/x": 6, "/h/b": 3]
        let entries = [entry(id: "x", path: "/h/a/x", tier: .obsolete, selectable: true)]
        let top = FolderTree.children(of: "/", dirs: dirs, rootTotals: ["/h": 20], unreadable: ["/h/locked"], entries: entries)
        precondition(top.map(\.path) == ["/h"], "\(top.map(\.path))")
        precondition(top[0].size == 20 && top[0].hasChildren && top[0].name == "h")

        let h = FolderTree.children(of: "/h", dirs: dirs, rootTotals: ["/h": 20], unreadable: ["/h/locked"], entries: entries)
        precondition(h.map(\.path) == ["/h/a", "/h/…", "/h/b", "/h/locked"], "\(h.map(\.path))")   // 其余 = 20-13 = 7
        precondition(h.first { $0.path == "/h/…" }?.size == 7 && h.first { $0.path == "/h/locked" }?.unreadable == true)
        let rest = h.first { $0.path == "/h/…" }!
        precondition(rest.name == "其余" && rest.tier == nil && !rest.selectable && !rest.hasChildren && rest.entryID == nil)
        let locked = h.first { $0.path == "/h/locked" }!
        precondition(locked.size == 0 && !locked.selectable && !locked.hasChildren)
        precondition(h.first { $0.path == "/h/a" }!.hasChildren && !h.first { $0.path == "/h/b" }!.hasChildren)
        // 目录本身在条目之上（条目在它下面）时不带条目
        precondition(h.first { $0.path == "/h/a" }!.tier == nil && h.first { $0.path == "/h/a" }!.entryID == nil)

        let a = FolderTree.children(of: "/h/a", dirs: dirs, rootTotals: ["/h": 20], unreadable: [], entries: entries)
        precondition(a.map(\.path) == ["/h/a/x", "/h/a/…"], "\(a.map(\.path))")   // 其余 = 10-6 = 4
        precondition(a.first { $0.path == "/h/a/x" }?.tier == .obsolete && a.first { $0.path == "/h/a/x" }?.selectable == true)
        precondition(a.first { $0.path == "/h/a/x" }?.entryID == "x")

        let held = [entry(id: "x", path: "/h/a/x", tier: .obsolete, selectable: true, safetyHold: true)]
        precondition(FolderTree.children(of: "/h/a", dirs: dirs, rootTotals: ["/h": 20], unreadable: [], entries: held).first!.selectable == true,
                     "safety-held entries are individually selectable (same rule as CleanupCore.canPick)")
        let lockedEntry = [entry(id: "x", path: "/h/a/x", tier: .locked, selectable: true)]
        let lockedNode = FolderTree.children(of: "/h/a", dirs: dirs, rootTotals: ["/h": 20], unreadable: [], entries: lockedEntry).first!
        precondition(lockedNode.selectable == false && lockedNode.tier == .locked)
        let guarded = [entry(id: "x", path: "/h/a/x", tier: .obsolete, selectable: true, userProtected: true)]
        precondition(FolderTree.children(of: "/h/a", dirs: dirs, rootTotals: ["/h": 20], unreadable: [], entries: guarded).first!.selectable == false)

        // 目录在条目路径之下：继承条目；最深的条目优先
        let deep: [String: UInt64] = ["/h/a": 10, "/h/a/x": 6, "/h/a/x/y": 5]
        let two = [entry(id: "outer", path: "/h/a/x", tier: .review, selectable: true),
                   entry(id: "inner", path: "/h/a/x/y", tier: .rebuildable, selectable: true)]
        let inside = FolderTree.children(of: "/h/a/x", dirs: deep, rootTotals: ["/h": 20], unreadable: [], entries: two)
        precondition(inside.first { $0.path == "/h/a/x/y" }?.entryID == "inner", "\(inside)")
        let below: [String: UInt64] = ["/h/a": 10, "/h/a/x": 6, "/h/a/x/y": 5]
        let outerOnly = [entry(id: "outer", path: "/h/a/x", tier: .review, selectable: true)]
        let inherited = FolderTree.children(of: "/h/a/x", dirs: below, rootTotals: ["/h": 20], unreadable: [], entries: outerOnly)
        precondition(inherited.first { $0.path == "/h/a/x/y" }?.entryID == "outer" && inherited.first { $0.path == "/h/a/x/y" }?.tier == .review)
        // 兄弟路径前缀不算在条目之下
        let sibling = [entry(id: "s", path: "/h/a/x", tier: .obsolete, selectable: true)]
        let sibDirs: [String: UInt64] = ["/h/a": 10, "/h/a/xy": 6]
        precondition(FolderTree.children(of: "/h/a", dirs: sibDirs, rootTotals: ["/h": 20], unreadable: [], entries: sibling).first { $0.path == "/h/a/xy" }?.entryID == nil)

        // 其余不大于 0 时不返回
        let full: [String: UInt64] = ["/h/a": 12, "/h/b": 8]
        precondition(FolderTree.children(of: "/h", dirs: full, rootTotals: ["/h": 20], unreadable: [], entries: []).map(\.path) == ["/h/a", "/h/b"])
        // 不可读的根单独出现在顶层
        let withBad = FolderTree.children(of: "/", dirs: [:], rootTotals: ["/h": 20], unreadable: ["/Library", "/h/locked"], entries: [])
        precondition(withBad.map(\.path) == ["/h", "/Library"] && withBad[1].unreadable, "\(withBad.map(\.path))")
        // 没有数据的路径
        precondition(FolderTree.children(of: "/nowhere", dirs: dirs, rootTotals: ["/h": 20], unreadable: [], entries: []).isEmpty)
        // 面包屑与合计：根的上一层是 "/"，"/" 没有上一层；合计取目录或根自身的大小，"/" 取所有根之和
        let roots: [String: UInt64] = ["/h": 20, "/Library": 5]
        precondition(FolderTree.parentPath(of: "/h/a", rootTotals: roots) == "/h" && FolderTree.parentPath(of: "/h", rootTotals: roots) == "/"
                     && FolderTree.parentPath(of: "/", rootTotals: roots) == nil)
        precondition(FolderTree.total(of: "/h/a", dirs: dirs, rootTotals: roots) == 10 && FolderTree.total(of: "/h", dirs: dirs, rootTotals: roots) == 20
                     && FolderTree.total(of: "/", dirs: dirs, rootTotals: roots) == 25 && FolderTree.total(of: "/zz", dirs: dirs, rootTotals: roots) == 0)
        print("FolderTreeTests passed")
    }
}
