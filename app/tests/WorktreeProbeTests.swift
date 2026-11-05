// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        lock.lock(); recorded.append(arguments); lock.unlock()   // 探测器会并发调用
        return ProcessRunner().run(executable, arguments, timeout: timeout)
    }
}

@discardableResult
private func git(_ args: [String], in dir: String) -> CommandResult {
    let r = ProcessRunner().run("/usr/bin/git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args, timeout: 20)
    precondition(r.ok, "git \(args) failed: \(r.stderr)")
    return r
}

@main
struct WorktreeProbeTests {
    static func main() throws {
        let porcelain = """
        worktree /code/repo
        HEAD aaa
        branch refs/heads/main

        worktree /code/.worktrees/done
        HEAD bbb
        branch refs/heads/codex/done

        worktree /code/.worktrees/detached
        HEAD ccc
        detached

        worktree /code/.worktrees/held
        HEAD ddd
        branch refs/heads/codex/held
        locked

        """
        precondition(WorktreeProbe.parsePorcelain(porcelain)
            == [.init(path: "/code/.worktrees/done", branch: "codex/done")], "\(WorktreeProbe.parsePorcelain(porcelain))")

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-wt-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let root = realpath(tmp, nil).map { p in defer { free(p) }; return String(cString: p) }!   // git 报告的是真实路径
        defer { try? fm.removeItem(atPath: root) }
        let repo = root + "/proj/repo"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repo)
        try "a".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: repo); git(["commit", "-q", "-m", "init"], in: repo)

        let wts = root + "/proj/.worktrees"
        git(["worktree", "add", "-q", "-b", "codex/merged", wts + "/merged"], in: repo)
        git(["worktree", "add", "-q", "-b", "codex/dirty", wts + "/dirty"], in: repo)
        try "x".write(toFile: wts + "/dirty/new.txt", atomically: true, encoding: .utf8)
        git(["worktree", "add", "-q", "-b", "codex/ahead", wts + "/ahead"], in: repo)
        try "b".write(toFile: wts + "/ahead/b.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: wts + "/ahead"); git(["commit", "-q", "-m", "ahead"], in: wts + "/ahead")

        // 有自己提交、已快进合入 main 的分支（真正"做完了"的任务）
        git(["worktree", "add", "-q", "-b", "codex/shipped", wts + "/shipped"], in: repo)
        try "s".write(toFile: wts + "/shipped/s.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: wts + "/shipped"); git(["commit", "-q", "-m", "shipped"], in: wts + "/shipped")
        git(["merge", "-q", "--ff-only", "codex/shipped"], in: repo)
        // 同样已合入，但有一个被仓库配置藏起来的未跟踪文件
        git(["worktree", "add", "-q", "-b", "codex/quiet", wts + "/quiet"], in: repo)
        try "q".write(toFile: wts + "/quiet/q.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: wts + "/quiet"); git(["commit", "-q", "-m", "quiet"], in: wts + "/quiet")
        git(["merge", "-q", "--ff-only", "codex/quiet"], in: repo)
        try "secret".write(toFile: wts + "/quiet/Unsaved.swift", atomically: true, encoding: .utf8)
        // 提交时间是 60 天前，但 worktree 今天还被动过（index 是新的）
        git(["worktree", "add", "-q", "-b", "codex/old", wts + "/old"], in: repo)
        try "o".write(toFile: wts + "/old/o.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: wts + "/old")
        let oldCommit = Process()
        oldCommit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        oldCommit.arguments = ["-C", wts + "/old", "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false",
                               "commit", "-q", "-m", "old"]
        let sixtyDaysAgo = "\(Int(Date().timeIntervalSince1970) - 60 * 86_400) +0000"
        oldCommit.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_COMMITTER_DATE": sixtyDaysAgo, "GIT_AUTHOR_DATE": sixtyDaysAgo]) { $1 }
        try oldCommit.run(); oldCommit.waitUntilExit()
        precondition(oldCommit.terminationStatus == 0)
        git(["merge", "-q", "--ff-only", "codex/old"], in: repo)
        git(["config", "status.showUntrackedFiles", "no"], in: repo)

        // 第二个仓库：主工作区在别的分支上，worktree 签出的就是 main 本身 → 不算"已合入"的临时 worktree
        let repo2 = root + "/proj2/repo2"
        try fm.createDirectory(atPath: repo2, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repo2)
        git(["commit", "-q", "--allow-empty", "-m", "init"], in: repo2)
        git(["switch", "-q", "-c", "feature"], in: repo2)
        git(["worktree", "add", "-q", root + "/proj2/.worktrees/on-main", "main"], in: repo2)

        let discovered = WorktreeProbe.findRepositories(roots: [root])
        precondition(discovered.contains(repo) && discovered.contains(repo2) && discovered.contains(root + "/proj/.worktrees/merged"),
            "main and hidden linked repositories must both locate their registry: \(discovered)")
        precondition(Set(discovered).count == discovered.count)

        let tools = ToolLocator()
        let later = Date().addingTimeInterval(30 * 86_400)
        let recorder = RecordingRunner()
        let found = WorktreeProbe.probe(roots: [root], runner: recorder, tools: tools, now: later, sizeOf: { _ in 1_000 })
        let titles = found.map(\.entry.title).sorted()
        // 已合入但有本地修改的工作树也展示，仍禁止整棵清理；ahead 有未合入的提交，作为"不能删"展示。
        precondition(titles == ["Worktree · ahead（repo）", "Worktree · dirty（repo）", "Worktree · merged（repo）", "Worktree · old（repo）", "Worktree · quiet（repo）", "Worktree · shipped（repo）"], "\(titles)")
        precondition(found.filter { $0.entry.title.contains("dirty") || $0.entry.title.contains("quiet") }.allSatisfy { !$0.entry.selectable })
        precondition(found.filter { $0.entry.title.contains("dirty") || $0.entry.title.contains("ahead") }
            .allSatisfy { $0.entry.tier == .locked && $0.action == nil && $0.entry.lockReason != nil })
        // Merge checks use immutable complete OIDs, never option-like branch names.
        let mergeChecks = recorder.calls.filter { $0.contains("merge-base") }
        precondition(!mergeChecks.isEmpty && mergeChecks.allSatisfy { $0.suffix(2).allSatisfy(GitWorktreeMerge.oid) })
        // 没有任何自己提交的分支"已合入"是平凡成立的：只列出，不默认勾选
        let merged = found.first { $0.entry.title.contains("merged") }!
        precondition(!merged.entry.defaultChecked && merged.entry.risk == .amber, "zero-commit branch must not be pre-checked")
        precondition(merged.entry.evidence.contains("没有自己的提交"), merged.entry.evidence)
        let shipped = found.first { $0.entry.title.contains("shipped") }!
        precondition(shipped.entry.defaultChecked && shipped.entry.reversible, "30 days idle + merged + clean → pre-checked")
        precondition(shipped.entry.evidence.contains("分支 codex/shipped 已合入 main"), shipped.entry.evidence)
        precondition(shipped.entry.evidence.contains("被忽略的文件"), shipped.entry.evidence)
        guard case .worktreeRemove(let item, let r, let branch, let base) = shipped.action else { preconditionFailure("action") }
        precondition(item.path == wts + "/shipped" && r == repo && branch == "codex/shipped" && base == "refs/heads/main")
        precondition(item.identity != nil)

        let fresh = WorktreeProbe.probe(roots: [root], runner: ProcessRunner(), tools: tools, now: Date(), sizeOf: { _ in 1 })
        precondition(fresh.allSatisfy { !$0.entry.defaultChecked }, "committed today → not pre-checked")
        // old 的提交是 60 天前，但 index 今天才动过 → 按最近一次活动算，不默认勾选
        precondition(fresh.contains { $0.entry.title.contains("old") }, "\(fresh.map(\.entry.title))")

        // AI 代理把 worktree 建在代码目录之外（如 ~/.codex/worktrees）：把那个目录加进 roots 就能找到
        git(["worktree", "add", "-q", "-b", "codex/agent", root + "/agent/task-1"], in: repo)
        try "a".write(toFile: root + "/agent/task-1/a2.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: root + "/agent/task-1"); git(["commit", "-q", "-m", "agent"], in: root + "/agent/task-1")
        git(["merge", "-q", "--ff-only", "codex/agent"], in: repo)
        let withAgent = WorktreeProbe.probe(roots: [root + "/proj", root + "/agent"], runner: ProcessRunner(), tools: tools,
                                            now: later, sizeOf: { _ in 1 })
        precondition(withAgent.contains { $0.entry.title == "Worktree · task-1（repo）" }, "\(withAgent.map(\.entry.title))")
        // ~/.codex/worktrees/<任务>/<仓库>：标题写任务名，否则所有任务都叫"Valley"
        git(["worktree", "add", "-q", "-b", "codex/named", root + "/agent/keji-release/repo"], in: repo)
        try "n".write(toFile: root + "/agent/keji-release/repo/n.txt", atomically: true, encoding: .utf8)
        git(["add", "."], in: root + "/agent/keji-release/repo"); git(["commit", "-q", "-m", "n"], in: root + "/agent/keji-release/repo")
        git(["merge", "-q", "--ff-only", "codex/named"], in: repo)
        let named = WorktreeProbe.probe(roots: [root + "/proj", root + "/agent"], runner: ProcessRunner(), tools: tools,
                                        now: later, sizeOf: { _ in 1 })
        precondition(named.contains { $0.entry.title == "Worktree · keji-release（repo）" }, "\(named.map(\.entry.title))")
        try fm.createDirectory(atPath: root + "/agent-home/.codex/worktrees", withIntermediateDirectories: true)
        precondition(ToolProbes.worktreeRoots(codeRoots: ["/opt/coding"], home: root + "/agent-home")
                     == ["/opt/coding", root + "/agent-home/.codex/worktrees"])

        // 范围之外的 worktree 不列
        precondition(WorktreeProbe.probe(roots: [root + "/elsewhere"], runner: ProcessRunner(), tools: tools,
            now: later, sizeOf: { _ in 1 }).isEmpty)

        // Git status excludes ignored payload; merged source is not sufficient authorization.
        try "\n.local-data/\n".write(toFile: repo + "/.git/info/exclude", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: wts + "/shipped/.local-data", withIntermediateDirectories: true)
        try "only copy".write(toFile: wts + "/shipped/.local-data/OnlyCopy.swift", atomically: true, encoding: .utf8)
        let ignored = WorktreeProbe.probe(roots: [root], runner: ProcessRunner(), tools: tools, now: later, sizeOf: { _ in 1000 })
        precondition(!ignored.contains { $0.targetPath == wts + "/shipped" && $0.entry.selectable }, "ignored source must block whole-worktree cleanup")
        precondition(WorktreeProbe.blocker(path: wts + "/shipped", repo: repo, branch: "codex/shipped", base: "main",
            runner: ProcessRunner(), tools: tools) != nil, "late ignored data must be rechecked before execution")
        try fm.removeItem(atPath: wts + "/shipped/.local-data")

        // 复核：扫描后又有了改动 → 拒绝
        precondition(WorktreeProbe.blocker(path: wts + "/merged", repo: repo, branch: "codex/merged", base: "main",
            runner: ProcessRunner(), tools: tools) == nil)
        try "late".write(toFile: wts + "/merged/late.txt", atomically: true, encoding: .utf8)
        precondition(WorktreeProbe.blocker(path: wts + "/merged", repo: repo, branch: "codex/merged", base: "main",
            runner: ProcessRunner(), tools: tools) == "这个 worktree 有未提交的改动")
        precondition(WorktreeProbe.blocker(path: wts + "/ahead", repo: repo, branch: "codex/ahead", base: "main",
            runner: ProcessRunner(), tools: tools) == "分支还没合入 main")
        // 复核：扫描后 worktree 切到了游离 HEAD 并提交（工作区仍干净）→ 拒绝，否则那个提交会变成孤儿
        precondition(WorktreeProbe.blocker(path: wts + "/shipped", repo: repo, branch: "codex/shipped", base: "main",
            runner: ProcessRunner(), tools: tools) == nil)
        git(["checkout", "-q", "--detach"], in: wts + "/shipped")
        git(["commit", "-q", "--allow-empty", "-m", "detached work"], in: wts + "/shipped")
        precondition(WorktreeProbe.blocker(path: wts + "/shipped", repo: repo, branch: "codex/shipped", base: "main",
            runner: ProcessRunner(), tools: tools) == "这个 worktree 已经不在 codex/shipped 上了")
        // Ignored data inside a tracked submodule is invisible to superproject status/ls-files.
        let module = root + "/.module-source"
        try fm.createDirectory(atPath: module, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: module)
        try "*.env\n".write(toFile: module + "/.gitignore", atomically: true, encoding: .utf8)
        git(["add", "."], in: module); git(["commit", "-q", "-m", "module"], in: module)
        let host = root + "/submodule/repo", nestedWT = root + "/submodule/worktree"
        try fm.createDirectory(atPath: host, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: host)
        git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", module, "lib"], in: host)
        git(["commit", "-q", "-m", "add module"], in: host)
        git(["worktree", "add", "-q", "-b", "task", nestedWT], in: host)
        git(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q"], in: nestedWT)
        try "unique config".write(toFile: nestedWT + "/lib/private.env", atomically: true, encoding: .utf8)
        precondition(git(["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], in: nestedWT).stdout.isEmpty)
        let nestedFound = WorktreeProbe.probe(roots: [root + "/submodule"], runner: ProcessRunner(), tools: tools, now: later, sizeOf: { _ in 1000 })
        precondition(!nestedFound.contains { $0.targetPath == nestedWT && $0.entry.selectable }, "submodule local data must not be hidden by superproject checks")
        precondition(WorktreeProbe.blocker(path: nestedWT, repo: host, branch: "task", base: "main", runner: ProcessRunner(), tools: tools) != nil)
        print("WorktreeProbeTests passed")
    }
}
