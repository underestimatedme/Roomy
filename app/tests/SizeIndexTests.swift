// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct SizeIndexTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-index-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tmp) }
        func file(_ p: String, _ n: Int) throws {
            try fm.createDirectory(atPath: tmp + "/" + (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: n).write(to: URL(fileURLWithPath: tmp + "/" + p))
        }
        try file("home/code/repo/.worktrees/wt/.cache/go-build/a", 300_000)
        try file("home/code/repo/.worktrees/wt/src.go", 40_000)
        try file("home/code/repo/node_modules/x/index.js", 120_000)
        try file("home/Library/Caches/pip/http/b", 200_000)
        try file("home/Documents/ComfyUI/models/m.safetensors", 90_000)   // 在跳过的隐私目录里 → 回退
        try file("home/Downloads/setup.dmg", 70_000)                      // 文件目标 → 回退
        try fm.linkItem(atPath: tmp + "/home/code/repo/node_modules/x/index.js", toPath: tmp + "/home/code/repo/hard.js")
        try fm.createSymbolicLink(atPath: tmp + "/home/code/repo/link", withDestinationPath: tmp + "/home/Library")

        let home = tmp + "/home"
        let targets = [home + "/code/repo/.worktrees/wt", home + "/code/repo/.worktrees/wt/.cache",
                       home + "/code/repo/node_modules", home + "/Library/Caches/pip",
                       home + "/Documents/ComfyUI/models", home + "/Downloads/setup.dmg", home + "/gone"]
        let index = BulkWalker().measure(roots: [home], targets: targets, dirDepth: 3, dirThreshold: 1,
                                         skip: [home + "/Documents"])
        let nodeModules = home + "/code/repo/node_modules"
        for t in targets where t != home + "/gone" && t != nodeModules {
            let alone = BulkWalker().size(of: t)!
            precondition(index.targets[t] == alone, "\(t): \(String(describing: index.targets[t])) vs \(alone)")
        }
        // node_modules 里有个文件在外面还有硬链接（repo/hard.js）：只算一次，删它也腾不出那部分，所以可以比单独统计小
        precondition(index.targets[nodeModules]! <= BulkWalker().size(of: nodeModules)!)
        precondition(index.targets[home + "/gone"] == nil)
        precondition(index.targets[home + "/code/repo/.worktrees/wt"]! > index.targets[home + "/code/repo/.worktrees/wt/.cache"]!)
        precondition(index.dirs[home + "/code"] != nil && index.dirs[home + "/Documents"] == nil, "\(index.dirs.keys.sorted())")
        precondition(index.dirs.keys.allSatisfy { $0.split(separator: "/").count - home.split(separator: "/").count <= 3 })
        // 硬链接只计一次：repo 的大小不会把 hard.js 再算一遍
        let repo = index.dirs[home + "/code/repo"]!
        let separately = BulkWalker().size(of: home + "/code/repo/node_modules")! + BulkWalker().size(of: home + "/code/repo/.worktrees/wt")!
        precondition(repo < separately + 120_000, "hard.js and index.js are one file: \(repo) vs \(separately)")
        // 拆到第二层并发后，第一层目录和第一层上的目标仍由子任务加总得到（含第一层自己的文件）
        try file("home/Library/top.plist", 50_000)
        let lib = BulkWalker().measure(roots: [home], targets: [home + "/Library"], dirDepth: 2, dirThreshold: 1, skip: [])
        precondition(lib.targets[home + "/Library"] == BulkWalker().size(of: home + "/Library")!, "\(String(describing: lib.targets[home + "/Library"]))")
        precondition(lib.dirs[home + "/Library"] == lib.targets[home + "/Library"] && lib.dirs[home + "/Library/Caches"] != nil)
        // 只统计目标：最外层的目标各遍历一次，嵌套在里面的目标在同一次遍历里记下；结果与逐个统计一致
        let only = BulkWalker().measureTargets(targets)
        for t in targets where t != home + "/gone" && t != nodeModules {
            precondition(only[t] == BulkWalker().size(of: t)!, "\(t): \(String(describing: only[t]))")
        }
        precondition(only[home + "/gone"] == nil && only[nodeModules] != nil)
        // 嵌套目标遍历没走到时（文件、在符号链接后面、大小写和磁盘上不一样）也要补齐，不能悄悄消失
        try file("home/n/a/setup.dmg", 73_000)
        try file("home/n/a/inner/x.bin", 100_000)
        try file("home/n/real/y.bin", 50_000)
        try fm.createSymbolicLink(atPath: tmp + "/home/n/a/lnk", withDestinationPath: tmp + "/home/n/real")
        let nestedTargets = [home + "/n/a", home + "/n/a/setup.dmg", home + "/n/a/lnk/y.bin", home + "/n/a/Inner"]
        let nested = BulkWalker().measureTargets(nestedTargets)
        for t in nestedTargets { precondition(nested[t] == BulkWalker().size(of: t)!, "nested \(t): \(String(describing: nested[t]))") }
        print("SizeIndexTests passed")
    }
}
