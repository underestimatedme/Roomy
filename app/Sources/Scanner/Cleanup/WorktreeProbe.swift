// SPDX-License-Identifier: GPL-3.0-only
// AI 编程代理每个任务开一个 git worktree，做完合进主干就再没人管。
// 已合入与可清理分别判断；目录进废纸篓，不 prune，分支保留。

import Foundation

enum WorktreeProbe {
    struct Worktree: Equatable {
        let path: String
        let branch: String?
        var head: String? = nil
    }

    static func parsePorcelain(_ text: String) -> [Worktree] {
        let nul = text.contains("\0")
        let blocks = text.components(separatedBy: nul ? "\0\0" : "\n\n")
        return blocks.dropFirst().compactMap { block in
            var path: String?, branch: String?, head: String?, skip = false, detached = false
            for line in block.components(separatedBy: nul ? "\0" : "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
                else if line.hasPrefix("HEAD ") {
                    let value = String(line.dropFirst(5))
                    if GitWorktreeMerge.oid(value) { head = value }
                }
                else if line == "detached" { detached = true }
                else if line == "bare" || line.hasPrefix("locked") || line.hasPrefix("prunable") { skip = true }
            }
            guard !skip, let path, path.hasPrefix("/"), branch != nil || (detached && head != nil),
                  !(detached && branch != nil) else { return nil }
            return Worktree(path: path, branch: branch, head: head)
        }
    }

    /// Main repositories and linked checkouts can both locate the shared worktree registry.
    static func findRepositories(roots: [String], maxDepth: Int = 8) -> [String] {
        // This phase locates markers only; probe() asks Git to validate the common
        // registry before using any result. Share bounded directory enumeration,
        // hidden-worktree handling and dependency pruning with root discovery.
        let canonical = roots.map { root in realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root }
        return GitRepositoryDiscovery.discover(searchRoots: canonical, maxDepth: maxDepth,
            secondsPerRoot: 4, validateMarkers: false).repositories
    }

    /// git 命令大多在等进程启动，不吃 CPU：并发数比核数小一点就够
    static let workers = 8

    /// 按下标并发计算、按原顺序返回
    static func concurrentMap<T, R>(_ items: [T], _ transform: (T) -> R?) -> [R?] {
        var out = [R?](repeating: nil, count: items.count)
        out.withUnsafeMutableBufferPointer { slots in
            guard let base = slots.baseAddress, !items.isEmpty else { return }
            DispatchQueue.concurrentPerform(iterations: min(workers, items.count)) { worker in
                for i in stride(from: worker, to: items.count, by: workers) { base[i] = transform(items[i]) }
            }
        }
        return out
    }

