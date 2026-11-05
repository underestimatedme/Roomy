// SPDX-License-Identifier: GPL-3.0-only
// 测量完整性：全部用真实生成的临时目录树，不手工拼 complete 字典。
// 覆盖：完整/嵌套、不可读兄弟、符号链接不跟随、硬链接口径、取消、旧记录失效、同批 proof 复用。
import Darwin
import Foundation

@main struct MeasurementCompletenessTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporary.hasPrefix("/var/") ? "/private" + temporary : temporary)
            .appendingPathComponent("roomy-measure-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func path(_ relative: String) -> String { root.path + "/" + relative }
        func file(_ relative: String, _ bytes: Int) throws {
            let target = path(relative)
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: target))
        }
        // 实际占用按磁盘上的 st_blocks 算，和 BulkWalker 的口径（ATTR_FILE_ALLOCSIZE）一致
        func allocated(_ target: String) -> UInt64 {
            var st = stat()
            precondition(lstat(target, &st) == 0, "fixture must exist: " + target)
            return UInt64(st.st_blocks) * 512
        }
        let permissionChecks = geteuid() != 0

        // ① 真实生成的树：完整，且嵌套目标在同一次遍历里各自作证
        try file("complete/alpha/a.bin", 200_000)
        try file("complete/alpha/root.bin", 8_000)
        try file("complete/alpha/beta/b.bin", 100_000)
        try file("complete/alpha/beta/gamma/c.bin", 50_000)
        let alpha = path("complete/alpha"), beta = alpha + "/beta", gamma = beta + "/gamma"
        let alphaExpected = allocated(alpha + "/root.bin") + allocated(alpha + "/a.bin")
            + allocated(beta + "/b.bin") + allocated(gamma + "/c.bin")
        let complete = BulkWalker().measureTargetsDetailed([alpha, beta, gamma])
        precondition(complete.sizes[alpha] == alphaExpected, "a complete tree must add up to the real allocated bytes")
        precondition(complete.sizes[beta] == allocated(beta + "/b.bin") + allocated(gamma + "/c.bin"),
                     "a nested target must be measured inside the same walk")
        precondition(complete.sizes[gamma] == allocated(gamma + "/c.bin"), "a leaf target must carry its own size")
        for target in [alpha, beta, gamma] {
            precondition(complete.measurement(for: target)?.completeness == .complete,
                         "a readable tree must be complete: " + target)
        }

        // ② 有不可读兄弟：父目标锁定为不完整，可读的独立子目标仍然完整
        try file("denied/parent/readable/ok.bin", 40_000)
        try file("denied/parent/locked/secret.bin", 40_000)
        let deniedParent = path("denied/parent"), readable = deniedParent + "/readable", locked = deniedParent + "/locked"
        if permissionChecks {
            precondition(chmod(locked, 0) == 0, "sample permission change must succeed")
            defer { _ = chmod(locked, 0o755) }
            let siblings = BulkWalker().measureTargetsDetailed([deniedParent, readable, locked])
            let parentProof = siblings.measurement(for: deniedParent)
            precondition(parentProof?.completeness == .incomplete,
                         "an unreadable sibling must leave the parent incomplete")
            precondition(parentProof?.size == allocated(readable + "/ok.bin"),
                         "the parent still reports what it could read, never zero")
            let readableProof = siblings.measurement(for: readable)
            precondition(readableProof?.completeness == .complete && readableProof?.size == allocated(readable + "/ok.bin"),
                         "a readable sibling target stays complete on its own walk")
            let lockedProof = siblings.measurement(for: locked)
            precondition(lockedProof?.completeness == .incomplete && lockedProof?.size == nil,
                         "an unreadable target must be locked without a size")
        } else {
            print("MeasurementCompletenessTests: root account, unreadable-directory checks skipped")
        }

        // ③ 符号链接不跟随：文件链接和目录链接都是 unknown，且目标字节不算进父目录
        try file("links/parent/target.bin", 120_000)
        try file("links/outside/payload.bin", 60_000)
        let linkParent = path("links/parent")
        let fileLink = linkParent + "/target-link", dirLink = linkParent + "/outside-link"
        precondition(symlink("target.bin", fileLink) == 0, "file symlink fixture must be created")
        precondition(symlink("../outside", dirLink) == 0, "directory symlink fixture must be created")
        let linked = BulkWalker().measureTargetsDetailed([linkParent, fileLink, dirLink])
        precondition(linked.sizes[linkParent] == allocated(linkParent + "/target.bin"),
                     "a symlink must not add its target's bytes to the parent")
        let fileLinkProof = linked.measurement(for: fileLink)
        precondition(fileLinkProof?.completeness == .unknown && fileLinkProof?.size == 0,
                     "a file symlink is unknown, never followed")
        precondition(linked.measurement(for: dirLink)?.completeness == .unknown,
                     "a directory symlink is unknown, never followed")

        // ④ 硬链接口径保持：同一 inode 只算一次
        try file("hard/one.bin", 90_000)
        let one = path("hard/one.bin"), two = path("hard/two.bin")
        precondition(link(one, two) == 0, "hard link fixture must be created")
        let once = allocated(one)
        let hardTree = BulkWalker().measureTargetsDetailed([path("hard")])
        precondition(hardTree.sizes[path("hard")] == once, "hard-linked bytes must be counted once in the parent")
        precondition(hardTree.measurement(for: path("hard"))?.completeness == .complete,
                     "a hard-linked subtree is still a complete read")
        let perName = BulkWalker().measureTargetsDetailed([one, two])
        let hardSizes = perName.sizes
        precondition(hardSizes.count == 2, "both names must be reported")
        precondition(hardSizes.values.reduce(0, +) == once && hardSizes.values.min() == 0 && hardSizes.values.max() == once,
                     "measuring both names of one inode must still total the bytes once")

        // ⑤ 取消：文件、目录都不算完整
        try file("cancel/single.bin", 20_000)
        try file("cancel/tree/a.bin", 20_000)
        try file("cancel/tree/sub/b.bin", 20_000)
        let single = path("cancel/single.bin"), tree = path("cancel/tree")
        let cancelledFile = BulkWalker().sizeDetailed(of: single, shouldContinue: { false })
        precondition(cancelledFile.completeness == .incomplete && cancelledFile.size == nil,
                     "a cancelled file read is not complete")
        let cancelledTree = BulkWalker().sizeDetailed(of: tree, shouldContinue: { false })
        precondition(cancelledTree.completeness == .incomplete && cancelledTree.size == nil,
                     "a cancelled directory read is not complete")
        var calls = 0
        let late = BulkWalker().sizeDetailed(of: tree, shouldContinue: { calls += 1; return calls < 2 })
        precondition(late.completeness == .incomplete, "cancelling mid-walk must not report a complete subtree")
        let walker = BulkWalker()
        let counted = walker.sizeDetailed(of: tree, shouldContinue: { false })
        precondition(counted.completeness == .incomplete && walker.cancelled > 0,
                     "a cancelled measurement must be counted as cancelled, not failed")
        let healthy = BulkWalker().sizeDetailed(of: tree)
        precondition(healthy.completeness == .complete
            && healthy.size == allocated(tree + "/a.bin") + allocated(tree + "/sub/b.bin"),
                     "the same tree read without cancellation must be complete")

        // ⑥ 旧的完整记录不能盖过之后读坏的子项
        try file("record/parent/child/deep.bin", 30_000)
        let recParent = path("record/parent"), recChild = recParent + "/child"
        let record = MeasuredSubtrees(depth: 5, threshold: 0)
        let firstRun = BulkWalker().measureTargetsDetailed([recParent], record: record)
        precondition(firstRun.measurement(for: recParent)?.completeness == .complete && record.count == 1,
                     "a clean walk must record the subtree once")
        let trie = PathTrie()
        record.plant(in: trie, targets: [], skip: [], dirThreshold: 0)
        precondition(trie.node(for: recParent)?.reused != nil,
                     "the recorded subtree must be reusable while it is trusted")
        if permissionChecks {
            precondition(chmod(recChild, 0) == 0, "sample permission change must succeed")
            let brokenChild = BulkWalker().measureTargetsDetailed([recChild], record: record)
            precondition(brokenChild.measurement(for: recChild)?.completeness == .incomplete,
                         "an unreadable child must be incomplete")
            precondition(record.count == 0, "a later failing child must invalidate the earlier complete parent")
            let afterTrie = PathTrie()
            record.plant(in: afterTrie, targets: [], skip: [], dirThreshold: 0)
            precondition(afterTrie.node(for: recParent)?.reused == nil,
                         "an invalidated parent must never be planted as complete")
            precondition(chmod(recChild, 0o755) == 0, "sample permissions must be restored")
        }
        // 反过来：父目录读坏时，它里面记过的子树也不能再单独当完整证据
        let childRun = BulkWalker().measureTargetsDetailed([recChild], record: record)
        precondition(childRun.measurement(for: recChild)?.completeness == .complete && record.count == 1,
                     "a fresh complete walk must be recorded again")
        if permissionChecks {
            precondition(chmod(recChild, 0) == 0, "sample permission change must succeed")
            let brokenParent = BulkWalker().measureTargetsDetailed([recParent], record: record)
            precondition(brokenParent.measurement(for: recParent)?.completeness == .incomplete,
                         "a parent with an unreadable child must be incomplete")
            precondition(record.count == 0, "a failing parent must invalidate the subtrees recorded inside it")
            precondition(chmod(recChild, 0o755) == 0, "sample permissions must be restored")
        }

        // ⑦ 同批 proof：batch 对得上才复用，对不上退回独立复核
        try file("cache/tree/part-a.bin", 300_000)
        try file("cache/tree/nested/part-b.bin", 200_000)
        let cachePath = path("cache/tree")
        func cacheCandidate() -> CleanupCandidate {
            var candidate = CleanupCandidate(source: "appcache", key: cachePath, title: "缓存 · sample",
                                             size: ToolProbes.placeholder, evidence: "fixture", risk: .green, action: nil)
            candidate.entry.path = cachePath
            return candidate
        }
        let expected = allocated(cachePath + "/part-a.bin") + allocated(cachePath + "/nested/part-b.bin")
        let proof = BulkWalker().measureTargetsDetailed([cachePath])
        precondition(proof.measurement(for: cachePath)?.completeness == .complete && proof.sizes[cachePath] == expected,
                     "the cache fixture must measure complete")
        var verifies = 0
        let trusted = ToolProbes.sized([cacheCandidate()], sizePaths: [cachePath], index: SizeIndex.from(proof),
                                       measurement: proof, verify: { _ in verifies += 1; return nil })
        precondition(verifies == 0 && trusted.first?.entry.size == expected && trusted.first?.action == nil,
                     "a same-batch complete proof must be reused without an independent verify")
        // 同一路径、同一大小的另一次测量：batch 不同，不许复用
        let second = BulkWalker().measureTargetsDetailed([cachePath])
        precondition(second.batch != proof.batch && second.sizes[cachePath] == expected,
                     "the second walk must be a different batch with the same size")
        var mismatched = 0
        let fallback = ToolProbes.sized([cacheCandidate()], sizePaths: [cachePath], index: SizeIndex.from(proof),
                                        measurement: second, verify: { _ in mismatched += 1; return nil })
        precondition(mismatched == 1, "a proof from another batch must fall back to exactly one independent verify")
        precondition(fallback.first?.entry.size == 0 && fallback.first?.action == nil
            && fallback.first?.entry.selectable == false,
                     "an unverifiable cache must stay an explicit locked notice")
        var unproven = 0
        _ = ToolProbes.sized([cacheCandidate()], sizePaths: [cachePath], index: SizeIndex.from(proof),
                             verify: { _ in unproven += 1; return nil })
        precondition(unproven == 1, "without a proof the independent verify must run exactly once")
        var untaggedIndex = SizeIndex()
        untaggedIndex.targets = proof.sizes
        var untagged = 0
        _ = ToolProbes.sized([cacheCandidate()], sizePaths: [cachePath], index: untaggedIndex,
                             measurement: proof, verify: { _ in untagged += 1; return nil })
        precondition(untagged == 1, "an index without a batch marker must not trust any proof")

        // 不完整的同批 proof 直接锁定，不重新遍历
        try file("cache/tree/nested/blocked/secret.bin", 10_000)
        if permissionChecks {
            let blocked = cachePath + "/nested/blocked"
            precondition(chmod(blocked, 0) == 0, "sample permission change must succeed")
            defer { _ = chmod(blocked, 0o755) }
            let partial = BulkWalker().measureTargetsDetailed([cachePath])
            let partialProof = partial.measurement(for: cachePath)
            precondition(partialProof?.completeness == .incomplete && partialProof?.size != nil,
                         "a partially readable cache must be incomplete with a partial size")
            var partialVerifies = 0
            let lockedNotice = ToolProbes.sized([cacheCandidate()], sizePaths: [cachePath], index: SizeIndex.from(partial),
                                                measurement: partial, verify: { _ in partialVerifies += 1; return nil })
            precondition(partialVerifies == 0 && lockedNotice.first?.entry.size == 0 && lockedNotice.first?.action == nil
                && lockedNotice.first?.entry.selectable == false,
                         "an incomplete same-batch proof must be locked without re-verifying")
            // 不同 batch 且文件现在读不了：独立复核拿不到大小，必须锁定
            var lateVerifies = 0
            let lateLocked = ToolProbes.sized([cacheCandidate()], sizePaths: [cachePath], index: SizeIndex.from(proof),
                                              measurement: second, verify: { target in
                lateVerifies += 1
                return ApplicationSession.measure(target)
            })
            precondition(lateVerifies == 1 && lateLocked.first?.entry.size == 0 && lateLocked.first?.action == nil
                && lateLocked.first?.entry.selectable == false,
                         "a mismatched proof over a now-unreadable cache must lock, never authorize")
        }

        // ⑧ 增长对比的一级目录：阈值只影响排行，不应把跨过阈值的小目录当成新增/移除
        try file("growth/small/one.bin", 1_000)
        try file("growth/large/big.bin", 40_000)
        let growthRoot = path("growth")
        let withoutSmall = BulkWalker().measure(roots: [growthRoot], targets: [], dirDepth: 1,
                                                dirThreshold: 10_000, skip: [])
        precondition(withoutSmall.dirs[growthRoot + "/large"] != nil,
                     "a large first-level directory is ranked")
        precondition(withoutSmall.dirs[growthRoot + "/small"] == nil,
                     "without the growth flag a small first-level directory is below threshold")
        let beforeCross = BulkWalker().measure(roots: [growthRoot], targets: [], dirDepth: 1,
                                               dirThreshold: 10_000, skip: [], includeAllRootChildren: true)
        precondition(beforeCross.dirs[growthRoot + "/small"] != nil,
                     "the growth flag keeps every direct child even below the threshold")
        precondition(beforeCross.dirs[growthRoot + "/large"] != nil,
                     "the growth flag keeps large children too")
        precondition(beforeCross.roots[growthRoot] == allocated(growthRoot + "/small/one.bin")
            + allocated(growthRoot + "/large/big.bin"),
                     "totals still include files, only the ranking threshold is bypassed")
        let walkedGrowth = ScanPipeline.folderWalk(roots: [growthRoot], systemRoots: [], threshold: 10_000)
        precondition(walkedGrowth.dirs[growthRoot + "/small"] != nil,
                     "folderWalk keeps small first-level directories for growth comparison")
        try file("growth/small/more.bin", 20_000)
        let afterCross = BulkWalker().measure(roots: [growthRoot], targets: [], dirDepth: 1,
                                              dirThreshold: 10_000, skip: [], includeAllRootChildren: true)
        precondition(afterCross.dirs[growthRoot + "/small"] != nil,
                     "a first-level directory stays present after crossing the threshold")
        precondition(afterCross.roots[growthRoot] == allocated(growthRoot + "/small/one.bin")
            + allocated(growthRoot + "/small/more.bin") + allocated(growthRoot + "/large/big.bin"),
                     "the re-measured total includes the new file")
        let rankedAfter = BulkWalker().measure(roots: [growthRoot], targets: [], dirDepth: 1,
                                               dirThreshold: 10_000, skip: [])
        precondition(rankedAfter.dirs[growthRoot + "/small"] != nil,
                     "after crossing the threshold it is ranked even without the growth flag")

        // ⑨ 深层读坏：记所属并行任务路径，整根不能当完整快照
        try file("gap/level1/level2/level3/secret.bin", 10_000)
        let gapRoot = path("gap"), gapTask = gapRoot + "/level1/level2"
        if permissionChecks {
            precondition(chmod(path("gap/level1/level2/level3"), 0) == 0, "sample permission change must succeed")
            defer { _ = chmod(path("gap/level1/level2/level3"), 0o755) }
            let gapIndex = BulkWalker().measure(roots: [gapRoot], targets: [], dirDepth: 6,
                                                dirThreshold: 0, skip: [])
            precondition(gapIndex.unreadable.contains(gapTask),
                         "a deep unreadable directory must mark its owning parallel task, not every descendant")
            precondition(!SpaceGrowthStore.coverageComplete(root: gapRoot, unreadable: gapIndex.unreadable),
                         "a root with a deep gap cannot become a complete growth snapshot")
            precondition(SpaceGrowthStore.coverageComplete(root: gapRoot + "-other", unreadable: gapIndex.unreadable),
                         "a sibling root with a similar prefix is not affected")
        }

        print("MeasurementCompletenessTests passed: real trees complete/nested, unreadable siblings locked, symlinks not followed, hard-link accounting, cancellation, record invalidation, same-batch proof reuse, first-level growth coverage, deep task gap")
    }
}
