// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

private final class OwnerFakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    var responses: [String: CommandResult] = [:]
    private(set) var calls: [String] = []
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        lock.lock(); calls.append(key); let response = responses[key]; lock.unlock()
        precondition(timeout <= 10, "scope queries must carry a short timeout")
        return response ?? CommandResult(status: 1, stdout: "", stderr: "unexpected \(key)", timedOut: false)
    }
    private(set) var contexts: [String: (env: [String: String], dir: String?)] = [:]
    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             timeout: TimeInterval) -> CommandResult {
        lock.lock(); contexts[([executable] + arguments).joined(separator: " ")] = (environment, directory); lock.unlock()
        return run(executable, arguments, timeout: timeout)
    }
}

private func ok(_ text: String) -> CommandResult { CommandResult(status: 0, stdout: text, stderr: "", timedOut: false) }

@main
struct OwnerCachePolicyTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        let root = (temporary.hasPrefix("/var/") ? "/private" + temporary : temporary) + "/roomy-owner-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: root) }
        func dir(_ path: String) throws { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        func file(_ path: String, _ text: String = "fixture", age days: Double? = nil) throws {
            try dir((path as NSString).deletingLastPathComponent)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            if let days { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: path) }
        }
        func rule(_ name: String, _ path: String, size: UInt64 = 3_000_000_000) -> ScanItem {
            ScanItem(name: (path as NSString).lastPathComponent, path: path, size: size, atimeDays: nil, mtimeDays: 30,
                rule: name, evidence: "纯缓存，缺失时自动重建", risk: .amber, gentle: nil, hard: "移到废纸篓",
                undo: true, note: "", rebuild: .free, identity: CleanupIdentity.capture(path: path))
        }
        let now = Date()
        let goPath = root + "/Library/Caches/go-build", npmPath = root + "/.npm/_cacache"
        for p in [goPath, npmPath] { try file(p + "/README") }

        // ── 命令类：工具报告的范围与路径一致 → A，整体清理
        let ctx = OwnerContext(scopes: [.goBuildCache: goPath, .npmCache: npmPath], running: RunningOwners(commands: []), now: now)
        let go = OwnerCachePolicy.candidates(for: rule("Go 构建缓存", goPath), context: ctx)!
        precondition(go.count == 1 && go[0].entry.tier == .obsolete && go[0].entry.defaultChecked && !go[0].entry.reversible)
        if case .toolClean(.goBuildCache, let s)? = go[0].action { precondition(s == goPath) } else { preconditionFailure() }
        precondition(go[0].entry.evidence.hasPrefix("由 go 管理，扫描时 "), go[0].entry.evidence)
        precondition(go[0].entry.tierReason == "整块由 go clean -cache 清空，工具会按需重新下载", go[0].entry.tierReason ?? "nil")
        precondition(go[0].entry.path == goPath && go[0].targetPath == goPath, "toolClean must expose its scope to path gates")
        precondition(go[0].entry.id == CleanupListBuilder.fromRule(rule("Go 构建缓存", goPath)).entry.id, "id stays stable across policies")
        precondition(!go[0].entry.estimateIsApprox)

        let noTool = OwnerCachePolicy.candidates(for: rule("Go 构建缓存", goPath), context: OwnerContext(scopes: [:], running: nil, now: now))!
        precondition(noTool[0].entry.tier == .review && noTool[0].entry.reversible)
        precondition(noTool[0].entry.tierReason == "找不到 go 或无法确认其缓存位置；可移到废纸篓", noTool[0].entry.tierReason ?? "nil")
        if case .trash(let item)? = noTool[0].action { precondition(item.path == goPath && item.undo) } else { preconditionFailure("C falls back to Trash") }
        let elsewhere = OwnerCachePolicy.candidates(for: rule("Go 构建缓存", goPath),
            context: OwnerContext(scopes: [.goBuildCache: root + "/elsewhere"], running: nil, now: now))!
        precondition(elsewhere[0].entry.tier == .review && elsewhere[0].entry.reversible, "tool reporting another location must not clean it")

        let npm = OwnerCachePolicy.candidates(for: rule("包管理器缓存", npmPath), context: ctx)!
        if case .toolClean(.npmCache, let s)? = npm[0].action { precondition(s == npmPath && npm[0].entry.tier == .obsolete) } else { preconditionFailure() }
        precondition(npm[0].entry.evidence.hasPrefix("由 npm 管理，扫描时 "))

        let pipPath = root + "/Library/Caches/pip", pnpmPath = root + "/Library/pnpm/store",
            brewPath = root + "/Library/Caches/Homebrew", modPath = root + "/go/pkg/mod", uvPath = root + "/.cache/uv"
        for p in [pipPath, pnpmPath + "/v10", brewPath, modPath, uvPath] { try dir(p) }
        let all = OwnerContext(scopes: [.pipCache: pipPath, .pnpmStorePrune: pnpmPath + "/v10", .brewCleanup: brewPath,
                                        .goModCache: modPath, .uvCache: uvPath], running: RunningOwners(commands: []), now: now)
        func command(_ c: CleanupCandidate) -> (ToolCleanCommand, String)? {
            if case .toolClean(let cmd, let scope)? = c.action { return (cmd, scope) }
            return nil
        }
        let pip = OwnerCachePolicy.candidates(for: rule("包管理器缓存", pipPath), context: all)![0]
        precondition(command(pip)?.0 == .pipCache && command(pip)?.1 == pipPath && pip.entry.tier == .obsolete && !pip.entry.estimateIsApprox)
        let pnpm = OwnerCachePolicy.candidates(for: rule("包管理器缓存", pnpmPath), context: all)![0]
        precondition(command(pnpm)?.0 == .pnpmStorePrune && command(pnpm)?.1 == pnpmPath, "pnpm store path may carry a version folder")
        precondition(pnpm.entry.estimateIsApprox && pnpm.entry.tier == .obsolete)
        let brew = OwnerCachePolicy.candidates(for: rule("包管理器缓存", brewPath), context: all)![0]
        precondition(command(brew)?.0 == .brewCleanup && brew.entry.estimateIsApprox && brew.entry.tier == .obsolete)
        precondition(brew.entry.tierReason == "brew cleanup 会删除旧版本软件包和下载缓存，大小以工具实际回收为准", brew.entry.tierReason ?? "nil")
        precondition(brew.entry.evidence.contains("旧版本") && brew.entry.title.contains("旧版本"), brew.entry.evidence + " / " + brew.entry.title)
        let mod = OwnerCachePolicy.candidates(for: rule("Go 模块缓存", modPath), context: all)![0]
        precondition(command(mod)?.0 == .goModCache && mod.entry.tier == .obsolete)
        let uv = OwnerCachePolicy.candidates(for: rule("uv 缓存", uvPath), context: all)![0]
        precondition(command(uv)?.0 == .uvCache && uv.entry.tier == .obsolete)
        let noPip = OwnerCachePolicy.candidates(for: rule("包管理器缓存", pipPath), context: OwnerContext(scopes: [:], running: nil, now: now))![0]
        precondition(noPip.entry.tierReason == "找不到 pip3 或无法确认其缓存位置；可移到废纸篓")
        precondition(OwnerCachePolicy.candidates(for: rule("包管理器缓存", root + "/.cargo/registry/cache"), context: all) == nil,
            "rows outside the table keep the old logic")
        precondition(OwnerCachePolicy.candidates(for: rule("node_modules", root + "/p/node_modules"), context: all) == nil)
        var lockedItem = rule("Go 构建缓存", goPath); lockedItem = ScanItem(name: lockedItem.name, path: goPath, size: 1, atimeDays: nil,
            mtimeDays: nil, rule: "Go 构建缓存", evidence: "x", risk: .lock, gentle: nil, hard: "", undo: true, note: "", rebuild: .free)
        precondition(OwnerCachePolicy.candidates(for: lockedItem, context: ctx) == nil, "lock items stay with the builder")

        // ── Xcode / Gradle：标准路径进 A 废纸篓；运行中 → 不能删；查不到进程 → C
        let dd = root + "/Library/Developer/Xcode/DerivedData/Roomy-abc"
        let mcp = root + "/Library/Developer/XcodeBuildMCP/workspaces/w1", gradle = root + "/.gradle/caches"
        for p in [dd, mcp, gradle] { try file(p + "/x.bin") }
        let xcode = OwnerCachePolicy.candidates(for: rule("Xcode DerivedData", dd), context: OwnerContext(scopes: [:], running: RunningOwners(commands: ["/usr/bin/xcodebuild -scheme X"]), now: now))!
        precondition(xcode[0].entry.tier == .locked)
        precondition(xcode[0].entry.lockReason == RunningOwners.xcodeBlocker && xcode[0].entry.path == dd)
        let idle = OwnerContext(scopes: [:], running: RunningOwners(commands: []), now: now)
        let ddA = OwnerCachePolicy.candidates(for: rule("Xcode DerivedData", dd), context: idle)!
        precondition(ddA.count == 1 && ddA[0].entry.tier == .obsolete && ddA[0].entry.defaultChecked && ddA[0].entry.reversible)
        if case .trash(let item)? = ddA[0].action { precondition(item.path == dd && item.undo) } else { preconditionFailure() }
        let ddUnknown = OwnerCachePolicy.candidates(for: rule("Xcode DerivedData", dd), context: OwnerContext(scopes: [:], running: nil, now: now))!
        precondition(ddUnknown[0].entry.tier == .review && ddUnknown[0].entry.tierReason == RunningOwners.unverifiedReason)
        precondition(RunningOwners.markUnverified(CleanupList(candidates: ddUnknown)).candidates[0].entry.evidence == ddUnknown[0].entry.evidence,
            "already-downgraded entries are not prefixed twice")
        let mcpA = OwnerCachePolicy.candidates(for: rule("XcodeBuildMCP 工作区", mcp), context: idle)!
        precondition(mcpA[0].entry.tier == .obsolete && mcpA[0].entry.defaultChecked)
        let gradleA = OwnerCachePolicy.candidates(for: rule("Gradle 缓存", gradle), context: idle)!
        precondition(gradleA[0].entry.tier == .obsolete && gradleA[0].entry.reversible)
        let daemon = OwnerContext(scopes: [:], running: RunningOwners(commands: ["java org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5"]), now: now)
        let gradleLocked = OwnerCachePolicy.candidates(for: rule("Gradle 缓存", gradle), context: daemon)!
        precondition(gradleLocked[0].entry.tier == .locked && gradleLocked[0].entry.lockReason == RunningOwners.gradleBlocker)

        // ── 其他固定档位
        let maven = OwnerCachePolicy.candidates(for: rule("Maven 仓库", root + "/.m2/repository"), context: idle)![0]
        precondition(maven.entry.tier == .review && maven.entry.reversible && maven.entry.selectable)
        let playwright = OwnerCachePolicy.candidates(for: rule("Playwright 旧版本浏览器", root + "/Library/Caches/ms-playwright/chromium-1000"), context: idle)![0]
        precondition(playwright.entry.tier == .rebuildable && !playwright.entry.defaultChecked && playwright.entry.reversible)

        // ── installerTempAge：最新文件 3 天 → C，10 天 → A；被进程使用 → C；进程未知 → C
        let young = root + "/.cache/codex-runtimes/codex-runtime-install-young", old = root + "/.cache/codex-runtimes/codex-runtime-install-old"
        try file(young + "/a.bin", age: 3); try file(young + "/sub/b.bin", age: 20)
        try file(old + "/a.bin", age: 10); try file(old + "/sub/b.bin", age: 30)
        precondition(OwnerCachePolicy.newestFileAge(in: young) == 3, "\(String(describing: OwnerCachePolicy.newestFileAge(in: young)))")
        precondition(OwnerCachePolicy.newestFileAge(in: old) == 10)
        precondition(OwnerCachePolicy.newestFileAge(in: old, limit: 1) == nil, "a walk beyond the limit is uncertain")
        precondition(OwnerCachePolicy.candidates(for: rule("安装临时目录", young), context: idle)![0].entry.tier == .review)
        // 旁边没有正式安装的目录（只有另一个 -install- 临时目录）→ 仍是 C；有正式目录 → A
        precondition(OwnerCachePolicy.candidates(for: rule("安装临时目录", old), context: idle)![0].entry.tier == .review,
            "no finished install next to it")
        try dir(root + "/.cache/codex-runtimes/codex-runtime-1.0.0")
        let oldA = OwnerCachePolicy.candidates(for: rule("安装临时目录", old), context: idle)![0]
        precondition(oldA.entry.tier == .obsolete && oldA.entry.defaultChecked && oldA.entry.reversible)
        let inUse = OwnerContext(scopes: [:], running: RunningOwners(commands: ["/bin/sh " + old + "/install.sh"]), now: now)
        precondition(OwnerCachePolicy.candidates(for: rule("安装临时目录", old), context: inUse)![0].entry.tier == .review)
        precondition(OwnerCachePolicy.candidates(for: rule("安装临时目录", old), context: OwnerContext(scopes: [:], running: nil, now: now))![0].entry.tier == .review)

        // ── installerTempLimits：条目上限 200,000、时间预算 5 秒；本机实际的安装临时目录有 27,726 个文件，必须能判断
        precondition(OwnerCachePolicy.newestFileAgeLimit == 200_000 && OwnerCachePolicy.newestFileAgeBudget == 5,
            "\(OwnerCachePolicy.newestFileAgeLimit) \(OwnerCachePolicy.newestFileAgeBudget)")
        let manyParent = root + "/many-runtimes", many = manyParent + "/codex-runtime-install-many"
        let twelveDays = now.addingTimeInterval(-12 * 86_400)
        for d in 0..<25 {
            try dir(many + "/d\(d)")
            for f in 0..<1_000 {
                precondition(fm.createFile(atPath: many + "/d\(d)/f\(f)", contents: nil, attributes: [.modificationDate: twelveDays]))
            }
        }
        try dir(manyParent + "/codex-runtime-2.0.0")
        precondition(OwnerCachePolicy.newestFileAge(in: many, now: now) == 12,
            "25,025 entries fit the default limit: \(String(describing: OwnerCachePolicy.newestFileAge(in: many, now: now)))")
        let manyRow = OwnerCachePolicy.candidates(for: rule("安装临时目录", many), context: idle)![0]
        precondition(manyRow.entry.tier == .obsolete, "\(manyRow.entry.tier as Any) \(manyRow.entry.tierReason ?? "nil")")
        // 注入的上限：超出 → 不确定（nil）→ C
        precondition(OwnerCachePolicy.newestFileAge(in: many, limit: 25_024, now: now) == nil)
        precondition(OwnerCachePolicy.newestFileAge(in: many, limit: 25_025, now: now) == 12)
        // 注入的时间预算：每读一次时钟前进 1 秒；预算用完 → 不确定（nil）
        final class Tick: @unchecked Sendable {
            var calls = 0
            func next() -> Date { calls += 1; return Date(timeIntervalSince1970: Double(calls)) }
        }
        let slow = Tick()
        precondition(OwnerCachePolicy.newestFileAge(in: many, budget: 3, now: now, clock: slow.next) == nil, "a walk past its budget is uncertain")
        precondition(slow.calls < 100, "the walk stops soon after the budget runs out: \(slow.calls)")
        precondition(OwnerCachePolicy.newestFileAge(in: many, budget: 1_000_000, now: now, clock: Tick().next) == 12)
        precondition(OwnerCachePolicy.newestFileAge(in: old, budget: 0, now: now) == nil, "zero budget is uncertain")
        // 读不完（子目录不可读）仍是"不确定 → C"
        let unreadable = manyParent + "/codex-runtime-install-locked"
        try file(unreadable + "/a.bin", age: 30); try dir(unreadable + "/sealed")
        precondition(chmod(unreadable + "/sealed", 0) == 0)
        let unknownRow = OwnerCachePolicy.candidates(for: rule("安装临时目录", unreadable), context: idle)![0]
        precondition(chmod(unreadable + "/sealed", 0o755) == 0)
        precondition(unknownRow.entry.tier == .review && unknownRow.entry.tierReason?.contains("目录内容太多或无法完整读取") == true,
            unknownRow.entry.tierReason ?? "nil")

        // ── projectCacheSplits：go-build、go-mod 各一条 A，其余合为一条 C
        let project = root + "/code/Valley", cache = project + "/.cache"
        try file(cache + "/go-build/README", "This directory holds cached build artifacts from the Go build system.\n")
        try file(cache + "/go-build/00/00aa-d", String(repeating: "g", count: 5000))
        try file(cache + "/go-mod/cache/download/example.com/@v/list", String(repeating: "m", count: 5000))
        try file(cache + "/refactor-x/notes.txt", String(repeating: "r", count: 5000))
        let split = OwnerCachePolicy.candidates(for: rule("项目缓存目录", cache), context: idle)!
        let splitA = split.filter { $0.entry.tier == .obsolete }, splitC = split.filter { $0.entry.tier == .review }
        precondition(split.count == 3 && splitA.count == 2 && splitC.count == 1, "\(split.map { ($0.entry.title, $0.entry.tier) })")
        precondition(Set(splitA.compactMap(\.targetPath)) == [cache + "/go-build", cache + "/go-mod"])
        precondition(splitC[0].targetPath == cache + "/refactor-x" && splitC[0].entry.reversible)
        precondition(split.allSatisfy { $0.entry.size > 0 && $0.entry.group == "项目缓存目录" && $0.entry.title.contains("Valley") }, "\(split.map(\.entry.title))")
        precondition(Set(split.map(\.entry.id)).count == 3)
        // 布局不像 Go 缓存的 go-build 不能进 A
        let fake = root + "/code/Other/.cache"
        try file(fake + "/go-build/notes.txt", String(repeating: "n", count: 5000))
        let fakeSplit = OwnerCachePolicy.candidates(for: rule("项目缓存目录", fake), context: idle)!
        precondition(fakeSplit.count == 1 && fakeSplit[0].entry.tier == .review && fakeSplit[0].targetPath == fake,
            "without Go children the whole .cache stays one C entry")

        // ── A 档废纸篓项能真正执行（执行前按归属复核），且不碰真实文件
        let trash = root + "/PrivateTrash"
        try dir(trash)
        var env = CleanupEnvironment()
        env.roots = [root]; env.selectedCodeRoots = []; env.diskFree = { 0 }
        env.trash = { path in let to = trash + "/" + UUID().uuidString; try fm.moveItem(atPath: path, toPath: to); return to }
        let goChild = splitA.first { $0.targetPath == cache + "/go-build" }!
        let oldInstaller = oldA
        let runList = CleanupList(candidates: [goChild, oldInstaller])
        let summary = CleanupRunner.run(ids: [goChild.entry.id, oldInstaller.entry.id], list: runList, env: env, progress: { _ in })
        precondition(summary.outcomes.allSatisfy(\.ok), "\(summary.outcomes.map(\.message))")
        precondition(!fm.fileExists(atPath: cache + "/go-build") && fm.fileExists(atPath: cache + "/refactor-x"))
        // 扫描后被改成不像 Go 缓存：执行前复核拒绝
        try file(cache + "/go-build/README", "This directory holds cached build artifacts from the Go build system.\n")
        let again = OwnerCachePolicy.candidates(for: rule("项目缓存目录", cache), context: idle)!.first { $0.targetPath == cache + "/go-build" }!
        try fm.removeItem(atPath: cache + "/go-build/README")
        let refused = CleanupRunner.run(ids: [again.entry.id], list: CleanupList(candidates: [again]), env: env, progress: { _ in })
        precondition(refused.outcomes.first?.ok == false && fm.fileExists(atPath: cache + "/go-build"), "layout recheck must block execution")

        // ── OwnerContext.capture：每个命令问一次工具，工具缺失静默跳过
        let runner = OwnerFakeRunner()
        runner.responses["/fake/go env GOCACHE"] = ok(goPath + "\n")
        runner.responses["/fake/go env GOMODCACHE"] = ok(modPath + "\n")
        runner.responses["/fake/npm config get cache --no-update-notifier"] = ok(root + "/.npm\n")
        let tools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { $0 == "/fake/go" || $0 == "/fake/npm" })
        let captured = OwnerContext.capture(runner: runner, tools: tools)
        precondition(captured.scopes == [.goBuildCache: goPath, .goModCache: modPath, .npmCache: npmPath], "\(captured.scopes)")
        precondition(captured.running == nil, "callers fill running from their own process capture")
        precondition(!runner.calls.contains { $0.contains("docker") || $0.contains("pip3") }, "\(runner.calls)")
        precondition(runner.contexts.count == 3 && runner.contexts.values.allSatisfy { $0.dir == HOME }, "scope queries run from HOME")
        precondition(runner.contexts["/fake/go env GOCACHE"]?.env["GOTOOLCHAIN"] == "local")
        // 只有系统 /usr/bin/pip3：装了命令行工具才问它的缓存位置；没装就不碰这个占位程序
        func systemPipCapture(_ installed: Bool) -> (OwnerContext, OwnerFakeRunner) {
            let r = OwnerFakeRunner()
            r.responses["/usr/bin/pip3 cache dir"] = ok(pipPath + "\n")
            let t = ToolLocator(searchDirectories: ["/fake"], isExecutable: { $0 == "/usr/bin/pip3" }, dockerHost: nil,
                                developerToolsInstalled: { installed })
            return (OwnerContext.capture(runner: r, tools: t), r)
        }
        let (sysPip, sysPipRunner) = systemPipCapture(true)
        precondition(sysPip.scopes == [.pipCache: pipPath], "\(sysPip.scopes) \(sysPipRunner.calls)")
        var sysPipIdle = sysPip; sysPipIdle.running = RunningOwners(commands: [])
        let sysPipRow = OwnerCachePolicy.candidates(for: rule("包管理器缓存", pipPath), context: sysPipIdle)![0]
        precondition(command(sysPipRow)?.0 == .pipCache && sysPipRow.entry.tier == .obsolete, "\(sysPipRow.entry)")
        let (noCLT, noCLTRunner) = systemPipCapture(false)
        precondition(noCLT.scopes.isEmpty && noCLTRunner.calls.isEmpty, "\(noCLTRunner.calls)")

        // ── builderSkipsEvidenceChildren：命中归属时不再生成 npm 下载缓存 / Go 生成缓存子项
        let blob = Data(String(repeating: "npm", count: 2000).utf8)
        let hex = SHA512.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let bucket = npmPath + "/content-v2/sha512/" + hex.prefix(2)
        try dir(bucket + "/" + hex.dropFirst(2).prefix(2))
        try blob.write(to: URL(fileURLWithPath: bucket + "/" + hex.dropFirst(2).prefix(2) + "/" + hex.dropFirst(4)))
        let npmItem = rule("包管理器缓存", npmPath, size: 9_000)
        let owned = CleanupListBuilder.build(items: [npmItem], probes: [], running: RunningOwners(commands: []), owners: ctx)
        precondition(!owned.entries.contains { $0.group == "npm 下载缓存" }, "\(owned.entries.map(\.group))")
        let legacy = CleanupListBuilder.build(items: [npmItem], probes: [], running: RunningOwners(commands: []))
        precondition(legacy.entries.contains { $0.group == "npm 下载缓存" } || CacheActivitySnapshot.capture(runner: ProcessRunner()) == nil,
            "control: without owners the legacy path still splits evidence children")
        precondition(owned.candidates.count == 1 && command(owned.candidates[0])?.0 == .npmCache)
        // 后台服务用到的整块缓存不默认勾选
        let agent = CleanupListBuilder.build(items: [npmItem], probes: [], agentPaths: [(label: "com.x.agent", path: npmPath + "/index-v5")],
            running: RunningOwners(commands: []), owners: ctx)
        precondition(agent.candidates[0].entry.tier == .review && !agent.candidates[0].entry.defaultChecked, "agent gate must see toolClean scope")
        // 用户保护的范围与整块缓存重叠 → 不能删
        let protection = CleanupProtectionStore(url: URL(fileURLWithPath: root + "/protected.json"))
        try dir(npmPath + "/index-v5")
        let inner = CleanupListBuilder.fromRule(rule("自动更新残留", npmPath + "/index-v5"))
        try protection.set(inner, protected: true)
        let reloaded = try protection.apply(to: owned)
        precondition(reloaded.candidates[0].entry.tier == .locked, "protection must overlap the toolClean scope")
        try protection.remove(id: inner.entry.id)
        try protection.set(owned.candidates[0], protected: true)
        let records = try protection.all()
        precondition(records.first?.path == npmPath, "protecting a toolClean entry records its scope")
        // Xcode 正在运行：owners 和 running 都给时都只锁一次
        let ddLocked = CleanupListBuilder.build(items: [rule("Xcode DerivedData", dd)], probes: [],
            running: RunningOwners(commands: ["/usr/bin/xcodebuild"]), owners: OwnerContext(scopes: [:], running: nil, now: now))
        precondition(ddLocked.candidates.count == 1 && ddLocked.candidates[0].entry.tier == .locked)

        // ── Xcode 的各种安装名（Xcode-beta.app、Xcode-16.2.0.app）都算 Xcode 在运行；Xcodes.app（版本管理器）不算
        func xcodeRuns(_ line: String) -> Bool { RunningOwners(commands: [line]).blocker(forRule: "Xcode DerivedData") == RunningOwners.xcodeBlocker }
        precondition(xcodeRuns("/Applications/Xcode.app/Contents/MacOS/Xcode"))
        precondition(xcodeRuns("/Applications/Xcode-beta.app/Contents/MacOS/Xcode"), "Xcode-beta must count")
        precondition(xcodeRuns("/Applications/Xcode-16.2.0.app/Contents/MacOS/Xcode"), "versioned Xcode must count")
        precondition(xcodeRuns("/usr/bin/xcodebuild -scheme X"))
        precondition(xcodeRuns("/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build"))
        precondition(!xcodeRuns("/Applications/Xcodes.app/Contents/MacOS/Xcodes") && !xcodeRuns("/usr/sbin/cfprefsd agent"))
        // 只认 Xcode 本体和 xcodebuild：装在 Xcode 里的其他程序、名字里带 xcodebuild 的 MCP 服务都不算 Xcode 在运行
        precondition(!xcodeRuns("/Applications/Xcode.app/Contents/Applications/DeviceHub.app/Contents/MacOS/DeviceHub"), "DeviceHub is not Xcode")
        precondition(!xcodeRuns("/Applications/Xcode_15.4.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"))
        precondition(!xcodeRuns("npm exec xcodebuildmcp@latest mcp"), "an MCP server named xcodebuildmcp is not xcodebuild")
        precondition(!xcodeRuns("node /x/node_modules/.bin/xcodebuildmcp mcp"))
        precondition(RunningOwners(commands: ["/Applications/Xcode-beta.app/Contents/MacOS/Xcode"]).blocker(forRule: "XcodeBuildMCP 工作区") == RunningOwners.xcodeBlocker)
        // XcodeBuildMCP 工作区归 xcodebuildmcp 自己：它在运行只锁它的工作区，不连带锁 DerivedData
        for line in ["npm exec xcodebuildmcp@latest mcp", "node /x/node_modules/.bin/xcodebuildmcp mcp"] {
            precondition(RunningOwners(commands: [line]).blocker(forRule: "XcodeBuildMCP 工作区") == RunningOwners.xcodeBuildMCPBlocker, line)
        }
        precondition(RunningOwners(commands: ["npm exec my-xcodebuildmcp-fork"]).blocker(forRule: "XcodeBuildMCP 工作区") == nil)

        // ── 整块清理的所有者在运行：进"不能删"；读不到进程列表：降为 C 并安全锁定（与 Xcode / Gradle 一致）
        func runs(_ c: ToolCleanCommand, _ line: String) -> Bool { RunningOwners(commands: [line]).blocker(forTool: c) != nil }
        precondition(runs(.npmCache, "npm exec @softeria/ms-365-mcp-server --org-mode"))
        precondition(runs(.npmCache, "/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/npm/bin/npm-cli.js install"))
        precondition(runs(.npmCache, "/usr/local/bin/npx -y serve"))
        precondition(!runs(.npmCache, "/opt/homebrew/bin/node /Users/x/app/server.js"), "plain node is not npm")
        precondition(!runs(.npmCache, "/usr/local/bin/npm-check-updates") && !runs(.npmCache, "/x/my-npm/bin/tool"))
        precondition(runs(.goBuildCache, "go run ./cmd/server") && runs(.goModCache, "/usr/local/go/bin/go build ./..."))
        precondition(!runs(.goBuildCache, "/Users/x/go/bin/gopls") && !runs(.goModCache, "/Users/x/go/bin/server"), "go-built binaries are not go")
        precondition(runs(.pipCache, "/usr/bin/pip3 install x") && runs(.pipCache, "pip3.12 download x") && runs(.pipCache, "pip list"))
        precondition(runs(.pipCache, "/opt/homebrew/bin/python3 -m pip install x"))
        precondition(!runs(.pipCache, "/usr/bin/python3 /Users/x/pipeline.py") && !runs(.pipCache, "/usr/bin/pipx run x"))
        precondition(runs(.uvCache, "/Users/x/.local/bin/uv sync") && runs(.uvCache, "uvx ruff check"))
        precondition(!runs(.uvCache, "/usr/local/bin/uvicorn app:main"))
        precondition(runs(.pnpmStorePrune, "pnpm install") && runs(.pnpmStorePrune, "node /x/pnpm/bin/pnpm.cjs install"))
        precondition(runs(.brewCleanup, "/opt/homebrew/bin/brew install x") && runs(.brewCleanup, "/bin/bash /opt/homebrew/Library/Homebrew/brew.sh upgrade"))
        precondition(!runs(.brewCleanup, "/usr/local/bin/brewer"))
        precondition(!runs(.dockerBuilderPrune, "docker build ."), "docker builder prune has its own daemon check")
        precondition(!runs(.npmCache, "go run x") && !runs(.goBuildCache, "npm exec x"), "each tool only blocks its own cache")
        let npmBusy = OwnerContext(scopes: [.npmCache: npmPath], running: RunningOwners(commands: ["npm exec serve site"]), now: now)
        let busy = OwnerCachePolicy.candidates(for: rule("包管理器缓存", npmPath), context: npmBusy)![0]
        precondition(busy.entry.tier == .locked && busy.action == nil && !busy.entry.selectable, "\(busy.entry)")
        precondition(busy.entry.lockReason == RunningOwners.toolBlocker(.npmCache) && busy.entry.lockReason?.contains("npm") == true)
        let goBusy = OwnerCachePolicy.candidates(for: rule("Go 模块缓存", modPath),
            context: OwnerContext(scopes: [.goModCache: modPath], running: RunningOwners(commands: ["go run ./cmd/server"]), now: now))![0]
        precondition(goBusy.entry.tier == .locked, "\(goBusy.entry)")
        let npmUnknown = OwnerCachePolicy.candidates(for: rule("包管理器缓存", npmPath),
            context: OwnerContext(scopes: [.npmCache: npmPath], running: nil, now: now))![0]
        precondition(npmUnknown.entry.tier == .review && npmUnknown.entry.safetyHold == true && !npmUnknown.entry.defaultChecked
            && npmUnknown.entry.tierReason == RunningOwners.unverifiedReason, "\(npmUnknown.entry)")
        // 列表层面：读不到进程列表时，整块清理行也要降级（markUnverified）
        let npmIdleRow = OwnerCachePolicy.candidates(for: rule("包管理器缓存", npmPath), context: ctx)![0]
        let unverifiedList = RunningOwners.markUnverified(CleanupList(candidates: [npmIdleRow]))
        precondition(unverifiedList.candidates[0].entry.tier == .review && unverifiedList.candidates[0].entry.safetyHold == true)
        let builtBusy = CleanupListBuilder.build(items: [rule("包管理器缓存", npmPath, size: 9_000)], probes: [],
            running: RunningOwners(commands: ["/usr/local/bin/npm run dev"]), owners: OwnerContext(scopes: [.npmCache: npmPath], running: nil, now: now))
        precondition(builtBusy.candidates.count == 1 && builtBusy.candidates[0].entry.tier == .locked, "\(builtBusy.entries)")
        // 回退到废纸篓的整块缓存（工具位置对不上）执行前同样复核所有者
        let fallback = OwnerCachePolicy.candidates(for: rule("包管理器缓存", npmPath),
            context: OwnerContext(scopes: [.npmCache: root + "/elsewhere"], running: RunningOwners(commands: []), now: now))![0]
        guard case .trash(let fallbackItem)? = fallback.action else { preconditionFailure("fallback is a Trash row") }
        let psTools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { $0 == "/fake/ps" || $0 == "/bin/ps" })
        let psBusy = OwnerFakeRunner(); psBusy.responses["/bin/ps -axo command="] = ok("npm exec x\n"); psBusy.responses["/fake/ps -axo command="] = ok("npm exec x\n")
        precondition(OwnerCachePolicy.executionBlocker(fallbackItem, runner: psBusy, tools: psTools) == RunningOwners.toolBlocker(.npmCache))
        let psDown = OwnerFakeRunner()
        precondition(OwnerCachePolicy.executionBlocker(fallbackItem, runner: psDown, tools: psTools) == "无法检查运行状态，请重新扫描")
        let psIdle = OwnerFakeRunner(); psIdle.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n"); psIdle.responses["/fake/ps -axo command="] = ok("/sbin/launchd\n")
        precondition(OwnerCachePolicy.executionBlocker(fallbackItem, runner: psIdle, tools: psTools) == nil)

        // pnpm 元数据缓存与系统 Python 字节码：纯缓存，A 进废纸篓；pnpm 在跑就锁定，执行前再查一次
        let pnpmMeta = root + "/Library/Caches/pnpm", pyc = root + "/Library/Caches/com.apple.python"
        for p in [pnpmMeta, pyc] { try file(p + "/README") }
        let idleCtx = OwnerContext(scopes: [:], running: RunningOwners(commands: []), now: now)
        let meta = OwnerCachePolicy.candidates(for: rule("pnpm 元数据缓存", pnpmMeta), context: idleCtx)![0]
        precondition(meta.entry.tier == .obsolete && meta.entry.defaultChecked && meta.entry.reversible)
        let busyMeta = OwnerCachePolicy.candidates(for: rule("pnpm 元数据缓存", pnpmMeta),
            context: OwnerContext(scopes: [:], running: RunningOwners(commands: ["pnpm install"]), now: now))![0]
        precondition(busyMeta.entry.tier == .locked && busyMeta.entry.lockReason == RunningOwners.toolBlocker(.pnpmStorePrune))
        precondition(OwnerCachePolicy.candidates(for: rule("pnpm 元数据缓存", pnpmMeta),
            context: OwnerContext(scopes: [:], running: nil, now: now))![0].entry.tier == .review, "unknown running state is C")
        guard case .trash(let metaItem)? = meta.action else { preconditionFailure("pnpm metadata is a Trash row") }
        let psPnpm = OwnerFakeRunner(); psPnpm.responses["/bin/ps -axo command="] = ok("pnpm add x\n"); psPnpm.responses["/fake/ps -axo command="] = ok("pnpm add x\n")
        precondition(OwnerCachePolicy.executionBlocker(metaItem, runner: psPnpm, tools: psTools) == RunningOwners.toolBlocker(.pnpmStorePrune))
        precondition(OwnerCachePolicy.executionBlocker(metaItem, runner: psIdle, tools: psTools) == nil)
        let python = OwnerCachePolicy.candidates(for: rule("Python 字节码缓存", pyc), context: idleCtx)![0]
        precondition(python.entry.tier == .obsolete && python.entry.reversible)

        print("OwnerCachePolicyTests passed")
    }
}
