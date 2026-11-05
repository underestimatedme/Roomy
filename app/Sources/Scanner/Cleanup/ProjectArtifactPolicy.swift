// SPDX-License-Identifier: MPL-2.0
// 项目里的构建产物 / 依赖目录（node_modules、.venv、target、工作空间构建目录）：
// - 含有被 Git 跟踪的文件（提交过的 dist、被强制加入的文件、vendored 依赖）→ 不能删；
// - 被 .gitignore 忽略、没有被跟踪的文件 → B（可选清），废纸篓动作；项目和产物都 staleDays 天以上没动过 → A（放心清）；
//   Xcode 测试结果报告（.xcresult）是过去测试的记录，删了就看不到 → C；
// - 其余（没被忽略、不在仓库里、查不了跟踪状态）沿用扫描时的内容核验结论：核验通过才是可选的 C 废纸篓，否则只能查看。
// 执行前由 OwnerCachePolicy 的归属复核重查进程、被跟踪的文件，以及"仍被忽略"（B）或"内容核验仍通过"（C）。

import Foundation

enum ProjectArtifactPolicy {
    static let rules: Set<String> = ["node_modules", "Python 虚拟环境", "Rust 构建产物", "工作空间构建目录"]

    private static let gitTimeout: TimeInterval = 10
    static let ignoredRole = "gitignored"
    static let ignoredEvidence = "已被 .gitignore 忽略，且没有被 Git 跟踪的文件，是项目生成的构建产物或依赖"
    static let trackedReason = "包含被 Git 跟踪的文件"
    static let unverifiedTracking = "无法确认其中是否有被 Git 跟踪的文件；仅供查看，请重新扫描"
    private static let lsFilesChunk = 200

    /// 项目这么多天没有提交、产物里的文件也这么多天没动过：当作不再开发的项目，依赖和构建产物进 A
    static let staleDays = 90
    static let testReportReason = "Xcode 测试结果报告，删了就看不到这次测试的截图和日志；请确认不再需要后再清"

    /// 产物目录里有没有被 Git 跟踪的文件：clean = 确认没有（或不在仓库里，无从跟踪）
    enum Tracking { case clean, tracked, unverified }

    // MARK: - 仓库与 gitignore

    /// 路径所在的 Git 仓库根（向上找 .git，目录或 worktree 的 gitdir 文件都算）；不在仓库里返回 nil
    static func repository(of path: String) -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        for _ in 0..<64 {
            guard dir.count > 1 else { return nil }
            if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// 被所在仓库 .gitignore 忽略的路径。每个仓库只跑一次 `git check-ignore --stdin -z`，路径经标准输入、相对仓库根。
    /// 找不到 git、命令失败或不在仓库里的路径一律视为"没被忽略"
    static func ignoredPaths(_ paths: [String], runner: CommandRunning, tools: ToolLocator) -> Set<String> {
        guard let git = tools.path(for: .git) else { return [] }
        var byRepository: [String: [String]] = [:]
        for path in paths {
            guard let repo = repository(of: path), path.hasPrefix(repo + "/") else { continue }
            byRepository[repo, default: []].append(path)
        }
        var ignored = Set<String>()
        for repo in byRepository.keys.sorted() {
            let members = byRepository[repo] ?? []
            let input = members.map { String($0.dropFirst(repo.count + 1)) + "\0" }.joined()
            let result = runner.run(git, ["-C", repo, "check-ignore", "--stdin", "-z"], input: input, timeout: gitTimeout)
            // 退出码 0 = 至少一个被忽略；1 = 都没被忽略；其他 = 出错
            guard result.status == 0, !result.timedOut else { continue }
            for relative in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
                let full = repo + "/" + relative
                if members.contains(full) { ignored.insert(full) }
            }
        }
        return ignored
    }

