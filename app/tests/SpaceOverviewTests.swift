// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct SpaceOverviewTests {
    static func main() throws {
        // ── 只取互不包含的顶层区域，按大小降序；unattributed = 已用 - 区域之和
        let o = SpaceOverview.compute(dataUsed: 434, free: 22,
            areaSizes: ["/Users/j": 146, "/Users/j/Library": 75, "/opt": 96],
            unreadable: ["/Users/j/Desktop", "/Users/j/.Trash"], home: "/Users/j")
        precondition(o.areas == [SpaceArea(path: "/Users/j", bytes: 146), SpaceArea(path: "/opt", bytes: 96)], "\(o.areas)")
        precondition(o.areas.map(\.path) == ["/Users/j", "/opt"], "\(o.areas)")
        precondition(o.unattributed == 192, "\(o.unattributed)")
        precondition(o.dataUsed == 434 && o.free == 22)
        precondition(o.unreadableHints == ["/Users/j/Desktop", "/Users/j/.Trash"])
        precondition(o.unreadableSystemCount == 0)

        // 家目录之外的读不到的路径（/private/var/root、/private/var/audit 这类系统目录）不逐条列出，合并成一个数
        let noisy = SpaceOverview.compute(dataUsed: 100, free: 1, areaSizes: [:],
            unreadable: ["/private/var/root", "/private/var/audit", "/Users/j/Desktop", "/Users/j/.Trash", "/Users/jj/x"],
            home: "/Users/j")
        precondition(noisy.unreadableHints == ["/Users/j/Desktop", "/Users/j/.Trash"], "\(noisy.unreadableHints)")
        precondition(noisy.unreadableSystemCount == 3, "\(noisy.unreadableSystemCount)")
        let (shown, others) = SpaceOverview.partitionHints(["/private/var/root", "/Users/j/a", "/Users/jx/b"], home: "/Users/j")
        precondition(shown == ["/Users/j/a"] && others == 2, "\(shown) \(others)")

        // 前缀相同但不是子目录的不算嵌套
        let p = SpaceOverview.compute(dataUsed: 100, free: 0,
            areaSizes: ["/Users/j": 30, "/Users/jj": 20, "/Users/j/x": 10], unreadable: [])
        precondition(p.areas.map(\.path) == ["/Users/j", "/Users/jj"] && p.unattributed == 50, "\(p)")

        // 区域之和超过已用（硬链接/估算偏差）：下限 0，不下溢
        let big = SpaceOverview.compute(dataUsed: 10, free: 5, areaSizes: ["/a": 30], unreadable: [])
        precondition(big.unattributed == 0)

        // 空输入
        let empty = SpaceOverview.compute(dataUsed: 7, free: 1, areaSizes: [:], unreadable: [])
        precondition(empty.areas.isEmpty && empty.unattributed == 7)

        // Codable 往返
        let data = try JSONEncoder().encode(o)
        let decoded = try JSONDecoder().decode(SpaceOverview.self, from: data)
        precondition(decoded == o)

        // ── 读取失败的受保护路径 + ~/.Trash
        let hints = SpaceOverview.unreadableHints(home: "/h") { path in path != "/h/Desktop" && path != "/h/.Trash" }
        precondition(hints == ["/h/.Trash", "/h/Desktop"], "\(hints)")
        precondition(SpaceOverview.unreadableHints(home: "/h") { _ in true }.isEmpty)

        // ── 数据卷用量能取到（回退到 /）
        let usage = SpaceOverview.dataVolumeUsage()
        precondition(usage != nil && usage!.used > 0, "\(String(describing: usage))")

        // ── 一次遍历同时给出浅层目录大小和每个根的总量；不跨挂载点、跳过受保护子树
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-space-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tmp) }
        func file(_ path: String, _ bytes: Int) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        }
        try file(tmp + "/home/top.bin", 100_000)
        try file(tmp + "/home/a/b.bin", 200_000)
        try file(tmp + "/home/Desktop/skip.bin", 500_000)
        try file(tmp + "/sys/lib/c.bin", 300_000)
        let index = BulkWalker().measure(roots: [tmp + "/home", tmp + "/sys"], targets: [], dirDepth: 2, dirThreshold: 1,
                                         skip: [tmp + "/home/Desktop"])
        let home = index.roots[tmp + "/home"], sys = index.roots[tmp + "/sys"]
        precondition(home != nil && home! >= 300_000 && home! < 500_000, "home root total counts own files + subdirs, not skipped: \(String(describing: home))")
        precondition(sys != nil && sys! >= 300_000 && sys! < 400_000, "\(String(describing: sys))")
        precondition(index.dirs[tmp + "/home/a"] != nil)

        // 系统区域根与受保护子树
        let roots = ScanPipeline.systemAreaRoots()
        precondition(roots == ["/Applications", "/opt/homebrew", "/Library", "/private/var"], "\(roots)")

        // ── 读不了的根不能显示成 0：不进 roots，记进 unreadable；根里读不了的第一层目录也记下
        if geteuid() != 0 {
            let locked = tmp + "/locked-root"
            try fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
            try file(tmp + "/mixed/ok/x.bin", 150_000)
            let mixedLocked = tmp + "/mixed/locked"
            try fm.createDirectory(atPath: mixedLocked, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mixedLocked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mixedLocked)
            }
            let idx = BulkWalker().measure(roots: [locked, tmp + "/mixed", tmp + "/does-not-exist"], targets: [],
                                           dirDepth: 2, dirThreshold: 1, skip: [])
            precondition(idx.roots[locked] == nil, "unreadable root must not appear as 0: \(idx.roots)")
            precondition(idx.unreadable.contains(locked), "\(idx.unreadable)")
            precondition(idx.roots[tmp + "/mixed"] != nil && idx.roots[tmp + "/mixed"]! >= 150_000)
            precondition(idx.unreadable.contains(mixedLocked), "\(idx.unreadable)")
            precondition(idx.roots[tmp + "/does-not-exist"] == nil && !idx.unreadable.contains(tmp + "/does-not-exist"),
                         "a missing root is neither zero nor unreadable")
            let merged = SpaceOverview.unreadableHints(home: "/h", walkUnreadable: [locked]) { _ in true }
            precondition(merged == [locked], "\(merged)")
        }
        print("SpaceOverviewTests OK")
    }
}
