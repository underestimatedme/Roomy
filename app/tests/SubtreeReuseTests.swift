// SPDX-License-Identifier: MPL-2.0
import Foundation

/// 完整遍历取用清单统计时量过的子树（MeasuredSubtrees），结果必须和重新读一遍完全相同
@main
struct SubtreeReuseTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("roomy-reuse-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        func file(_ path: String, _ bytes: Int) throws {
            let full = base + "/" + path
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: URL(fileURLWithPath: full))
        }
        let home = base + "/home", code = base + "/code"
        for i in 0..<6 {
            try file("home/.cache/tool\(i)/blobs/a/b/c/d/e/f/g/data", 40_000 * (i + 1))    // 比记下的层数更深的目录
            try file("home/.cache/tool\(i)/index", 9_000)
            try file("code/p\(i)/node_modules/dep/lib/x.js", 30_000)
            try file("code/p\(i)/node_modules/dep/node_modules/inner/y.js", 20_000)
            try file("code/p\(i)/src/main.swift", 5_000)
        }
        try file("home/Library/Caches/app/blob", 300_000)
        try file("home/Library/Caches/app/private/secret", 100_000)                    // 遍历要跳过的目录在子树里
        try file("home/deep/a/b/c/d/e/f/g/h/node_modules/z.js", 70_000)                   // 第 9 层的子树
        try file("home/shared/original", 500_000)
        try file("home/.npm/_cacache/x", 50_000)
        try file("home/.gradle/caches/modules/jar", 80_000)                                // 第 1 层的子树
        try fm.linkItem(atPath: home + "/shared/original", toPath: home + "/.npm/_cacache/linked")   // 跨子树的硬链接

        let skip: Set<String> = [home + "/Library/Caches/app/private"]
        let targets = (0..<6).map { "\(home)/.cache/tool\($0)" } + (0..<6).flatMap { ["\(code)/p\($0)/node_modules", "\(code)/p\($0)/node_modules/dep/node_modules"] }
            + [home + "/Library/Caches/app", home + "/deep/a/b/c/d/e/f/g/h/node_modules", home + "/.npm/_cacache", home + "/.npm", home + "/.gradle", home + "/missing"]
        let roots = [home, code]

        func check(depth: Int, threshold: UInt64, walkThreshold: UInt64, walkTargets: [String] = [], label: String) {
            let measured = MeasuredSubtrees(depth: depth, threshold: threshold)
            let half = targets.count / 2   // 两路各量一半，像规则和探测器那样
            _ = BulkWalker().measureTargets(Array(targets[..<half]), record: measured)
            _ = BulkWalker().measureTargets(Array(targets[half...]), threads: 2, record: measured)
            let reader = BulkWalker(), plainReader = BulkWalker()
            let reused = reader.measure(roots: roots, targets: walkTargets, dirDepth: 6, dirThreshold: walkThreshold, skip: skip, reuse: measured)
            let plain = plainReader.measure(roots: roots, targets: walkTargets, dirDepth: 6, dirThreshold: walkThreshold, skip: skip)
            precondition(reused.dirs == plain.dirs, "\(label): dirs differ\n\(reused.dirs.sorted { $0.key < $1.key })\nvs\n\(plain.dirs.sorted { $0.key < $1.key })")
            precondition(reused.roots == plain.roots, "\(label): root totals differ \(reused.roots) vs \(plain.roots)")
            precondition(reused.targets == plain.targets, "\(label): targets differ")
            precondition(reused.unreadable == plain.unreadable, "\(label): unreadable differ")
            print("  \(label): read \(reader.dirs) of \(plainReader.dirs) dirs")
        }
        // 门槛一样：取用，读的目录少得多
        check(depth: 5, threshold: 1, walkThreshold: 1, label: "same threshold")
        // 只记了 1 层：浅处的子树不能取用（照常读），深处的可以
        check(depth: 1, threshold: 1, walkThreshold: 1, label: "shallow record")
        // 遍历要的门槛更低：都不能取用
        check(depth: 5, threshold: 100_000, walkThreshold: 1, label: "lower walk threshold")
        check(depth: 5, threshold: 100_000, walkThreshold: 200_000, label: "higher walk threshold")
        // 遍历另有目标，等于或落在量过的子树里
        check(depth: 5, threshold: 1, walkThreshold: 1, walkTargets: [home + "/.cache/tool2", code + "/p1/node_modules/dep", home + "/.npm/_cacache"],
              label: "walk targets")

        // 有硬链接的子树不记；跳过目录所在的子树记下但遍历不取用；量过的子树确实被取用了
        let measured = MeasuredSubtrees(depth: 5, threshold: 1)
        _ = BulkWalker().measureTargets(targets, record: measured)
        precondition(measured.count == 6 + 6 + 3, "recorded \(measured.count)")    // .cache×6、node_modules×6、Caches/app、deep、.gradle；.npm 有硬链接
        let reader = BulkWalker(), plainReader = BulkWalker()
        _ = reader.measure(roots: roots, targets: [], dirDepth: 6, dirThreshold: 1, skip: skip, reuse: measured)
        _ = plainReader.measure(roots: roots, targets: [], dirDepth: 6, dirThreshold: 1, skip: skip)
        precondition(reader.dirs < plainReader.dirs / 2, "reuse should skip most reads: \(reader.dirs) vs \(plainReader.dirs)")
        print("SubtreeReuseTests passed")
    }
}
