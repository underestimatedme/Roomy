// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct BulkCancellationTests {
    /// 取消回调会从并发任务里被调用：计数必须过锁，否则断言不可靠
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var stopped = false
        private let stopAfter: Int
        init(stopAfter: Int) { self.stopAfter = stopAfter }
        /// 超过 stopAfter 之后一直返回 false（真实的取消）
        func keepGoing() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if stopped { return false }
            calls += 1
            if calls > stopAfter { stopped = true; return false }
            return true
        }
        var total: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var didStop: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// 只 false 一次，之后又 true：不能因此把半截遍历称成完整
    final class OneShotFalse: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var fired = false
        func keepGoing() -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            if calls == 3 && !fired { fired = true; return false }
            return true
        }
    }

    static func makeTree(_ root: URL, levels: Int, width: Int, files: Int) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if levels == 0 {
            for f in 0..<files { try Data().write(to: root.appendingPathComponent("f-\(f)")) }
            return
        }
        for d in 0..<width {
            try makeTree(root.appendingPathComponent("d-\(d)"), levels: levels - 1, width: width, files: files)
        }
    }

    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-bulk-cancel-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // ① 单目录多批 read：最外层 readEntries 就能观察到取消
        let flat = root.appendingPathComponent("flat")
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        for index in 0..<5_000 {
            try Data().write(to: flat.appendingPathComponent("f-\(index)"))
        }
        let fd = try openDir(flat.path)
        defer { close(fd) }
        var entries: [DirEntry] = []
        var checks = 0
        do {
            try readEntries(fd: fd, into: &entries, buf: AttrBuffer(size: 4 * 1024)) {
                checks += 1
                return checks <= 2
            }
            preconditionFailure("multi-batch read should observe cancellation")
        } catch BulkError.cancelled {
            precondition(checks == 3)
            precondition(entries.count < 5_000)
        }

        // ② 浅树（根目录直接放文件）：只读根、没有子目录可递归。取消也必须生效，
        //    不能因为不进 walk 递归就把整棵树读完
        let shallow = root.appendingPathComponent("shallow")
        try fm.createDirectory(at: shallow, withIntermediateDirectories: true)
        for index in 0..<5_000 {
            try Data().write(to: shallow.appendingPathComponent("f-\(index)"))
        }
        let shallowCounter = Counter(stopAfter: 2)
        let shallowWalker = BulkWalker()
        let shallowIndex = shallowWalker.measure(roots: [shallow.path], targets: [], dirDepth: 6, dirThreshold: 0,
                                                 skip: [], shouldContinue: shallowCounter.keepGoing)
        precondition(shallowCounter.didStop, "top-level read should observe cancellation")
        precondition(shallowWalker.cancelled > 0, "top-level cancellation must be recorded")
        precondition(shallowIndex.roots[shallow.path] == nil, "cancelled root stays unknown, not 0")

        // ③ 深树（三层、很多子目录）：取消要传进 measureWalk / walk 的递归，不是只停在最外层
        let deep = root.appendingPathComponent("deep")
        try makeTree(deep, levels: 3, width: 5, files: 20)
        let deepCounter = Counter(stopAfter: 20)
        let deepWalker = BulkWalker()
        let deepIndex = deepWalker.measure(roots: [deep.path], targets: [], dirDepth: 6, dirThreshold: 0,
                                           skip: [], shouldContinue: deepCounter.keepGoing)
        precondition(deepCounter.didStop)
        precondition(deepWalker.cancelled > 0, "cancellation must reach the recursive walk")
        precondition(deepWalker.dirs < 125, "cancelled walk must stop early, not read every directory")
        precondition(deepWalker.files < 2_500, "cancelled walk must not finish every file")
        precondition(deepIndex.roots[deep.path] == nil, "a cancelled root is unknown, not a partial total")

        // ④ 多个根在第一个根就取消：不能越界，也不能给没走到的根造 0
        var multi: [String] = []
        for index in 0..<3 {
            let dir = root.appendingPathComponent("multi-\(index)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<1_000 { try Data().write(to: dir.appendingPathComponent("f-\(f)")) }
            multi.append(dir.path)
        }
        let multiCounter = Counter(stopAfter: 1)
        let multiWalker = BulkWalker()
        let multiIndex = multiWalker.measure(roots: multi, targets: [], dirDepth: 6, dirThreshold: 0,
                                             skip: [], shouldContinue: multiCounter.keepGoing)
        precondition(multiWalker.cancelled > 0)
        precondition(multiIndex.roots.isEmpty, "roots not walked stay unknown")

        // ⑤ 回调 false 一次后又 true：complete 仍然必须是 false，不能把半截结果当完整报告
        let flip = OneShotFalse()
        let walk = ScanPipeline.folderWalk(roots: [deep.path], systemRoots: [], threshold: 0,
                                           shouldContinue: flip.keepGoing)
        precondition(walk.complete == false, "a cancelled walk can never be reported complete")

        print("bulk cancellation ok")
    }
}
