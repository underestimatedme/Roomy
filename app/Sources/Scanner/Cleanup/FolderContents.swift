// SPDX-License-Identifier: MPL-2.0
// 详情里展开一项：它下面的直接子项各占多少。只给人看，不能单独勾选——清理的安全检查都按整个条目做。

import Foundation

struct FolderContents: Codable, Equatable {
    struct Child: Codable, Equatable {
        let name: String
        let size: UInt64
        let isDir: Bool
    }
    let path: String
    /// 大的在前，最多 limit 个
    let children: [Child]
    /// 没列出来的那些，合成一行
    let moreCount: Int
    let moreSize: UInt64

    /// 不是目录（文件、符号链接、不存在）或读不了时返回 nil。符号链接子项不跟随、不列出
    static func list(path: String, limit: Int = 30) -> FolderContents? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, let entries = try? readDir(path) else { return nil }
        let base = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let dirs = entries.filter { $0.isDir && !$0.isLink }.map { base + "/" + $0.name }
        let sizes = BulkWalker().measureTargets(dirs)
        var all: [Child] = []
        for e in entries where !e.isLink {
            if e.isDir { all.append(Child(name: e.name, size: sizes[base + "/" + e.name] ?? 0, isDir: true)) }
            else if e.isFile { all.append(Child(name: e.name, size: e.alloc, isDir: false)) }
        }
        all.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        let shown = Array(all.prefix(limit)), rest = all.dropFirst(limit)
        return FolderContents(path: base, children: shown, moreCount: rest.count, moreSize: rest.reduce(0) { $0 &+ $1.size })
    }
}
