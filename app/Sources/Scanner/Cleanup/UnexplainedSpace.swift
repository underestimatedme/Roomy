// SPDX-License-Identifier: GPL-3.0-only
// "Roomy 还看不懂的大目录"：从上往下统计目录大小，扣掉清单已覆盖的和规则认识但有意不动的，
// 剩下仍然很大的目录列出来——只展示、不能清理，也是下一批该写什么规则的依据。

import Foundation

struct UnexplainedDir: Codable, Equatable {
    let path: String
    let size: UInt64          // 目录总占用
    let unexplained: UInt64   // 只属于它自己的、解释不了的部分（已扣掉更深一层列出的），各行可以相加
}

enum UnexplainedSpace {
    static func find(sizes: [String: UInt64], explained: [(path: String, bytes: UInt64)], known: [String],
                     roots: [String], threshold: UInt64) -> [UnexplainedDir] {
        func inside(_ path: String, _ dir: String) -> Bool { path == dir || path.hasPrefix(dir + "/") }
        let candidates = sizes.keys.filter { d in
            !roots.contains(d) && sizes[d]! >= threshold
                && !explained.contains { inside(d, $0.path) } && !known.contains { inside(d, $0) }
        }
        // 自下而上：先处理深的，父目录再扣掉已经列出的子孙
        let ordered = candidates.sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a != b ? a > b : $0 < $1
        }
        var listed: [UnexplainedDir] = []
        for d in ordered {
            let covered = explained.filter { inside($0.path, d) }.reduce(Int64(0)) { $0 + Int64($1.bytes) }
                + known.filter { inside($0, d) }.reduce(Int64(0)) { $0 + Int64(sizes[$1] ?? 0) }
            let attributed = listed.filter { inside($0.path, d) }.reduce(Int64(0)) { $0 + Int64($1.unexplained) }
            let remainder = Int64(sizes[d]!) - covered - attributed
            // 已有更深的被列出时，自己的零头要占一半以上才列：否则只是很多小目录拼出来的，打开也看不出是什么
            let hasListedChild = attributed > 0
            if remainder >= Int64(threshold), !hasListedChild || remainder * 2 >= Int64(sizes[d]!) {
                listed.append(UnexplainedDir(path: d, size: sizes[d]!, unexplained: UInt64(remainder)))
            }
        }
        return listed.sorted { $0.unexplained > $1.unexplained }
    }

    /// 从完整遍历的结果里取"看不懂的大目录"的输入：只留根之内、根下 maxDepth 层以内、不小于 threshold 的目录。
    /// 遍历为了"按文件夹看"记得更深、阈值更低，这里把它收窄回原来的范围，结果不随遍历参数变化。
    static func walkSizes(dirs: [String: UInt64], roots: [String], threshold: UInt64, maxDepth: Int = 5) -> [String: UInt64] {
        dirs.filter { path, size in
            guard size >= threshold else { return false }
            return roots.contains { root in
                guard path == root || path.hasPrefix(root + "/") else { return false }
                let depth = path.dropFirst(root.count).split(separator: "/").count
                return depth <= maxDepth
            }
        }
    }

    /// 受隐私保护或在云端的目录：读它们会弹授权、或卡在占位文件上，不统计
    static func protectedSubtrees(home: String) -> Set<String> {
        Set(["Library/Containers", "Library/Group Containers", "Library/Mobile Documents", "Library/CloudStorage",
             "Desktop", "Documents", "Pictures", "Movies", "Music"].map { home + "/" + $0 })
    }

    /// 按根目录下的第一层拆开并发遍历，记下 maxDepth 层以内、不小于 threshold 的目录大小
    static func sizeMap(roots: [String], threshold: UInt64, maxDepth: Int = 5, home: String = HOME) -> [String: UInt64] {
        final class Box: @unchecked Sendable { let lock = NSLock(); var map: [String: UInt64] = [:] }
        let box = Box()
        let skip = protectedSubtrees(home: home)
        let tasks = roots.flatMap { root -> [String] in
            ((try? readDir(root)) ?? []).filter(\.isDir).map { root + "/" + $0.name }.filter { !skip.contains($0) }
        }
        DispatchQueue.concurrentPerform(iterations: tasks.count) { i in
            var local: [String: UInt64] = [:]
            _ = BulkWalker().size(of: tasks[i], maxDepth: maxDepth - 1, skip: skip) { path, bytes in
                if bytes >= threshold { local[path] = bytes }
            }
            box.lock.lock(); box.map.merge(local) { a, _ in a }; box.lock.unlock()
        }
        return box.map
    }

    /// 规则认识、但不一定出现在清单里的位置（有意不动的、工具接管的、保护区）
    static var knownPaths: [String] { RULES.flatMap(\.literalPaths) }

    /// 一句话说明它大概是什么
    static func hint(for path: String, home: String = HOME, codeRoots: [String] = ALL_CODE_ROOTS) -> String {
        if path.hasPrefix(home + "/Library/Application Support/") { return "应用数据" }
        if path.hasPrefix(home + "/Library/Caches/") { return "应用缓存" }
        let worktrees = home + "/.codex/worktrees"
        if path == worktrees || path.hasPrefix(worktrees + "/") { return "代码目录" }
        if codeRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return "代码目录" }
        if path.hasPrefix(home + "/.") { return "工具数据" }
        return ""
    }
}
