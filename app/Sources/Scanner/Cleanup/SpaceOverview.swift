// SPDX-License-Identifier: GPL-3.0-only
// "空间去向"：数据卷已用的空间落在哪几个顶层区域，以及有多少没能归到任何区域（读不了的、系统管的）。
// 只给报告用，纯展示，不能据此清理。

import Foundation

struct SpaceArea: Codable, Equatable {
    let path: String
    let bytes: UInt64
}

struct SpaceOverview: Codable, Equatable {
    let dataUsed: UInt64
    let free: UInt64
    let areas: [SpaceArea]
    let unattributed: UInt64
    /// 家目录里（含 ~/.Trash）读不到的路径，逐条列出
    let unreadableHints: [String]
    /// 家目录之外读不到的系统目录（/private/var/root 这类）只给个数，不逐条列
    let unreadableSystemCount: Int

    /// areaSizes 里互相包含的只留最外层（子目录已经在父目录的大小里），按大小降序；
    /// unattributed = 已用 - 各区域之和，下限 0
    static func compute(dataUsed: UInt64, free: UInt64, areaSizes: [String: UInt64], unreadable: [String],
                        home: String = HOME) -> SpaceOverview {
        func inside(_ path: String, _ dir: String) -> Bool { path.hasPrefix(dir == "/" ? "/" : dir + "/") }
        let top = areaSizes.filter { path, _ in !areaSizes.keys.contains { $0 != path && inside(path, $0) } }
        let areas = top.map { SpaceArea(path: $0.key, bytes: $0.value) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
        let attributed = areas.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let (hints, others) = partitionHints(unreadable, home: home)
        return SpaceOverview(dataUsed: dataUsed, free: free, areas: areas,
                             unattributed: dataUsed > attributed ? dataUsed - attributed : 0,
                             unreadableHints: hints, unreadableSystemCount: others)
    }

    /// 读不到的路径分两类：家目录里的逐条提示，其余（系统目录）只数个数。保持传入顺序
    static func partitionHints(_ paths: [String], home: String) -> (shown: [String], otherCount: Int) {
        let shown = paths.filter { $0 == home || $0.hasPrefix(home + "/") }
        return (shown, paths.count - shown.count)
    }

    /// 数据卷的已用和可用；取不到 /System/Volumes/Data 时回退到 /
    static func dataVolumeUsage() -> (used: UInt64, free: UInt64)? {
        for path in ["/System/Volumes/Data", "/"] {
            var s = statfs()
            guard statfs(path, &s) == 0, s.f_blocks > 0 else { continue }
            let bs = UInt64(s.f_bsize)
            let total = UInt64(s.f_blocks) * bs, free = UInt64(s.f_bavail) * bs
            return (total > free ? total - free : 0, free)
        }
        return nil
    }

    /// 读不了的路径，报告里提示"这些没算进去"：遍历时没读成的（walkUnreadable），
    /// 加上遍历跳过的受保护子树和废纸篓里 access 判断读不了的。
    /// 用 access 判断，不真正打开目录——打开会触发系统的授权弹窗
    static func unreadableHints(home: String = HOME, walkUnreadable: [String] = [],
                                readable: (String) -> Bool = { access($0, R_OK) == 0 }) -> [String] {
        let candidates = UnexplainedSpace.protectedSubtrees(home: home).union([home + "/.Trash"])
        return Set(candidates.filter { !readable($0) }).union(walkUnreadable).sorted()
    }
}
