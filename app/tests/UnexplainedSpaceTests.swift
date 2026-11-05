// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct UnexplainedSpaceTests {
    static func main() throws {
        // ── 一次遍历记下浅层目录的大小
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-unexplained-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tmp) }
        func file(_ path: String, _ bytes: Int) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        }
        try file(tmp + "/a/b/c/deep.bin", 300_000)
        try file(tmp + "/a/top.bin", 100_000)
        try file(tmp + "/x/y.bin", 50_000)
        let walker = BulkWalker()
        var map: [String: UInt64] = [:]
        let total = walker.size(of: tmp, maxDepth: 2) { path, bytes in map[path] = bytes }
        precondition(total != nil && map[tmp] == total, "root itself is recorded")
        precondition(map[tmp + "/a"]! >= 400_000 && map[tmp + "/a/b"]! >= 300_000, "\(map)")
        precondition(map[tmp + "/a/b/c"] == nil, "deeper than maxDepth is summed into its ancestors, not recorded")
        precondition(map[tmp + "/a"]! + map[tmp + "/x"]! <= total!)

        // ── 找出清单解释不了的大目录
        let G: UInt64 = 1_000_000_000
        let sizes: [String: UInt64] = [
            "/h": 100 * G,
            "/h/Library": 40 * G,
            "/h/Library/Caches": 12 * G,
            "/h/Library/Caches/pip": 10 * G,          // 规则已覆盖
            "/h/Library/Application Support": 15 * G,
            "/h/Library/Application Support/Claude": 9 * G,
            "/h/Library/Application Support/Claude/vm": 8_500_000_000,
            "/h/.codex": 7_500_000_000,
            "/h/.codex/sessions": 3 * G,              // 规则已覆盖
            "/h/.codex/worktrees": 4_500_000_000,
            "/h/.codex/worktrees/a": 4 * G,
            "/h/Library/Containers/docker": 19 * G,   // 规则认识、有意不动
            "/h/code/proj": 3 * G,
            "/h/code/proj/node_modules": 2_500_000_000, // 规则已覆盖，在 proj 内部
        ]
        let explained: [(path: String, bytes: UInt64)] = [
            ("/h/Library/Caches/pip", 10 * G), ("/h/.codex/sessions", 3 * G), ("/h/code/proj/node_modules", 2_500_000_000),
        ]
        let found = UnexplainedSpace.find(sizes: sizes, explained: explained, known: ["/h/Library/Containers/docker"],
                                          roots: ["/h"], threshold: G)
        let paths = found.map(\.path)
        // 自下而上：每个目录只算"扣掉清单覆盖、扣掉更深一层已列出的"剩余部分，数字可以相加不重复
        // Application Support 自己的零头 6.5 GB 只占它 15 GB 的 43%，是很多小目录拼出来的：不单独列
        precondition(paths == ["/h/Library/Application Support/Claude/vm", "/h/.codex/worktrees/a", "/h/Library/Caches"],
                     "\(paths)")
        precondition(found.map(\.unexplained) == [8_500_000_000, 4 * G, 2 * G], "\(found.map(\.unexplained))")
        precondition(found[2].size == 12 * G, "size is the folder's total, unexplained is its own remainder")

        // 已有子目录被列出、但自己的零头仍占一半以上：列出
        let mostlyOwn = UnexplainedSpace.find(sizes: ["/h": 20 * G, "/h/p": 6 * G, "/h/p/big": 2 * G],
                                              explained: [], known: [], roots: ["/h"], threshold: G)
        precondition(mostlyOwn.map(\.path) == ["/h/p", "/h/p/big"], "\(mostlyOwn.map(\.path))")
        precondition(!paths.contains("/h/code/proj"), "3 GB minus 2.5 GB node_modules = 0.5 GB < threshold")
        precondition(!paths.contains("/h"), "a scan root's remainder is scattered small folders, not one thing")
        precondition(!paths.contains { $0.hasPrefix("/h/Library/Containers") }, "known, intentionally kept")

        // 父目录扣掉子目录后仍然大，而子目录本身不够大时，列父目录
        let parentOnly = UnexplainedSpace.find(sizes: ["/h": 10 * G, "/h/big": 5 * G, "/h/big/s1": 400_000_000,
                                                       "/h/big/s2": 300_000_000], explained: [], known: [], roots: ["/h"],
                                                       threshold: G)
        precondition(parentOnly.map(\.path) == ["/h/big"], "\(parentOnly.map(\.path))")

        // 遍历记录得更深、阈值更低时，"看不懂的大目录"用的输入不变：只取根下 5 层以内、不小于阈值、且在根之内的目录
        let walked: [String: UInt64] = ["/h/a": 3 * G, "/h/a/b": 2 * G, "/h/a/b/c/d/e": 2 * G, "/h/a/b/c/d/e/f": 2 * G,
                                        "/h/small": 300_000_000, "/sys/x": 5 * G]
        let inputs = UnexplainedSpace.walkSizes(dirs: walked, roots: ["/h"], threshold: G, maxDepth: 5)
        precondition(Set(inputs.keys) == ["/h/a", "/h/a/b", "/h/a/b/c/d/e"], "\(inputs.keys.sorted())")

        precondition(UnexplainedSpace.hint(for: "/h/Library/Application Support/Claude/vm", home: "/h", codeRoots: []) == "应用数据")
        precondition(UnexplainedSpace.hint(for: "/h/Library/Caches/Google/Chrome", home: "/h", codeRoots: []) == "应用缓存")
        precondition(UnexplainedSpace.hint(for: "/opt/coding/x/.cache", home: "/h", codeRoots: ["/opt/coding"]) == "代码目录")
        precondition(UnexplainedSpace.hint(for: "/h/.codex/worktrees/a", home: "/h", codeRoots: []) == "代码目录")
        precondition(UnexplainedSpace.hint(for: "/h/.codex/worktrees", home: "/h", codeRoots: []) == "代码目录")
        precondition(UnexplainedSpace.hint(for: "/h/.codex/worktrees-old", home: "/h", codeRoots: []) == "工具数据")
        precondition(UnexplainedSpace.hint(for: "/h/.codex/sessions/a", home: "/h", codeRoots: []) == "工具数据")
        precondition(UnexplainedSpace.hint(for: "/h/Documents", home: "/h", codeRoots: []) == "")
        print("UnexplainedSpaceTests passed")
    }
}