    static func probe(roots: [String], runner: CommandRunning, tools: ToolLocator, now: Date = Date(),
                      sizeOf: (String) -> UInt64? = { BulkWalker().size(of: $0) }) -> [CleanupCandidate] {
        guard let git = tools.path(for: .git) else { return [] }
        // git 报告的是解析过符号链接的真实路径（/var → /private/var），根目录也要按真实路径比
        // 注意：Foundation 的 resolvingSymlinksInPath 会故意去掉 /private 前缀，所以用 realpath(3)
        let realRoots = roots.map { root in realpath(root, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root }
        var out: [CleanupCandidate] = []
        // 先按仓库列出所有 worktree（很快），再并发做每个 worktree 的 git 检查（每个要跑好几条 git 命令）
        struct Job { let repo: String; let bases: [GitWorktreeMerge.Base]; let wt: Worktree }
        var jobs: [Job] = []
        var seenRepositories = Set<String>(), seenPaths = Set<String>()
        // 每个仓库的 git 查询互不相关：并发跑完，再按发现顺序去重、组装，结果与逐个跑一样
        let discovered = findRepositories(roots: roots)
        let registries = concurrentMap(discovered) { dir -> String? in
            let common = runner.run(git, ["-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 10)
            guard common.ok, common.stderr.isEmpty else { return nil }
            let registry = common.stdout.trimmingCharacters(in: .newlines)
            return registry.isEmpty ? nil : registry
        }
        let unique = zip(discovered, registries).compactMap { dir, registry in
            registry.flatMap { seenRepositories.insert($0).inserted ? dir : nil }
        }
        let listed = concurrentMap(unique) { dir -> (list: String, repo: String, bases: [GitWorktreeMerge.Base])? in
            let list = runner.run(git, ["-C", dir, "worktree", "list", "--porcelain", "-z"], timeout: 10)
            guard list.ok, list.stderr.isEmpty, list.stdout.hasPrefix("worktree "),
                  let first = list.stdout.components(separatedBy: "\0").first else { return nil }
            let repo = String(first.dropFirst("worktree ".count))
            return (list.stdout, repo, GitWorktreeMerge.bases(repo: repo, git: git, runner: runner))
        }
        for case let (listOutput, repo, bases)? in listed {
            guard !bases.isEmpty else { continue }
            // 签出的就是主干本身（main / origin/main 对应的本地分支）的 worktree，多半是有人当工作区在用，不列
            let baseBranches = Set(bases.map { $0.ref.hasPrefix("refs/remotes/origin/") ? String($0.ref.dropFirst("refs/remotes/origin/".count)) : String($0.ref.dropFirst("refs/heads/".count)) })
            for wt in parsePorcelain(listOutput) where wt.branch.map({ !baseBranches.contains($0) }) ?? true {
                guard realRoots.contains(where: { wt.path == $0 || wt.path.hasPrefix($0 + "/") }), isDirectory(wt.path),
                      seenPaths.insert(wt.path).inserted else { continue }
                jobs.append(Job(repo: repo, bases: bases, wt: wt))
            }
        }
        var results = [CleanupCandidate?](repeating: nil, count: jobs.count)
        results.withUnsafeMutableBufferPointer { slots in
            guard let base0 = slots.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: min(workers, jobs.count)) { worker in
              for i in stride(from: worker, to: jobs.count, by: workers) {
                let job = jobs[i], repo = job.repo, wt = job.wt
                // 先读活动时间：之后的 git status 不该影响它
                let active = lastActivity(wt.path, git: git, runner: runner)
                guard let head = wt.head, let size = sizeOf(wt.path), size > 0 else { continue }
                let clean = isClean(wt.path, git: git, runner: runner)
                let days = active.map { Int(now.timeIntervalSince1970 - $0) / 86_400 } ?? 0
                let idle = Humanize.span(days: days).map { "\($0)没动过" } ?? "今天还动过"
                // ~/.codex/worktrees/<任务>/<仓库>：目录名就是仓库名时，用上一级的任务名
                let repoName = (repo as NSString).lastPathComponent
                var leaf = (wt.path as NSString).lastPathComponent
                if leaf == repoName { leaf = ((wt.path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
                let title = "Worktree · \(leaf)（\(repoName)）"
                let dirtyNote = "有未提交的改动或无法完整检查"
                // 不能删：没有动作，只留原因；路径放在 entry 上，方便按路径找到它
                func locked(_ reason: String, evidence: String) -> CleanupCandidate {
                    var c = CleanupCandidate(source: "worktree", key: wt.path, title: title, size: size,
                        evidence: evidence, risk: .amber, action: nil).locked(reason)
                    c.entry.path = wt.path
                    return c
                }
                guard let match = GitWorktreeMerge.match(head: head, bases: job.bases, repo: repo, git: git, runner: runner),
                      wt.branch != nil || match.ancestor else {
                    // 提交没进主干：删掉目录后这些提交只剩分支（游离 HEAD 上甚至没有任何引用），不能当作做完的任务清掉
                    let target = job.bases.first?.name ?? "主干"
                    let unmerged = wt.branch.map { "分支 \($0) 有还没合入 \(target) 的提交（可能尚未推送）" }
                        ?? "detached HEAD \(head.prefix(12)) 的提交没有被 \(target) 包含，删除后可能找不回"
                    base0[i] = locked(clean ? unmerged : dirtyNote + "；" + unmerged,
                                      evidence: unmerged + " · \(idle) · " + (clean ? "工作区干净" : dirtyNote))
                    continue
                }
                // 分支从没动过（reflog 只有创建那一条）："已合入"是平凡成立的，可能是刚开、还在用的 worktree
                let ownWork = wt.branch.map { hasOwnCommits(repo: repo, branch: $0, git: git, runner: runner) } ?? false
                let merged: String
                if !match.ancestor { merged = "完整文件树已出现在 \(match.base) 历史中（兼容 squash/rebase），提交 \(head.prefix(12))" }
                else if let branch = wt.branch {
                    merged = ownWork ? "分支 \(branch) 已合入 \(match.base)" : "分支 \(branch) 没有自己的提交，HEAD 已包含在 \(match.base)"
                } else { merged = "detached HEAD \(head.prefix(12)) 已合入 \(match.base)" }
                let ignoredReason = ignoredBlocker(wt.path, git: git, runner: runner)
                let scanRoot = realRoots.contains(wt.path)
                let evidence = "\(merged) · \(idle) · " + (clean ? "工作区干净" : dirtyNote) + " · " + (ignoredReason ?? "未发现被忽略的文件") + (scanRoot ? " · 扫描根目录本身保留，仅检查内部产物" : "")
                guard GitWorktreeMerge.resolve("HEAD", repo: wt.path, git: git, runner: runner) == head,
                      checkoutMatches(path: wt.path, branch: wt.branch, git: git, runner: runner) else { continue }
                if !clean { base0[i] = locked(dirtyNote, evidence: evidence); continue }
                let eligible = ignoredReason == nil && !scanRoot
                let risk: Risk = eligible && match.ancestor && ownWork && days >= 7 ? .green : .amber
                var item = ScanItem.trashTarget(path: wt.path, name: title, size: size, rule: "Git worktree",
                    evidence: evidence, risk: risk)
                item.cleanupEvidence = .init(version: 1, fingerprint: head, kind: "gitWorktree")
                // 已合入、干净、没有忽略内容：闲置 7 天以上且分支确有自己的工作 → A；7 天内还有活动 → B；其余 → C
                let tier: CleanupTier = !eligible ? .review
                    : days < 7 ? .rebuildable
                    : (ownWork || wt.branch == nil || !match.ancestor) ? .obsolete : .review
                let tierReason = tier == .obsolete ? "分支已合入、工作区干净且至少 7 天未活动，未发现忽略内容或子模块"
                    : tier == .rebuildable ? "分支已合入、工作区干净，但 7 天内有过活动；确认不再用再清" : evidence
                var candidate = CleanupCandidate(source: "worktree", key: wt.path, title: title, size: size,
                    evidence: evidence, risk: risk,
                    action: .worktreeRemove(item: item, repo: repo, branch: wt.branch, base: match.reference),
                    tier: tier, tierReason: tierReason)
                if !eligible { candidate.entry.selectable = false; candidate.entry.defaultChecked = false }
                base0[i] = candidate
              }
            }
        }
        out = results.compactMap { $0 }
        return out
    }

    static func blocker(path: String, repo: String, branch: String?, base: String,
                        runner: CommandRunning, tools: ToolLocator, expectedHead: String? = nil) -> String? {
        guard let git = tools.path(for: .git) else { return "找不到 git" }
        guard isClean(path, git: git, runner: runner) else { return "这个 worktree 有未提交的改动" }
        // 现在签出的必须还是原来那个分支：切到游离 HEAD 或别的分支后再删，新提交会变成孤儿
        guard checkoutMatches(path: path, branch: branch, git: git, runner: runner) else {
            return "这个 worktree 已经不在 \(branch ?? "detached HEAD") 上了"
        }
        guard let current = GitWorktreeMerge.resolve("HEAD", repo: path, git: git, runner: runner),
              expectedHead.map({ $0 == current }) ?? (branch != nil) else { return "worktree 提交已变化或缺少提交快照，请重新扫描" }
        guard let target = GitWorktreeMerge.base(name: base, repo: repo, git: git, runner: runner),
              let match = GitWorktreeMerge.match(head: current, bases: [target], repo: repo, git: git, runner: runner),
              branch != nil || match.ancestor else { return "分支还没合入 \(base)" }
        let list = runner.run(git, ["-C", repo, "worktree", "list", "--porcelain", "-z"], timeout: 10)
        guard list.ok, list.stderr.isEmpty, parsePorcelain(list.stdout).contains(where: { $0.path == path && $0.branch == branch && $0.head == current }) else {
            return "这个 worktree 已被锁定或不在仓库的 worktree 列表里"
        }
        if let why = ignoredBlocker(path, git: git, runner: runner) { return why }
        guard GitWorktreeMerge.resolve("HEAD", repo: path, git: git, runner: runner) == current,
              checkoutMatches(path: path, branch: branch, git: git, runner: runner),
              isClean(path, git: git, runner: runner) else { return "worktree 在复核期间发生变化，请重新扫描" }
        return nil
    }

    private static func checkoutMatches(path: String, branch: String?, git: String, runner: CommandRunning) -> Bool {
        let r = runner.run(git, ["-C", path, "symbolic-ref", "--quiet", "HEAD"], timeout: 10)
        if let branch { return r.ok && r.stderr.isEmpty && r.stdout.trimmingCharacters(in: .newlines) == "refs/heads/" + branch }
        return r.status == 1 && !r.timedOut && r.stderr.isEmpty && r.stdout.isEmpty
    }

    /// NUL-delimited output keeps whitespace/newlines in filenames as data. Any ignored
    /// payload is review-only until its reconstruction has been independently established.
    private static func ignoredBlocker(_ path: String, git: String, runner: CommandRunning) -> String? {
        let result = runner.run(git, ["-C", path, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"], timeout: 20)
        guard result.ok, result.stderr.isEmpty else { return "未能完整检查被 Git 忽略的文件，请保留并重新扫描" }
        if !result.stdout.isEmpty {
            guard result.stdout.hasSuffix("\0"), result.stdout.utf8.count <= 32 * 1024 * 1024 else {
                return "忽略文件清单不完整或超过检查限额，请保留并重新扫描"
            }
            let paths = result.stdout.split(separator: "\0")
            var groups: [String: Int] = [:]
            for relative in paths {
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                      let first = relative.split(separator: "/").first else { return "忽略文件清单无效，请保留并重新扫描" }
                groups[String(first), default: 0] += 1
            }
            let top = groups.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3)
                .map { "\($0.key)（\($0.value) 个）" }.joined(separator: "、")
            return "已识别 \(paths.count) 个被 Git 忽略的文件，主要位置：\(top)；可能包含独有源码或配置，整棵 worktree 保留，已核实的缓存子项可单独处理"
        }
        let index = runner.run(git, ["-C", path, "ls-files", "--stage", "-z"], timeout: 20)
        guard index.ok, index.stderr.isEmpty else { return "未能完整检查子模块，请保留并重新扫描" }
        if index.stdout.split(separator: "\0").contains(where: { $0.hasPrefix("160000 ") }) {
            return "包含 Git 子模块，其忽略文件尚未独立核实；请保留并检查子模块内容"
        }
        let flags = runner.run(git, ["-C", path, "ls-files", "-v", "-z"], timeout: 20)
        guard flags.ok, flags.stderr.isEmpty else { return "无法完整检查 Git 索引标记，请保留并重新扫描" }
        if flags.stdout.split(separator: "\0").contains(where: { record in
            guard let flag = record.first else { return true }
            return flag == "S" || flag.isLowercase
        }) { return "索引存在 skip-worktree 或 assume-unchanged 标记，Git 状态可能隐藏本地修改；保留此项" }
        return nil
    }

    /// 最近一次活动：最后提交时间，和这个 worktree 自己的 index / HEAD 日志的修改时间，取最晚的
    private static func lastActivity(_ path: String, git: String, runner: CommandRunning) -> TimeInterval? {
        var times: [TimeInterval] = []
        let last = runner.run(git, ["-C", path, "log", "-1", "--format=%ct"], timeout: 10)
        if last.ok, let t = Double(last.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) { times.append(t) }
        let dir = runner.run(git, ["-C", path, "rev-parse", "--absolute-git-dir"], timeout: 10)
        if dir.ok {
            let gitDir = dir.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            for name in ["index", "HEAD", "logs/HEAD"] {
                var st = stat()
                if stat(gitDir + "/" + name, &st) == 0 { times.append(TimeInterval(st.st_mtimespec.tv_sec)) }
            }
        }
        return times.max()
    }

    /// reflog 里除了"创建"之外还有记录，说明分支自己动过（提交、合并、重置）
    private static func hasOwnCommits(repo: String, branch: String, git: String, runner: CommandRunning) -> Bool {
        let r = runner.run(git, ["-C", repo, "reflog", "show", "--format=%H", "refs/heads/\(branch)"], timeout: 10)
        return r.ok && r.stdout.split(separator: "\n").count > 1
    }

    private static func isClean(_ path: String, git: String, runner: CommandRunning) -> Bool {
        // 显式参数：仓库配置的 status.showUntrackedFiles=no 或忽略子模块，不能把改动藏起来；
        // --no-optional-locks 让 status 不顺手改写 index（否则会刷新"最近活动"）
        let r = runner.run(git, ["--no-optional-locks", "-C", path, "status", "--porcelain",
                                 "--untracked-files=all", "--ignore-submodules=none"], timeout: 20)
        return r.ok && r.stderr.isEmpty && r.stdout.isEmpty
    }

}
