// SPDX-License-Identifier: MPL-2.0
// "按文件夹看"的节点：把清理扫描顺手走出来的目录大小（dirs）按层展开，并标出哪些节点对应清单里的条目。
// 只读展示用的数据；能不能选中完全由清单条目决定，没有条目的目录一律不可选。

import Foundation

struct FolderNode: Codable, Equatable {
    let path: String
    let name: String
    let size: UInt64
    let tier: CleanupTier?
    let entryID: String?
    let selectable: Bool
    let hasChildren: Bool
    let unreadable: Bool
}

enum FolderTree {
    /// 其余节点的路径后缀与显示名
    static let restSuffix = "/…"
    static let restName = "其余"

    /// - path == "/"：各扫描根（rootTotals 的键），再加上不在任何根里的读不了的路径
    /// - 其他：dirs 里父目录等于 path 的子目录，读不了的一级目录，以及一块"其余"（父目录大小 − 子目录之和，≤ 0 不返回）
    static func children(of path: String, dirs: [String: UInt64], rootTotals: [String: UInt64],
                         unreadable: [String], entries: [CleanupEntry]) -> [FolderNode] {
        let matcher = EntryMatcher(entries)
        let parents = Set(dirs.keys.map(parent(of:)))
        var nodes: [FolderNode] = []

        func node(_ p: String, size: UInt64) -> FolderNode {
            let entry = matcher.entry(for: p)
            let tier = entry?.tier
            return FolderNode(path: p, name: name(of: p), size: size, tier: tier, entryID: entry?.id,
                              // 与页面的 CleanupCore.canPick 同一规则：安全降级的条目可以单独选（确认面板里逐项确认），只是不进整组选择
                              selectable: entry.map { $0.selectable && $0.tier != .locked && $0.userProtected != true } ?? false,
                              hasChildren: parents.contains(p), unreadable: false)
        }
        func unreadableNode(_ p: String) -> FolderNode {
            FolderNode(path: p, name: name(of: p), size: 0, tier: nil, entryID: nil, selectable: false, hasChildren: false, unreadable: true)
        }

        if path == "/" {
            nodes = rootTotals.map { node($0.key, size: $0.value) }
            for bad in Set(unreadable) where rootTotals[bad] == nil && !rootTotals.keys.contains(where: { bad.hasPrefix($0 + "/") }) {
                nodes.append(unreadableNode(bad))
            }
        } else {
            guard let total = dirs[path] ?? rootTotals[path] else { return [] }
            var covered: UInt64 = 0
            for (p, size) in dirs where parent(of: p) == path {
                nodes.append(node(p, size: size))
                covered &+= size
            }
            for bad in Set(unreadable) where parent(of: bad) == path && dirs[bad] == nil {
                nodes.append(unreadableNode(bad))
            }
            if total > covered {
                nodes.append(FolderNode(path: path + restSuffix, name: restName, size: total - covered, tier: nil, entryID: nil,
                                        selectable: false, hasChildren: false, unreadable: false))
            }
        }
        return nodes.sorted { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
    }

    /// 面包屑用的上一层：根的上一层是 "/"，"/" 自己没有
    static func parentPath(of path: String, rootTotals: [String: UInt64]) -> String? {
        if path == "/" { return nil }
        return rootTotals[path] != nil ? "/" : parent(of: path)
    }

    /// 这一层的合计：目录或根自身的大小；"/" 是所有根之和；没有记录的路径是 0
    static func total(of path: String, dirs: [String: UInt64], rootTotals: [String: UInt64]) -> UInt64 {
        if path == "/" { return rootTotals.values.reduce(0) { $0 &+ $1 } }
        return dirs[path] ?? rootTotals[path] ?? 0
    }

    /// 节点的上一层；根（或顶层）返回 "/"
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func name(of path: String) -> String {
        path == "/" ? "/" : String(path.split(separator: "/").last ?? "")
    }

    /// 目录对应的清单条目：条目路径与目录相同，或目录在条目路径之下；有多个时取路径最深的
    private struct EntryMatcher {
        private let byPath: [String: CleanupEntry]
        init(_ entries: [CleanupEntry]) {
            var map: [String: CleanupEntry] = [:]
            for e in entries {
                guard let p = e.path, !p.isEmpty else { continue }
                if let old = map[p] {
                    // 同一路径有多条时取最保守的：不可选的优先，其次按 id 定一个固定的结果
                    let oldSafe = !old.selectable
                    let newSafe = !e.selectable
                    if oldSafe != newSafe { if newSafe { map[p] = e }; continue }
                    if e.id < old.id { map[p] = e }
                } else { map[p] = e }
            }
            byPath = map
        }
        func entry(for dir: String) -> CleanupEntry? {
            var p = dir
            while true {
                if let e = byPath[p] { return e }
                let up = FolderTree.parent(of: p)
                if up == p || up == "/" { return byPath[up] }
                p = up
            }
        }
    }
}
