// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 记录每次调用的参数和标准输入；check-ignore 的应答按仓库给。
/// 以 " *" 结尾的键按前缀匹配（ls-files 的参数里带着各个路径）
private final class FakeRunner: CommandRunning, @unchecked Sendable {
    var responses: [String: CommandResult] = [:]
    private(set) var calls: [String] = []
    private(set) var inputs: [String: String] = [:]
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        calls.append(key)
        if let exact = responses[key] { return exact }
        let prefixed = responses.keys.filter { $0.hasSuffix(" *") && key.hasPrefix(String($0.dropLast(1))) }.max { $0.count < $1.count }
        return prefixed.flatMap { responses[$0] } ?? CommandResult(status: 1, stdout: "", stderr: "unexpected \(key)", timedOut: false)
    }
    func run(_ executable: String, _ arguments: [String], input: String, timeout: TimeInterval) -> CommandResult {
        inputs[([executable] + arguments).joined(separator: " ")] = input
        return run(executable, arguments, timeout: timeout)
    }
}

private func ok(_ text: String = "") -> CommandResult { CommandResult(status: 0, stdout: text, stderr: "", timedOut: false) }

@main
struct ProjectArtifactPolicyTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        let root = (temporary.hasPrefix("/var/") ? "/private" + temporary : temporary) + "/roomy-artifact-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        func dir(_ path: String) throws { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        func file(_ path: String, _ text: String = "fixture", age days: Double? = nil) throws {
            try dir((path as NSString).deletingLastPathComponent)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            if let days { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: path) }
        }
        func artifact(_ rule: String, _ path: String, size: UInt64 = 5_000_000) -> ScanItem {
            ScanItem(name: (path as NSString).lastPathComponent, path: path, size: size, atimeDays: nil, mtimeDays: 30,
                rule: rule, evidence: "所在项目最后提交/修改时间", risk: .green, gentle: nil, hard: "移到废纸篓",
                undo: true, note: "", rebuild: .cheap, identity: CleanupIdentity.capture(path: path))
        }
        let tools = ToolLocator(searchDirectories: [], isExecutable: { _ in true })
        let git = "/usr/bin/git"
        /// 每仓库一次的"有没有被 Git 跟踪的文件"查询（路径作为字面量 pathspec）
        func lsFiles(_ repo: String) -> String { "\(git) --no-optional-locks --literal-pathspecs -c core.fsmonitor=false -C \(repo) ls-files -z --cached -- *" }

        precondition(ProjectArtifactPolicy.rules == ["node_modules", "Python 虚拟环境", "Rust 构建产物", "工作空间构建目录"])

        // ── ignoredBecomesRebuildable / notIgnoredBecomesReview
        let repoA = root + "/code/a", repoB = root + "/code/b"
        for repo in [repoA, repoB] { try dir(repo + "/.git") }
        try dir(repoA + "/node_modules"); try dir(repoA + "/web/node_modules"); try dir(repoB + "/.venv"); try dir(repoB + "/target")
        try dir(root + "/loose/node_modules")   // 不在任何仓库里
        let runner = FakeRunner()
        runner.responses["\(git) -C \(repoA) check-ignore --stdin -z"] = ok("node_modules\0web/node_modules\0")
        runner.responses["\(git) -C \(repoB) check-ignore --stdin -z"] = ok(".venv\0")   // exit 0, only .venv ignored
        runner.responses[lsFiles(repoA)] = ok(""); runner.responses[lsFiles(repoB)] = ok("")   // nothing tracked
        let paths = [repoA + "/node_modules", repoA + "/web/node_modules", repoB + "/.venv", repoB + "/target", root + "/loose/node_modules"]
        let ignored = ProjectArtifactPolicy.ignoredPaths(paths, runner: runner, tools: tools)
        precondition(ignored == [repoA + "/node_modules", repoA + "/web/node_modules", repoB + "/.venv"], "\(ignored)")
        // ── batchesPerRepository：两个仓库四个路径 → 恰好两次 check-ignore，路径经 stdin、NUL 分隔、相对仓库根
        let batches = FakeRunner()
        batches.responses = runner.responses
        _ = ProjectArtifactPolicy.ignoredPaths(Array(paths.prefix(4)), runner: batches, tools: tools)
        precondition(batches.calls.filter { $0.contains("check-ignore") }.count == 2, "\(batches.calls)")
        precondition(batches.calls.count == 2, "no per-path git calls: \(batches.calls)")
        precondition(batches.inputs["\(git) -C \(repoA) check-ignore --stdin -z"] == "node_modules\0web/node_modules\0",
            "\(batches.inputs)")
        // 没有 git 或命令失败 → 当作没有被忽略（落到 C），不是 B
        precondition(ProjectArtifactPolicy.ignoredPaths(paths, runner: FakeRunner(), tools: tools).isEmpty)
        precondition(ProjectArtifactPolicy.ignoredPaths(paths, runner: runner, tools: ToolLocator(searchDirectories: [], isExecutable: { _ in false })).isEmpty)

        let nm = artifact("node_modules", repoA + "/node_modules")
        let b = ProjectArtifactPolicy.candidate(for: nm, ignored: true, lastCommit: "3 个月前")
        precondition(b.entry.tier == .rebuildable && !b.entry.defaultChecked && b.entry.selectable && b.entry.reversible, "\(b.entry)")
        precondition(b.entry.tierReason == "已被 .gitignore 忽略；项目最近提交 3 个月前，删除后需重新安装或构建", b.entry.tierReason ?? "nil")
        guard case .trash(let item)? = b.action else { preconditionFailure("project artifacts are trash actions") }
        precondition(item.path == nm.path && item.undo && item.cleanupEvidence?.kind == OwnerCachePolicy.evidenceKind)
        precondition(b.entry.group == "node_modules" && b.entry.category == "deps", "\(b.entry.group) \(b.entry.category)")
        // B 行的依据是策略自己的说法，不是规则里"需单独核实内容"那句
        precondition(b.entry.evidence.hasPrefix(ProjectArtifactPolicy.ignoredEvidence), b.entry.evidence)
        let wsB = ProjectArtifactPolicy.candidate(for: artifact("工作空间构建目录", repoB + "/build"), ignored: true, lastCommit: nil)
        precondition(wsB.entry.tier == .rebuildable && wsB.entry.evidence.hasPrefix(ProjectArtifactPolicy.ignoredEvidence)
            && !wsB.entry.evidence.contains("需单独核实") && !wsB.entry.evidence.contains("不能整体"), wsB.entry.evidence)
        // 没被忽略：保留内容核验的结论。没通过（node_modules 永远不按内容放行）→ 只能查看的 C，没有动作
        let c = ProjectArtifactPolicy.candidate(for: nm, ignored: false, lastCommit: nil)
        precondition(c.entry.tier == .review && !c.entry.selectable && c.action == nil && !c.entry.defaultChecked
            && c.entry.evidence.contains("待核实依赖重建"), "\(c.entry)")
        precondition(c.entry.id == b.entry.id, "same path, same id whichever tier")
        let noCommit = ProjectArtifactPolicy.candidate(for: nm, ignored: true, lastCommit: nil)
        precondition(noCommit.entry.tier == .rebuildable && !(noCommit.entry.tierReason ?? "").contains("nil"))
        // 有被 Git 跟踪的文件：不能删（被忽略的目录里强制加入的文件也算）
        let trackedRow = ProjectArtifactPolicy.candidate(for: nm, ignored: false, lastCommit: nil, tracking: .tracked)
        precondition(trackedRow.entry.tier == .locked && trackedRow.entry.lockReason == "包含被 Git 跟踪的文件" && trackedRow.action == nil,
            "\(trackedRow.entry)")
        let forced = ProjectArtifactPolicy.candidate(for: nm, ignored: true, lastCommit: "今天", tracking: .tracked)
        precondition(forced.entry.tier == .locked && forced.entry.lockReason == "包含被 Git 跟踪的文件" && forced.action == nil)
        // 查不了有没有被跟踪：被忽略也不进 B，只能查看
        let unsure = ProjectArtifactPolicy.candidate(for: nm, ignored: true, lastCommit: nil, tracking: .unverified)
        precondition(unsure.entry.tier == .review && unsure.action == nil && !unsure.entry.selectable
            && unsure.entry.evidence.contains("无法确认"), "\(unsure.entry)")
        // 内容核验通过的（带证据快照）、没被跟踪：可选的 C 档废纸篓，执行前按 plain 角色复核
        let verifiedNm = CleanupEvidence.applying(to: nm, decision: .init(reason: "夹具已核验",
            snapshot: .init(version: 1, fingerprint: "fixture", kind: "fixture")))
        let allowedC = ProjectArtifactPolicy.candidate(for: verifiedNm, ignored: false, lastCommit: nil)
        precondition(allowedC.entry.tier == .review && allowedC.entry.selectable && !allowedC.entry.defaultChecked
            && allowedC.entry.evidence.contains("夹具已核验"), "\(allowedC.entry)")
        guard case .trash(let plainItem)? = allowedC.action, plainItem.cleanupEvidence?.fingerprint.hasPrefix("plain:") == true else {
            preconditionFailure("evidence-allowed rows are plain-role trash actions")
        }
        // trackedPaths：每仓库一次 ls-files，路径作字面量；输出映射回包含它的产物；失败的仓库 = 无法确认；不在仓库里 = 没有跟踪可言
        let lsRunner = FakeRunner()
        lsRunner.responses[lsFiles(repoA)] = ok("web/node_modules/x/index.js\0")
        let tracking = ProjectArtifactPolicy.trackedPaths(paths, runner: lsRunner, tools: tools)
        precondition(tracking.tracked == [repoA + "/web/node_modules"], "\(tracking.tracked)")
        precondition(tracking.unverified == [repoB + "/.venv", repoB + "/target"], "\(tracking.unverified)")
        precondition(lsRunner.calls.count == 2 && lsRunner.calls.allSatisfy { $0.contains(" ls-files -z --cached -- ") }, "\(lsRunner.calls)")
        precondition(lsRunner.calls.contains { $0.hasSuffix("-- node_modules web/node_modules") }, "\(lsRunner.calls)")
        precondition(ProjectArtifactPolicy.trackedPaths(paths, runner: lsRunner, tools: ToolLocator(searchDirectories: [], isExecutable: { _ in false }))
            .unverified.count == 4, "no git: every in-repo path is unverified")

        // ── lastCommit：每仓库一次 git log -1
        let logs = FakeRunner()
        logs.responses["\(git) -C \(repoA) log -1 --format=%ct"] = ok("\(Int(Date().timeIntervalSince1970) - 100 * 86_400)\n")
        let commit = ProjectArtifactPolicy.lastCommit(repository: repoA, runner: logs, tools: tools)
        precondition(commit == "3 个月前", commit ?? "nil")
        precondition(ProjectArtifactPolicy.lastCommit(repository: repoB, runner: logs, tools: tools) == nil, "no commits yet")
        precondition(ProjectArtifactPolicy.repository(of: repoA + "/web/node_modules") == repoA)
        precondition(ProjectArtifactPolicy.repository(of: root + "/loose/node_modules") == nil)

        // ── 构建清单：被忽略、没被跟踪的进 B（可选）；没被忽略的保留内容核验结论（这里都没通过 → 只能查看）
        let listRunner = FakeRunner()
        listRunner.responses = runner.responses
        listRunner.responses["\(git) -C \(repoA) log -1 --format=%ct"] = ok("\(Int(Date().timeIntervalSince1970) - 40 * 86_400)\n")
        let built = CleanupListBuilder.build(items: [
            artifact("node_modules", repoA + "/node_modules"), artifact("Python 虚拟环境", repoB + "/.venv"),
            artifact("Rust 构建产物", repoB + "/target"), artifact("node_modules", root + "/loose/node_modules"),
        ], probes: [], runner: listRunner, tools: tools)
        func entry(_ suffix: String) -> CleanupEntry { built.entries.first { $0.path?.hasSuffix(suffix) == true }! }
        precondition(entry("a/node_modules").tier == .rebuildable && entry("a/node_modules").tierReason?.contains("1 个月前") == true,
            entry("a/node_modules").tierReason ?? "nil")
        precondition(entry(".venv").tier == .rebuildable && entry("target").tier == .review && entry("loose/node_modules").tier == .review)
        precondition(entry("a/node_modules").selectable && entry(".venv").selectable && !entry("target").selectable && !entry("loose/node_modules").selectable,
            "\(built.entries.map { ($0.title, $0.selectable) })")
        precondition(built.entries.allSatisfy { !$0.defaultChecked })
        precondition(listRunner.calls.filter { $0.contains("check-ignore") }.count == 2, "\(listRunner.calls)")
        precondition(listRunner.calls.filter { $0.contains(" ls-files ") }.count == 2, "one ls-files per repository: \(listRunner.calls)")
        precondition(listRunner.calls.filter { $0.contains(" log ") }.count == 2, "one git log per repository with ignored items: \(listRunner.calls)")

        // ── 真实扫描路径：条目由 buildRuleItems（扫描用的同一个函数）生成。扫描时的内容核验会把这些规则的 undo 降成 false，
        //    被忽略且没被跟踪的仍由 ProjectArtifactPolicy 放进 B；没被忽略的保留核验结论（只能查看）；含被跟踪文件的不能删
        func scanned(_ rule: String, _ path: String) -> ScanItem {
            guard let index = RULES.firstIndex(where: { $0.name == rule }) else { preconditionFailure("rule \(rule)") }
            let built = buildRuleItems([RuleTarget(ruleIndex: index, path: path)]) { _ in 5_000_000 }
            precondition(built.count == 1, "\(rule) \(path)")
            return built[0]
        }
        try dir(repoB + "/build/app/outputs")
        let scannedItems = [scanned("node_modules", repoA + "/node_modules"), scanned("node_modules", repoA + "/web/node_modules"),
                            scanned("Python 虚拟环境", repoB + "/.venv"),
                            scanned("Rust 构建产物", repoB + "/target"), scanned("工作空间构建目录", repoB + "/build"),
                            scanned("node_modules", root + "/loose/node_modules")]
        precondition(scannedItems.allSatisfy { !$0.undo }, "the scan-time content check downgrades these rows: \(scannedItems.map(\.undo))")
        let scanRunner = FakeRunner()
        scanRunner.responses = listRunner.responses
        // web/node_modules 被忽略但里面有强制加入的文件；b/build 没被忽略且有被跟踪的文件
        scanRunner.responses[lsFiles(repoA)] = ok("web/node_modules/patched/index.js\0")
        scanRunner.responses[lsFiles(repoB)] = ok("build/app/outputs/release.apk\0")
        let scanList = CleanupListBuilder.build(items: scannedItems, probes: [], running: RunningOwners(commands: []),
            owners: OwnerContext(scopes: [:], running: nil, now: Date()), runner: scanRunner, tools: tools)
        func scanEntry(_ suffix: String) -> CleanupEntry {
            guard let e = scanList.entries.first(where: { $0.path?.hasSuffix(suffix) == true }) else { preconditionFailure("missing \(suffix): \(scanList.entries.map(\.title))") }
            return e
        }
        precondition(scanList.entries.count == 6, "one row per artifact, no evidence children: \(scanList.entries.map(\.title))")
        precondition(scanEntry("a/node_modules").tier == .rebuildable && scanEntry("b/.venv").tier == .rebuildable,
            "gitignored scan rows reach B: \(scanEntry("a/node_modules").tier) \(scanEntry("b/.venv").tier) \(scanEntry("a/node_modules").evidence)")
        for suffix in ["a/node_modules", "b/.venv"] {
            let e = scanEntry(suffix)
            precondition(e.selectable && !e.defaultChecked && e.reversible && e.evidence.hasPrefix(ProjectArtifactPolicy.ignoredEvidence)
                && !e.evidence.contains("待核实依赖重建") && !e.evidence.contains("需单独核实"), "B row shows the policy's own evidence: \(e.evidence)")
        }
        for suffix in ["web/node_modules", "b/build"] {
            let e = scanEntry(suffix)
            precondition(e.tier == .locked && e.lockReason == "包含被 Git 跟踪的文件" && !e.selectable, "\(suffix): \(e)")
        }
        precondition(scanEntry("b/target").tier == .review && !scanEntry("b/target").selectable
            && scanEntry("b/target").evidence.contains("可能混有发布包"), scanEntry("b/target").evidence)
        precondition(scanEntry("loose/node_modules").tier == .review && !scanEntry("loose/node_modules").selectable
            && scanEntry("loose/node_modules").evidence.contains("待核实依赖重建"), scanEntry("loose/node_modules").evidence)
        precondition(scanList.candidates.allSatisfy { c in
            guard case .trash(let target)? = c.action else { return !c.entry.selectable }
            return c.entry.tier == .rebuildable && target.undo && target.cleanupEvidence?.kind == OwnerCachePolicy.evidenceKind
        }, "only B rows carry an owner-policy trash action here")
        precondition(scanRunner.calls.filter { $0.contains("check-ignore") }.count == 2, "\(scanRunner.calls)")
        precondition(scanRunner.calls.filter { $0.contains(" ls-files ") }.count == 2, "\(scanRunner.calls)")
        // ls-files 失败（查不了跟踪状态）：被忽略的也只能查看，不进 B
        let blindRunner = FakeRunner()
        blindRunner.responses = listRunner.responses
        blindRunner.responses.removeValue(forKey: lsFiles(repoA))
        let blind = CleanupListBuilder.build(items: [scanned("node_modules", repoA + "/node_modules")], probes: [],
            running: RunningOwners(commands: []), runner: blindRunner, tools: tools)
        precondition(blind.entries[0].tier == .review && !blind.entries[0].selectable && blind.entries[0].evidence.contains("无法确认"),
            "\(blind.entries[0])")

        // ── 执行：真实 git 仓库里被忽略的 node_modules 经 CleanupRunner 进入（私有的）废纸篓闭包
        let live = root + "/live"
        try dir(live + "/livedeps/pkg"); try file(live + "/livedeps/pkg/index.js", String(repeating: "x", count: 4000))
        try file(live + "/.gitignore", "livedeps/\n")
        func sh(_ args: [String]) {
            let r = ProcessRunner().run(git, ["-C", live] + args, timeout: 20)
            precondition(r.ok, "git \(args) failed: \(r.stderr)")
        }
        sh(["init", "-q"])
        sh(["add", ".gitignore"])
        sh(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"])
        var trashed: [String] = []
        var env = CleanupEnvironment()
        env.roots = [root]; env.selectedCodeRoots = []
        env.trash = { trashed.append($0); return "/Trash/" + ($0 as NSString).lastPathComponent }
        env.diskFree = { 1 }
        let liveItem = artifact("node_modules", live + "/livedeps")
        let liveList = CleanupListBuilder.build(items: [liveItem], probes: [])
        let liveEntry = liveList.entries[0]
        precondition(liveEntry.tier == .rebuildable && liveEntry.tierReason?.contains("项目最近提交 今天") == true, "\(liveEntry.tierReason ?? "nil")")
        let ran = CleanupRunner.run(ids: [liveEntry.id], list: liveList, env: env, progress: { _ in })
        precondition(ran.outcomes.count == 1 && ran.outcomes[0].ok && trashed == [live + "/livedeps"],
            "\(ran.outcomes) \(trashed)")
        // 扫描之后 .gitignore 改了 → 执行前复核不再通过
        try file(live + "/.gitignore", "dist/\n")
        let stale = CleanupRunner.run(ids: [liveEntry.id], list: liveList, env: env, progress: { _ in })
        precondition(!stale.outcomes[0].ok && stale.outcomes[0].message.contains(".gitignore") && trashed.count == 1,
            "\(stale.outcomes[0].message)")
        // 没被忽略、内容核验没通过的 C 档只能查看：不可选，CleanupRunner 也不执行
        let looseItem = artifact("node_modules", root + "/loose/node_modules")
        let looseList = CleanupListBuilder.build(items: [looseItem], probes: [])
        precondition(looseList.entries[0].tier == .review && !looseList.entries[0].selectable && looseList.candidates[0].action == nil)
        let trashedBefore = trashed.count
        let looseRan = CleanupRunner.run(ids: [looseList.entries[0].id], list: looseList, env: env, progress: { _ in })
        precondition(!looseRan.outcomes.contains { $0.ok } && trashed.count == trashedBefore, "\(looseRan.outcomes)")
        // 扫描路径生成的条目（undo 已被内容核验降为 false）同样能执行：执行前按归属复核，仍要求还被忽略
        try file(live + "/.gitignore", "livedeps/\n")
        let scanLive = CleanupListBuilder.build(items: [scanned("node_modules", live + "/livedeps")], probes: [])
        precondition(scanLive.entries[0].tier == .rebuildable, "\(scanLive.entries[0])")
        let scanRan = CleanupRunner.run(ids: [scanLive.entries[0].id], list: scanLive, env: env, progress: { _ in })
        precondition(scanRan.outcomes[0].ok && trashed.last == live + "/livedeps", "\(scanRan.outcomes[0].message)")
        try file(live + "/.gitignore", "dist/\n")
        let scanStale = CleanupRunner.run(ids: [scanLive.entries[0].id], list: scanLive, env: env, progress: { _ in })
        precondition(!scanStale.outcomes[0].ok && scanStale.outcomes[0].message.contains(".gitignore"), "\(scanStale.outcomes[0].message)")
        // 被忽略的目录里强制加入了一个文件：扫描后才加入 → 执行被拒；扫描时已加入 → 不能删
        try file(live + "/.gitignore", "livedeps/\n")
        let beforeForce = CleanupListBuilder.build(items: [scanned("node_modules", live + "/livedeps")], probes: [])
        precondition(beforeForce.entries[0].tier == .rebuildable)
        sh(["add", "-f", "livedeps/pkg/index.js"])
        let forcedRun = CleanupRunner.run(ids: [beforeForce.entries[0].id], list: beforeForce, env: env, progress: { _ in })
        precondition(!forcedRun.outcomes[0].ok && forcedRun.outcomes[0].message.contains("Git 跟踪") && trashed.last == live + "/livedeps"
            && trashed.count == trashedBefore + 1, "\(forcedRun.outcomes[0].message) \(trashed)")
        let afterForce = CleanupListBuilder.build(items: [scanned("node_modules", live + "/livedeps")], probes: [])
        precondition(afterForce.entries[0].tier == .locked && afterForce.entries[0].lockReason == "包含被 Git 跟踪的文件", "\(afterForce.entries[0])")
        // 没被忽略、真实仓库里有被跟踪文件的构建目录（提交过的 dist）→ 不能删
        try file(live + "/dist/app.js", "built")
        sh(["add", "dist/app.js"])
        let committedDist = CleanupListBuilder.build(items: [scanned("工作空间构建目录", live + "/dist")], probes: [])
        precondition(committedDist.entries[0].tier == .locked && committedDist.entries[0].lockReason == "包含被 Git 跟踪的文件",
            "\(committedDist.entries[0])")

        // ── Gradle wrapper：被项目引用的保留，其余是 A
        let home = root + "/home", codeRoot = home + "/code"
        let dists = home + "/.gradle/wrapper/dists"
        for name in ["gradle-8.14-all", "gradle-9.4.0-bin", "gradle-7.0-bin"] { try file(dists + "/" + name + "/abc123/gradle/lib.jar", String(repeating: "j", count: 3000)) }
        try file(codeRoot + "/app/gradle/wrapper/gradle-wrapper.properties",
                 "distributionBase=GRADLE_USER_HOME\ndistributionUrl=https\\://services.gradle.org/distributions/gradle-9.4.0-bin.zip\n")
        // node_modules / build / 过深的目录里的引用不算
        try file(codeRoot + "/web/node_modules/x/gradle/wrapper/gradle-wrapper.properties",
                 "distributionUrl=https\\://services.gradle.org/distributions/gradle-7.0-bin.zip\n")
        try file(codeRoot + "/o/build/gradle/wrapper/gradle-wrapper.properties",
                 "distributionUrl=https\\://services.gradle.org/distributions/gradle-7.0-bin.zip\n")
        try file(codeRoot + "/1/2/3/4/5/6/7/gradle/wrapper/gradle-wrapper.properties",
                 "distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14-all.zip\n")
        let wrappers = GradleWrapperProbe.candidates(home: home, codeRoots: [codeRoot])
        precondition(wrappers.map(\.entry.title).sorted() == ["Gradle 旧版本 wrapper · gradle-7.0-bin", "Gradle 旧版本 wrapper · gradle-8.14-all"],
            "\(wrappers.map(\.entry.title))")
        precondition(wrappers.allSatisfy { $0.entry.tier == .obsolete && $0.entry.defaultChecked && $0.entry.reversible && $0.entry.group == "Gradle 旧版本 wrapper" })
        try fm.removeItem(atPath: codeRoot + "/web"); try fm.removeItem(atPath: codeRoot + "/o"); try fm.removeItem(atPath: codeRoot + "/1")
        try fm.removeItem(atPath: dists + "/gradle-7.0-bin")
        let wrapperOnly = GradleWrapperProbe.candidates(home: home, codeRoots: [codeRoot])
        precondition(wrapperOnly.count == 1 && wrapperOnly[0].entry.title.hasSuffix("gradle-8.14-all") && wrapperOnly[0].entry.tier == .obsolete)
        precondition(wrapperOnly[0].entry.size > 0, "default sizing measures the directory")
        precondition(GradleWrapperProbe.candidates(home: root + "/nohome", codeRoots: [codeRoot]).isEmpty)
        // 运行中的 Gradle 守护进程：构建清单时锁定；进程未知时降为 C
        let wrapperList = CleanupListBuilder.build(items: [], probes: wrapperOnly,
            running: RunningOwners(commands: ["/usr/bin/java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8"]))
        precondition(wrapperList.entries[0].tier == .locked, "\(wrapperList.entries[0])")
        precondition(RunningOwners.markUnverified(CleanupListBuilder.build(items: [], probes: wrapperOnly)).entries[0].tier == .review)

        // ── Android SDK 副本：三个子目录齐全才算；标准位置和 ANDROID_HOME 排除
        func sdk(_ path: String, _ parts: [String] = ["platform-tools", "build-tools", "platforms"]) throws {
            for p in parts { try file(path + "/" + p + "/x.bin", String(repeating: "s", count: 3000)) }
        }
        let sdkRoot = root + "/sdk"
        try sdk(sdkRoot + "/qa/android-sdk")
        try sdk(sdkRoot + "/partial", ["platform-tools", "build-tools"])
        try sdk(sdkRoot + "/env/sdk"); try sdk(home + "/Library/Android/sdk")
        let copies = SdkCopyProbe.candidates(searchRoots: [sdkRoot], codeRoots: [], home: home, androidHome: sdkRoot + "/env/sdk", standard: home + "/Library/Android/sdk")
        precondition(copies.count == 1 && copies[0].entry.tier == .obsolete && copies[0].entry.path == sdkRoot + "/qa/android-sdk", "\(copies.map(\.entry.path))")
        precondition(copies[0].entry.group == "Android SDK 副本"
            && copies[0].entry.evidence.contains("标准 SDK 之外的另一份 Android SDK，本次检查范围内没有找到引用"))
        precondition(copies[0].entry.selectable && copies[0].entry.defaultChecked && copies[0].entry.reversible, "unreferenced copies are A")
        precondition(SdkCopyProbe.candidates(searchRoots: [sdkRoot], codeRoots: [], home: home, androidHome: nil, standard: home + "/Library/Android/sdk").count == 2,
            "without ANDROID_HOME the env copy is listed")
        precondition(SdkCopyProbe.candidates(searchRoots: [home], codeRoots: [], home: home, androidHome: nil, standard: home + "/Library/Android/sdk").isEmpty,
            "the standard SDK is never listed, depth is bounded")
        try fm.removeItem(atPath: sdkRoot + "/qa/android-sdk/platforms")
        precondition(SdkCopyProbe.candidates(searchRoots: [sdkRoot], codeRoots: [], home: home, androidHome: sdkRoot + "/env/sdk", standard: home + "/Library/Android/sdk").isEmpty,
            "missing platforms is not an SDK")

        // ── 探测结果走统一的 sizeOf：发现阶段只记路径
        var asked: [String] = []
        let sized = GradleWrapperProbe.candidates(home: home, codeRoots: [codeRoot], sizeOf: { asked.append($0); return ToolProbes.placeholder })
        precondition(asked == [dists + "/gradle-8.14-all"] && sized[0].entry.size == ToolProbes.placeholder, "\(asked)")

        // ── 从 npm 来的 _npx：存在才列，A 档，和 _cacache 的官方命令分开
        let npmHome = root + "/npmhome"
        precondition(OwnerCachePolicy.npxCandidate(home: npmHome) == nil)
        try file(npmHome + "/.npm/_npx/abc/node_modules/pkg/index.js", String(repeating: "n", count: 3000))
        guard let npx = OwnerCachePolicy.npxCandidate(home: npmHome) else { preconditionFailure("npx cache exists") }
        precondition(npx.entry.tier == .obsolete && npx.entry.defaultChecked && npx.entry.reversible, "\(npx.entry)")
        precondition(npx.entry.group == "npm 临时工具缓存" && npx.entry.path == npmHome + "/.npm/_npx", "\(npx.entry.group)")
        precondition(npx.entry.tierReason == "npx 临时下载的工具，需要时会重新下载", npx.entry.tierReason ?? "nil")
        guard case .trash(let npxItem)? = npx.action else { preconditionFailure("npx is a trash action") }
        precondition(npxItem.cleanupEvidence?.kind == OwnerCachePolicy.evidenceKind)
        try file(npmHome + "/.npm/_cacache/README")
        precondition(npx.entry.id != CleanupListBuilder.fromRule(artifact("包管理器缓存", npmHome + "/.npm/_cacache")).entry.id)

        // ── 安装临时目录：只有旁边有正式安装目录才是 A，否则 C
        let now = Date()
        let idle = OwnerContext(scopes: [:], running: RunningOwners(commands: []), now: now)
        let runtimes = root + "/.cache/codex-runtimes"
        let tmpOnly = runtimes + "/codex-runtime-install-aaa"
        try file(tmpOnly + "/a.bin", age: 12)
        func installer(_ path: String) -> ScanItem { artifact("安装临时目录", path, size: 3_000_000_000) }
        let lonely = OwnerCachePolicy.candidates(for: installer(tmpOnly), context: idle)![0]
        precondition(lonely.entry.tier == .review && !lonely.entry.defaultChecked, "\(lonely.entry.tierReason ?? "nil")")
        precondition(lonely.entry.tierReason?.contains("正式安装") == true, lonely.entry.tierReason ?? "nil")
        let otherInstall = runtimes + "/codex-runtime-install-bbb"
        try file(otherInstall + "/a.bin", age: 12)
        precondition(OwnerCachePolicy.candidates(for: installer(tmpOnly), context: idle)![0].entry.tier == .review,
            "another -install- directory is not a finished install")
        try dir(runtimes + "/codex-runtime-1.2.3")
        let withSibling = OwnerCachePolicy.candidates(for: installer(tmpOnly), context: idle)![0]
        precondition(withSibling.entry.tier == .obsolete && withSibling.entry.defaultChecked, "\(withSibling.entry.tierReason ?? "nil")")
        // 执行前也复核：正式目录没了就拦下
        guard case .trash(let tmpItem)? = withSibling.action else { preconditionFailure() }
        let psRunner = FakeRunner()
        psRunner.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        precondition(OwnerCachePolicy.executionBlocker(tmpItem, runner: psRunner, tools: tools) == nil)
        try fm.removeItem(atPath: runtimes + "/codex-runtime-1.2.3")
        precondition(OwnerCachePolicy.executionBlocker(tmpItem, runner: psRunner, tools: tools) != nil)

        // ── 有进程在用：扫描时锁定，进程未知时留在 C，执行前拒绝
        let inUse = "有进程正在使用这个项目，结束后重新扫描"
        precondition(RunningOwners(commands: ["node /a/b/node_modules/.bin/vite"]).usesDirectory("/a/b"))
        precondition(RunningOwners(commands: ["tool --cwd=/a/b --x"]).usesDirectory("/a/b"))
        precondition(RunningOwners(commands: ["tool '/a/b'"]).usesDirectory("/a/b"))
        precondition(RunningOwners(commands: ["tool /a/b"]).usesDirectory("/a/b"))
        precondition(!RunningOwners(commands: ["tool /a/bc/x", "tool /x/a/b/y", "tool /a/b-c"]).usesDirectory("/a/b"),
            "path boundary on both sides")
        let busy = RunningOwners(commands: ["node \(repoA)/node_modules/.bin/vite --port 5173", "/usr/bin/python3 \(repoB)c/serve.py"])
        let busyList = CleanupListBuilder.build(items: [
            artifact("node_modules", repoA + "/node_modules"), artifact("Python 虚拟环境", repoB + "/.venv"),
            artifact("node_modules", root + "/loose/node_modules"),
        ], probes: [], running: busy, runner: listRunner, tools: tools)
        func busyEntry(_ suffix: String) -> CleanupEntry { busyList.entries.first { $0.path?.hasSuffix(suffix) == true }! }
        precondition(busyEntry("a/node_modules").tier == .locked && busyEntry("a/node_modules").lockReason == inUse
            && !busyEntry("a/node_modules").selectable, "\(busyEntry("a/node_modules"))")
        precondition(busyEntry(".venv").tier == .rebuildable, "/code/bc is not /code/b: \(busyEntry(".venv").tier)")
        precondition(busyEntry("loose/node_modules").tier == .review)
        let looseBusy = CleanupListBuilder.build(items: [artifact("node_modules", root + "/loose/node_modules")], probes: [],
            running: RunningOwners(commands: ["npm install --prefix \(root)/loose"]), runner: listRunner, tools: tools)
        precondition(looseBusy.entries[0].tier == .locked, "outside a repository the artifact's parent directory counts")
        // 读不到进程列表：B 降为 C 并写明原因，不是默认勾选
        let unknown = RunningOwners.markUnverified(CleanupListBuilder.build(items: [artifact("node_modules", repoA + "/node_modules")],
            probes: [], runner: listRunner, tools: tools))
        precondition(unknown.entries[0].tier == .review && unknown.entries[0].evidence.contains("无法检查运行状态") && unknown.entries[0].selectable,
            "\(unknown.entries[0])")
        let npxBusy = CleanupListBuilder.build(items: [], probes: [npx],
            running: RunningOwners(commands: ["node \(npmHome)/.npm/_npx/abc/node_modules/.bin/foo"]))
        precondition(npxBusy.entries[0].tier == .locked && npxBusy.entries[0].lockReason == "有进程正在使用 npx 临时工具缓存，结束后重新扫描",
            "\(npxBusy.entries[0])")
        precondition(CleanupListBuilder.build(items: [], probes: [npx], running: RunningOwners(commands: [])).entries[0].tier == .obsolete)
        precondition(RunningOwners.markUnverified(CleanupListBuilder.build(items: [], probes: [npx])).entries[0].tier == .review)
        // 执行前复核：用到该项目的进程出现 → 拒绝；ps 失败 → 拒绝（不能当成没人用）
        func psFake(_ ps: String?) -> FakeRunner {
            let r = FakeRunner(); r.responses = runner.responses
            if let ps { r.responses["/bin/ps -axo command="] = ok(ps) }
            return r
        }
        for target in [item, plainItem] {
            precondition(OwnerCachePolicy.executionBlocker(target, runner: psFake("node \(repoA)/web/server.js\n"), tools: tools) == inUse,
                "\(String(describing: OwnerCachePolicy.executionBlocker(target, runner: psFake("node \(repoA)/web/server.js\n"), tools: tools)))")
            precondition(OwnerCachePolicy.executionBlocker(target, runner: psFake(nil), tools: tools) == "无法检查运行状态，请重新扫描")
        }
        precondition(OwnerCachePolicy.executionBlocker(item, runner: psFake("/sbin/launchd\n/usr/bin/python3 \(repoB)c/x.py\n"), tools: tools) == nil)
        // plain 角色：没被忽略的产物执行前还要求内容核验仍然通过（node_modules 不会通过）
        precondition(OwnerCachePolicy.executionBlocker(plainItem, runner: psFake("/sbin/launchd\n"), tools: tools)?.contains("待核实依赖重建") == true,
            "\(String(describing: OwnerCachePolicy.executionBlocker(plainItem, runner: psFake("/sbin/launchd\n"), tools: tools)))")
        let gone = psFake("/sbin/launchd\n"); gone.responses["\(git) -C \(repoA) check-ignore --stdin -z"] = ok("")
        precondition(OwnerCachePolicy.executionBlocker(item, runner: gone, tools: tools)?.contains(".gitignore") == true, "ignore is still rechecked")
        // 扫描之后出现了被跟踪的文件 → 两种角色都拒绝；查不了 → 拒绝
        for target in [item, plainItem] {
            let nowTracked = psFake("/sbin/launchd\n"); nowTracked.responses[lsFiles(repoA)] = ok("node_modules/vendored.js\0")
            precondition(OwnerCachePolicy.executionBlocker(target, runner: nowTracked, tools: tools) == "包含被 Git 跟踪的文件，请重新扫描",
                "\(String(describing: OwnerCachePolicy.executionBlocker(target, runner: nowTracked, tools: tools)))")
            let blindExec = psFake("/sbin/launchd\n"); blindExec.responses.removeValue(forKey: lsFiles(repoA))
            precondition(OwnerCachePolicy.executionBlocker(target, runner: blindExec, tools: tools)?.contains("无法确认") == true)
        }
        precondition(OwnerCachePolicy.executionBlocker(npxItem, runner: psFake("node \(npmHome)/.npm/_npx/abc/bin.js\n"), tools: tools)
            == "有进程正在使用 npx 临时工具缓存，结束后重新扫描")
        precondition(OwnerCachePolicy.executionBlocker(npxItem, runner: psFake(nil), tools: tools) == "无法检查运行状态，请重新扫描")
        precondition(OwnerCachePolicy.executionBlocker(npxItem, runner: psFake("/sbin/launchd\n"), tools: tools) == nil)

        // ── 有进程在用只锁它用到的那个子项目；Rust target 只锁运行中的 profile
        let repoR = root + "/code/portal"
        try dir(repoR + "/.git")
        try file(repoR + "/server/Cargo.toml"); try file(repoR + "/desktop/Cargo.toml")
        try file(repoR + "/server/target/debug/deps/a.rlib"); try file(repoR + "/server/target/release/portal")
        try file(repoR + "/server/target/aarch64-apple-darwin/release/portal"); try file(repoR + "/server/target/CACHEDIR.TAG")
        try file(repoR + "/desktop/target/debug/app")
        let rustRunner = FakeRunner()
        rustRunner.responses["\(git) -C \(repoR) check-ignore --stdin -z"] = ok("server/target\0desktop/target\0")
        rustRunner.responses[lsFiles(repoR)] = ok("")
        rustRunner.responses["\(git) -C \(repoR) log -1 --format=%ct"] = ok("\(Int(Date().timeIntervalSince1970) - 20 * 86_400)\n")
        let serving = RunningOwners(commands: ["\(repoR)/server/target/release/portal config.toml", "/sbin/launchd"])
        let rustItems = [artifact("Rust 构建产物", repoR + "/server/target"), artifact("Rust 构建产物", repoR + "/desktop/target")]
        let rustList = CleanupListBuilder.build(items: rustItems, probes: [], running: serving, runner: rustRunner, tools: tools)
        func rust(_ suffix: String) -> CleanupEntry? { rustList.entries.first { $0.path == repoR + suffix } }
        precondition(rust("/desktop/target")?.tier == .rebuildable, "another crate in the same repository is not in use: \(String(describing: rust("/desktop/target")))")
        precondition(rust("/server/target") == nil, "the running target is split by profile")
        precondition(rust("/server/target/release")?.tier == .locked && rust("/server/target/release")?.lockReason == inUse)
        for free in ["/server/target/debug", "/server/target/aarch64-apple-darwin"] {
            let e = rust(free)
            precondition(e?.tier == .rebuildable && e?.selectable == true && (e?.size ?? 0) > 0, "\(free): \(String(describing: e))")
            precondition(e?.title == "Rust 构建产物 · server/target/\((free as NSString).lastPathComponent)", "\(String(describing: e?.title))")
        }
        // 执行前同一口径：服务还跑着，debug 可以删，release 不行
        guard case .trash(let debugItem)? = rustList.candidate(id: rust("/server/target/debug")!.id)?.action else { preconditionFailure("debug is a trash row") }
        let execRunner = FakeRunner(); execRunner.responses = rustRunner.responses
        execRunner.responses["/bin/ps -axo command="] = ok("\(repoR)/server/target/release/portal config.toml\n")
        execRunner.responses["\(git) -C \(repoR) check-ignore --stdin -z"] = ok("server/target/debug\0")   // git 按问的路径作答
        precondition(OwnerCachePolicy.executionBlocker(debugItem, runner: execRunner, tools: tools) == nil,
            "\(String(describing: OwnerCachePolicy.executionBlocker(debugItem, runner: execRunner, tools: tools)))")
        let releaseItem = ScanItem(name: "release", path: repoR + "/server/target/release", size: 1, atimeDays: nil, mtimeDays: 1, rule: "Rust 构建产物",
            evidence: "e", risk: .green, gentle: nil, hard: "移到废纸篓", undo: true, note: "", rebuild: .cheap)
        precondition(ProjectArtifactPolicy.inUse(releaseItem.path, serving))
        // 项目目录里还有别的路径在用（不只是 target 里的程序）：整个 target 锁住，不拆
        let building = RunningOwners(commands: ["cargo build --manifest-path \(repoR)/server/Cargo.toml", "\(repoR)/server/target/release/portal"])
        let whole = CleanupListBuilder.build(items: rustItems, probes: [], running: building, runner: rustRunner, tools: tools)
        precondition(whole.entries.first { $0.path == repoR + "/server/target" }?.tier == .locked)
        precondition(!whole.entries.contains { $0.path?.hasPrefix(repoR + "/server/target/") == true })
        precondition(ProjectArtifactPolicy.inUse(repoR + "/server/target/debug", building), "cargo is building: debug is in use too")

        // ── 不再开发的项目：项目和产物都 90 天以上没动 → A；只有项目旧、产物最近动过 → 仍是 B；测试结果报告 → C
        func aged(_ path: String, quiet: Int) -> ScanItem {
            ScanItem(name: (path as NSString).lastPathComponent, path: path, size: 5_000_000, atimeDays: nil, mtimeDays: quiet,
                rule: "node_modules", evidence: "e", risk: .green, gentle: nil, hard: "移到废纸篓", undo: true, note: "", rebuild: .cheap,
                identity: CleanupIdentity.capture(path: path))
        }
        let staleA = ProjectArtifactPolicy.candidate(for: aged(repoA + "/node_modules", quiet: 400), ignored: true, lastCommit: "1 年前", idleDays: 396)
        precondition(staleA.entry.tier == .obsolete && staleA.entry.selectable, "\(staleA.entry)")
        precondition(staleA.entry.tierReason?.contains("项目 1 年没动过，里面的文件 1 年没变") == true, "\(String(describing: staleA.entry.tierReason))")
        precondition(ProjectArtifactPolicy.candidate(for: aged(repoA + "/node_modules", quiet: 20), ignored: true, lastCommit: "1 年前", idleDays: 396).entry.tier == .rebuildable,
            "an old project whose dependencies were installed recently is still in use")
        precondition(ProjectArtifactPolicy.candidate(for: aged(repoA + "/node_modules", quiet: 400), ignored: true, lastCommit: "1 个月前", idleDays: 40).entry.tier == .rebuildable)
        precondition(ProjectArtifactPolicy.candidate(for: aged(repoA + "/node_modules", quiet: 400), ignored: true, lastCommit: nil, idleDays: nil).entry.tier == .rebuildable)
        let report = ProjectArtifactPolicy.candidate(for: artifact("工作空间构建目录", repoA + "/ios/Regression.xcresult"), ignored: true, lastCommit: "今天", idleDays: 400)
        precondition(report.entry.tier == .review && report.entry.tierReason == ProjectArtifactPolicy.testReportReason && report.entry.selectable)
        print("ProjectArtifactPolicyTests passed")
    }
}