    /// 含有被 Git 跟踪文件的路径，以及查不了的路径。每个仓库一次（按块）`git ls-files -z --cached -- <相对路径…>`，
    /// 路径按字面量处理（--literal-pathspecs），不会被当成通配或 pathspec 魔法。不在仓库里的路径两边都不算
    static func trackedPaths(_ paths: [String], runner: CommandRunning, tools: ToolLocator)
        -> (tracked: Set<String>, unverified: Set<String>) {
        var byRepository: [String: [String]] = [:]
        for path in paths {
            guard let repo = repository(of: path), path.hasPrefix(repo + "/") else { continue }
            byRepository[repo, default: []].append(path)
        }
        guard let git = tools.path(for: .git) else { return ([], Set(byRepository.values.joined())) }
        var tracked = Set<String>(), unverified = Set<String>()
        for repo in byRepository.keys.sorted() {
            let members = byRepository[repo] ?? []
            for start in stride(from: 0, to: members.count, by: lsFilesChunk) {
                let chunk = Array(members[start..<min(start + lsFilesChunk, members.count)])
                let relative = chunk.map { String($0.dropFirst(repo.count + 1)) }
                let result = runner.run(git, ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-C", repo,
                                              "ls-files", "-z", "--cached", "--"] + relative, timeout: gitTimeout)
                guard result.ok, !result.timedOut else { unverified.formUnion(chunk); continue }
                for file in result.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
                    for (full, rel) in zip(chunk, relative) where file == rel || file.hasPrefix(rel + "/") { tracked.insert(full) }
                }
            }
        }
        return (tracked, unverified)
    }

    /// 仓库最近一次提交距今多久（中文）；没有提交或读不到返回 nil
    static func lastCommit(repository: String, runner: CommandRunning, tools: ToolLocator, now: Date = Date()) -> String? {
        commitAge(repository: repository, runner: runner, tools: tools, now: now).map(ageText)
    }

    static func ageText(_ days: Int) -> String { (Humanize.span(days: days).map { $0 + "前" }) ?? "今天" }

    /// 仓库多少天没动过：最近一次提交，和 .git/index 的修改时间（git status、add 都会碰它，开着的编辑器也会）取较近的
    static func commitAge(repository: String, runner: CommandRunning, tools: ToolLocator, now: Date = Date()) -> Int? {
        guard let git = tools.path(for: .git) else { return nil }
        let result = runner.run(git, ["-C", repository, "log", "-1", "--format=%ct"], timeout: gitTimeout)
        guard result.ok, var seconds = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var st = stat()
        if lstat(repository + "/.git/index", &st) == 0 { seconds = max(seconds, Double(st.st_mtimespec.tv_sec)) }
        return max(0, Int((now.timeIntervalSince1970 - seconds) / 86_400))
    }

    // MARK: - 定档

    /// idleDays：项目多少天没动过（commitAge）；和产物自己多久没动（扫描时的 usedDays / mtimeDays）一起决定是不是"不再开发"
    static func candidate(for item: ScanItem, ignored: Bool, lastCommit: String?, tracking: Tracking = .clean,
                          idleDays: Int? = nil) -> CleanupCandidate {
        if tracking == .tracked {
            return OwnerCachePolicy.trash(item, evidence: "目录里有被 Git 跟踪的文件，可能是提交过的发布包、vendored 依赖或本地修改")
                .locked(trackedReason)
        }
        if ignored, tracking == .clean {
            let base = OwnerCachePolicy.trash(item, role: ignoredRole, evidence: ignoredEvidence)
            if isTestReport(item.path) { return base.retiered(.review, reason: testReportReason) }
            if let idleDays, idleDays >= staleDays, let quiet = item.usedDays ?? item.mtimeDays, quiet >= staleDays {
                return base.retiered(.obsolete, reason: "已被 .gitignore 忽略；项目 \(Humanize.span(days: idleDays) ?? "")没动过，里面的文件 \(Humanize.span(days: quiet) ?? "")没变，"
                    + "看起来已不再开发；删了不影响源码，以后要用时重新安装或构建")
            }
            let recent = lastCommit.map { "项目最近提交 \($0)，" } ?? ""
            return base.retiered(.rebuildable, reason: "已被 .gitignore 忽略；\(recent)删除后需重新安装或构建")
        }
        // 没被忽略、不在仓库里或查不了跟踪状态：沿用扫描时的内容核验结论（手工构造、还没核验过的条目这里补一次）
        let checked = item.undo && item.cleanupEvidence == nil ? CleanupEvidence.applying(to: item) : item
        if tracking == .clean, checked.undo, checked.cleanupEvidence != nil {
            return OwnerCachePolicy.trash(checked, role: "plain", evidence: "没有被 .gitignore 忽略，也没有被 Git 跟踪的文件；" + checked.evidence)
                .retiered(.review, reason: "没有被 .gitignore 忽略，或不在 Git 仓库里，可能含本地文件；请核实后再清")
        }
        let reason = tracking == .unverified ? unverifiedTracking : checked.evidence
        let viewOnly = CleanupEvidence.applying(to: checked, decision: .init(reason: reason, snapshot: nil))
        return CleanupListBuilder.fromRule(viewOnly).retiered(.review, reason: reason)
    }

    /// 一批规则条目 → 候选：check-ignore 每仓库一次，git log 每个有被忽略条目的仓库一次
    /// running：已经为这次构建取好的进程列表（不再单独跑 ps）；用到这个产物的进程存在 => 不能删。nil = 没检查（由调用方降级）
    /// Rust 的 target 只被其中一个 profile 的程序用着（服务跑的是 target/release/app）：拆开，只锁那个 profile
    static func candidates(for items: [ScanItem], runner: CommandRunning, tools: ToolLocator,
                           running: RunningOwners? = nil) -> [CleanupCandidate] {
        guard !items.isEmpty else { return [] }
        let ignored = ignoredPaths(items.map(\.path), runner: runner, tools: tools)
        let tracking = trackedPaths(items.map(\.path), runner: runner, tools: tools)
        var ages: [String: Int] = [:], asked = Set<String>()
        return items.flatMap { item -> [CleanupCandidate] in
            let state: Tracking = tracking.tracked.contains(item.path) ? .tracked : tracking.unverified.contains(item.path) ? .unverified : .clean
            let clean = ignored.contains(item.path) && state == .clean
            var age: Int? = nil
            if clean, let repo = repository(of: item.path) {
                if asked.insert(repo).inserted, let days = commitAge(repository: repo, runner: runner, tools: tools) { ages[repo] = days }
                age = ages[repo]
            }
            if let running, inUse(item.path, running) {
                if clean, let parts = profileSplit(item, running) {
                    return parts.used.map { candidate(for: $0, ignored: true, lastCommit: nil).locked(RunningOwners.projectInUse) }
                        + parts.free.map { candidate(for: $0, ignored: true, lastCommit: age.map(ageText)) }
                }
                return [candidate(for: item, ignored: false, lastCommit: nil).locked(RunningOwners.projectInUse)]
            }
            guard clean else { return [candidate(for: item, ignored: ignored.contains(item.path), lastCommit: nil, tracking: state)] }
            return [candidate(for: item, ignored: true, lastCommit: age.map(ageText), idleDays: age)]
        }
    }

    static func isTestReport(_ path: String) -> Bool { path.hasSuffix(".xcresult") }

    /// Rust target 拆成各个 profile 目录（debug、release、aarch64-apple-darwin…）：命令行里落在项目目录下的路径全都在 target 的
    /// 某几个子目录里时，那几个锁住，其余照常可清。项目里还有别的路径在用、或读不了 target，返回 nil（整体锁住）
    static func profileSplit(_ item: ScanItem, _ running: RunningOwners) -> (used: [ScanItem], free: [ScanItem])? {
        guard item.rule == "Rust 构建产物", let users = rustUsers(of: item.path, running), !users.isEmpty,
              let entries = try? readDir(item.path) else { return nil }
        let dirs = entries.filter { $0.isDir && !$0.isLink }.map { item.path + "/" + $0.name }
        let used = dirs.filter { d in users.contains { $0 == d || $0.hasPrefix(d + "/") } }
        let free = dirs.filter { !used.contains($0) }
        guard !free.isEmpty, used.count + free.count == dirs.count else { return nil }
        let sizes = BulkWalker().measureTargets(dirs)
        let project = ((item.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        func child(_ path: String) -> ScanItem {
            let leaf = (path as NSString).lastPathComponent
            return ScanItem(name: "\(project)/target/\(leaf)", path: path, size: sizes[path] ?? 0, atimeDays: nil, mtimeDays: item.mtimeDays,
                usedDays: item.usedDays, rule: item.rule, evidence: item.evidence, risk: item.risk, gentle: item.gentle, hard: item.hard,
                undo: item.undo, note: item.note, rebuild: item.rebuild, identity: CleanupIdentity.capture(path: path))
        }
        return (used.map(child), free.map(child))
    }

    /// 项目目录下被命令行用到的路径；它们全都在 target 的某个子目录里时才返回（否则 nil：项目本身在用）
    private static func rustUsers(of target: String, _ running: RunningOwners) -> [String]? {
        guard let users = running.pathsUsed(under: (target as NSString).deletingLastPathComponent),
              users.allSatisfy({ $0.hasPrefix(target + "/") }) else { return nil }
        return users
    }

    /// 有进程用着这个产物：命令行里带着它所在的目录（产物自己的父目录，不是整个仓库：一个服务跑着不该锁住同仓库别的子项目）。
    /// Rust target 的某个 profile 目录：只有命令行用的是同一个 target 里别的 profile 时不算在用
    static func inUse(_ path: String, _ running: RunningOwners) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        guard running.usesDirectory(parent) else { return false }
        if (parent as NSString).lastPathComponent == "target",
           FileManager.default.fileExists(atPath: (parent as NSString).deletingLastPathComponent + "/Cargo.toml"),
           let users = rustUsers(of: parent, running), !users.isEmpty,
           !users.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { return false }
        return true
    }

    /// 项目目录：所在仓库根，不在仓库里就用产物的父目录。家目录本身（或它的上级）是仓库时不用它：几乎每个进程的命令行都带家目录
    static func projectDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        guard let repo = repository(of: path), repo != HOME, !HOME.hasPrefix(repo + "/") else { return parent }
        return repo
    }


    /// 执行前复核（OwnerCachePolicy.executionBlocker 调用）。nil = 可以执行
    static func executionBlocker(_ item: ScanItem, runner: CommandRunning, tools: ToolLocator) -> String? {
        // 先查有没有进程在用（读不到进程列表就拒绝，不能当成没人用）
        guard let running = RunningOwners.capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
        if inUse(item.path, running) { return RunningOwners.projectInUse }
        // 再查有没有被 Git 跟踪的文件（扫描后才加入的也算）；查不了就拒绝
        if repository(of: item.path) != nil {
            guard tools.path(for: .git) != nil else { return "找不到 git，无法确认其中没有被 Git 跟踪的文件，请重新扫描" }
            let tracking = trackedPaths([item.path], runner: runner, tools: tools)
            if tracking.tracked.contains(item.path) { return trackedReason + "，请重新扫描" }
            if tracking.unverified.contains(item.path) { return "无法确认其中是否有被 Git 跟踪的文件，请重新扫描" }
        }
        if item.cleanupEvidence?.fingerprint.hasPrefix(ignoredRole + ":") == true {
            guard ignoredPaths([item.path], runner: runner, tools: tools).contains(item.path) else {
                return "该目录已不再被 .gitignore 忽略，请重新扫描"
            }
            return nil
        }
        // 没被忽略的（plain）：扫描时靠内容核验才可选，执行前内容核验必须仍然通过
        guard CleanupEvidence.requiresInspection(item) else { return nil }
        let live = CleanupEvidence.inspect(item, runner: runner)
        return live.allowed ? nil : live.reason
    }
}
