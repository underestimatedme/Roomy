// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class FakeRunner: CommandRunning {
    var responses: [String: CommandResult] = [:]
    private(set) var calls: [String] = []
    private(set) var timeouts: [String: TimeInterval] = [:]
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        calls.append(key); timeouts[key] = timeout
        return responses[key] ?? CommandResult(status: 1, stdout: "", stderr: "unexpected \(key)", timedOut: false)
    }
    private(set) var environments: [String: [String: String]] = [:]
    private(set) var directories: [String: String] = [:]
    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             timeout: TimeInterval) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        environments[key] = environment; directories[key] = directory
        return run(executable, arguments, timeout: timeout)
    }
}

private func ok(_ text: String = "") -> CommandResult { CommandResult(status: 0, stdout: text, stderr: "", timedOut: false) }

@main
struct ToolCleanTests {
    static func main() throws {
        let fm = FileManager.default
        let tools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { _ in true })

        // ── 命令表
        precondition(ToolCleanCommand.allCases.count == 8)
        precondition(ToolCleanCommand.npmCache.tool == .npm && ToolCleanCommand.npmCache.arguments == ["cache", "clean", "--force", "--no-update-notifier"])
        precondition(ToolCleanCommand.npmCache.scopeQuery == ["config", "get", "cache", "--no-update-notifier"], "npm queries must not reach the registry")
        precondition(ToolCleanCommand.npmCache.label == "npm cache clean --force", "label stays readable")
        precondition(ToolCleanCommand.goModCache.arguments == ["clean", "-modcache"] && ToolCleanCommand.goModCache.exactSize)
        precondition(ToolCleanCommand.pnpmStorePrune.scopeQuery == ["store", "path"] && !ToolCleanCommand.pnpmStorePrune.exactSize)
        precondition(ToolCleanCommand.brewCleanup.scopeQuery == ["--cache"] && !ToolCleanCommand.brewCleanup.exactSize)
        precondition(ToolCleanCommand.dockerBuilderPrune.scopeQuery == nil && ToolCleanCommand.dockerBuilderPrune.arguments == ["builder", "prune", "-f"])
        precondition(ToolCleanCommand.pipCache.tool == .pip3 && ToolCleanCommand.uvCache.tool == .uv)
        precondition(ToolCleanCommand.allCases.filter(\.exactSize) == [.npmCache, .goBuildCache, .goModCache, .pipCache, .uvCache])
        precondition(CleanupAction.toolClean(.npmCache, scope: "/x").label == "用 npm cache clean --force 清空")
        precondition(!CleanupAction.toolClean(.npmCache, scope: "/x").reversible)
        let home = ToolLocator()
        precondition(home.searchDirectories.contains("\(HOME)/.local/bin") && home.searchDirectories.contains("\(HOME)/.cargo/bin")
            && home.searchDirectories.contains("/usr/local/go/bin"))

        // ── scopeResolves
        let scopeRunner = FakeRunner()
        scopeRunner.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/x/.npm\n")
        scopeRunner.responses["/fake/go env GOCACHE"] = ok("/tmp/x/go-build\n")
        scopeRunner.responses["/fake/docker info --format {{.ServerVersion}}"] = ok("27.0")
        precondition(ToolCleanScope.resolve(.npmCache, runner: scopeRunner, tools: tools) == "/tmp/x/.npm/_cacache")
        precondition(ToolCleanScope.resolve(.goBuildCache, runner: scopeRunner, tools: tools) == "/tmp/x/go-build")
        precondition(ToolCleanScope.resolve(.goModCache, runner: scopeRunner, tools: tools) == nil, "query failed → nil")
        precondition(ToolCleanScope.resolve(.dockerBuilderPrune, runner: scopeRunner, tools: tools) == nil, "no scope query")
        precondition(ToolCleanScope.resolve(.npmCache, runner: scopeRunner, tools: ToolLocator(searchDirectories: [], isExecutable: { _ in false })) == nil)

        // ── scopeMismatchSkips / runsExactCommand
        let expected = "/tmp/x/.npm/_cacache"
        func candidate(_ c: ToolCleanCommand, scope: String, size: UInt64 = 4242) -> CleanupCandidate {
            CleanupCandidate(source: "toolclean", key: c.rawValue, title: c.label, size: size, evidence: "e",
                risk: .amber, action: .toolClean(c, scope: scope))
        }
        func makeEnv(_ runner: FakeRunner, tools: ToolLocator, log: @escaping ([String: Any]) -> Void = { _ in }) -> CleanupEnvironment {
            var env = CleanupEnvironment()
            env.runner = runner; env.tools = tools; env.roots = ["/nonexistent"]; env.selectedCodeRoots = []
            env.diskFree = { 0 }; env.log = log
            return env
        }
        func list(_ c: CleanupCandidate) -> CleanupList { var l = CleanupList(); l.candidates = [c]; return l }

        let mismatch = FakeRunner()
        mismatch.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/y/.npm\n")
        precondition(ToolCleanScope.blocker(.npmCache, expected: expected, runner: mismatch, tools: tools) != nil)
        let npmC = candidate(.npmCache, scope: expected)
        let bad = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC), env: makeEnv(mismatch, tools: tools)) { _ in }
        precondition(bad.outcomes[0].ok == false && bad.outcomes[0].bytes == 0, "\(bad.outcomes)")
        precondition(!mismatch.calls.contains { $0.contains("cache clean") }, "\(mismatch.calls)")
        precondition(bad.permanentBytes == 0)

        let good = FakeRunner()
        good.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        good.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/x/.npm\n")
        good.responses["/fake/npm cache clean --force --no-update-notifier"] = ok("")
        var logged: [[String: Any]] = []
        let done = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC),
            env: makeEnv(good, tools: tools, log: { logged.append($0) })) { _ in }
        precondition(good.calls.last == "/fake/npm cache clean --force --no-update-notifier", "\(good.calls)")
        precondition(done.outcomes[0].ok && done.outcomes[0].bytes == 4242, "\(done.outcomes)")
        precondition(done.permanentBytes == 4242 && done.trashedBytes == 0, "\(done.permanentBytes) \(done.trashedBytes)")
        // 工具在 GUI（Finder 启动，PATH 很短）里也要能跑：PATH 带上工具自己的目录；工作目录固定为 HOME
        for key in ["/fake/npm config get cache --no-update-notifier", "/fake/npm cache clean --force --no-update-notifier"] {
            let path = good.environments[key]?["PATH"] ?? ""
            precondition(path.split(separator: ":").first == "/fake" && path.contains("/usr/bin"), "\(key): \(path)")
            precondition(good.directories[key] == HOME, "\(key) must run from HOME, not the caller's project")
        }
        let goRunner = FakeRunner()
        goRunner.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        goRunner.responses["/fake/go env GOCACHE"] = ok("/tmp/x/go-build\n")
        goRunner.responses["/fake/go clean -cache"] = ok("")
        let goC = candidate(.goBuildCache, scope: "/tmp/x/go-build")
        let goRun = CleanupRunner.run(ids: [goC.entry.id], list: list(goC), env: makeEnv(goRunner, tools: tools)) { _ in }
        precondition(goRun.outcomes[0].ok, "\(goRun.outcomes)")
        for key in ["/fake/go env GOCACHE", "/fake/go clean -cache"] {
            precondition(goRunner.environments[key]?["GOTOOLCHAIN"] == "local", "\(key) must not download a toolchain")
            precondition(goRunner.directories[key] == HOME)
        }
        precondition(logged.first?["action"] as? String == "/fake/npm cache clean --force --no-update-notifier scope=\(expected)", "\(logged)")

        // 工具自己失败：不算成功，不计入 permanentBytes
        let failing = FakeRunner()
        failing.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        failing.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/x/.npm\n")
        failing.responses["/fake/npm cache clean --force --no-update-notifier"] = CommandResult(status: 1, stdout: "", stderr: "boom", timedOut: false)
        let failed = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC), env: makeEnv(failing, tools: tools)) { _ in }
        precondition(!failed.outcomes[0].ok && failed.permanentBytes == 0 && failed.outcomes[0].message.contains("boom"))

        // ── symlinkScopeRefused
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-toolclean-\(UUID().uuidString)").resolvingSymlinksInPath().path
        defer { try? fm.removeItem(atPath: tmp) }
        try fm.createDirectory(atPath: tmp + "/real", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: tmp + "/link", withDestinationPath: tmp + "/real")
        let linkRunner = FakeRunner()
        linkRunner.responses["/fake/uv cache dir"] = ok(tmp + "/real\n")
        precondition(ToolCleanScope.blocker(.uvCache, expected: tmp + "/link", runner: linkRunner, tools: tools) != nil, "symlink expected path refused")
        precondition(ToolCleanScope.blocker(.uvCache, expected: tmp + "/real", runner: linkRunner, tools: tools) == nil, "plain match passes")
        linkRunner.responses["/fake/uv cache dir"] = ok(tmp + "/link\n")
        precondition(ToolCleanScope.blocker(.uvCache, expected: tmp + "/link", runner: linkRunner, tools: tools) != nil)
        // 工具报告的路径是符号链接、预期是它指向的真实目录：realpath 后一致
        precondition(ToolCleanScope.blocker(.uvCache, expected: tmp + "/real", runner: linkRunner, tools: tools) == nil)
        // 不合理的预期范围
        precondition(ToolCleanScope.blocker(.uvCache, expected: "/", runner: linkRunner, tools: tools) != nil)
        precondition(ToolCleanScope.blocker(.uvCache, expected: "relative", runner: linkRunner, tools: tools) != nil)

        // ── missingToolFails
        let none = ToolLocator(searchDirectories: [], isExecutable: { _ in false })
        let missing = FakeRunner()
        let miss = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC), env: makeEnv(missing, tools: none)) { _ in }
        precondition(!miss.outcomes[0].ok && miss.outcomes[0].message == "找不到 npm", "\(miss.outcomes)")
        precondition(missing.calls.isEmpty)

        // ── pnpmApproximate
        let pnpmScope = tmp + "/pnpm"
        try fm.createDirectory(atPath: pnpmScope + "/store/v3", withIntermediateDirectories: true)
        let pnpmRunner = FakeRunner()
        pnpmRunner.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        pnpmRunner.responses["/fake/pnpm store path"] = ok(pnpmScope + "/store/v3\n")
        pnpmRunner.responses["/fake/pnpm store prune"] = ok("Removed all cached metadata files\nRemoved 12 packages\n")
        precondition(ToolCleanScope.blocker(.pnpmStorePrune, expected: pnpmScope, runner: pnpmRunner, tools: tools) == nil, "reported store under expected")
        precondition(ToolCleanScope.blocker(.pnpmStorePrune, expected: tmp + "/other", runner: pnpmRunner, tools: tools) != nil)
        precondition(ToolCleanScope.blocker(.pnpmStorePrune, expected: pnpmScope + "/sto", runner: pnpmRunner, tools: tools) != nil, "prefix must be a path boundary")
        let pnpmC = candidate(.pnpmStorePrune, scope: pnpmScope)
        let pnpm = CleanupRunner.run(ids: [pnpmC.entry.id], list: list(pnpmC), env: makeEnv(pnpmRunner, tools: tools)) { _ in }
        precondition(pnpm.outcomes[0].ok && pnpm.outcomes[0].bytes == 0, "\(pnpm.outcomes)")
        precondition(pnpm.outcomes[0].message.contains("Removed 12 packages"), pnpm.outcomes[0].message)
        precondition(pnpm.permanentBytes == 0)

        // ── docker builder prune：复用 daemonBlocker，没有 scope 查询
        let dockerRunner = FakeRunner()
        dockerRunner.responses["/fake/docker context inspect --format {{.Endpoints.docker.Host}}"] = ok("unix:///x.sock")
        dockerRunner.responses["/fake/docker info --format {{.ServerVersion}}"] = ok("27.0")
        dockerRunner.responses["/fake/docker builder prune -f"] = ok("Total:\t1.2GB\n")
        let dockerC = candidate(.dockerBuilderPrune, scope: "Docker 构建缓存")
        let docker = CleanupRunner.run(ids: [dockerC.entry.id], list: list(dockerC), env: makeEnv(dockerRunner, tools: tools)) { _ in }
        if ProcessInfo.processInfo.environment["DOCKER_HOST"] == nil {
            precondition(docker.outcomes[0].ok && dockerRunner.calls.last == "/fake/docker builder prune -f", "\(docker.outcomes) \(dockerRunner.calls)")
        }
        let dockerDown = FakeRunner()
        let downRun = CleanupRunner.run(ids: [dockerC.entry.id], list: list(dockerC), env: makeEnv(dockerDown, tools: tools)) { _ in }
        precondition(!downRun.outcomes[0].ok && !dockerDown.calls.contains { $0.contains("builder prune") })

        // ── 所有者在运行：执行前拒绝，不调用清理命令；读不到进程列表：同样拒绝（fail closed）
        let busyRunner = FakeRunner()
        busyRunner.responses["/bin/ps -axo command="] = ok("/sbin/launchd\nnpm exec @softeria/ms-365-mcp-server --org-mode\n")
        busyRunner.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/x/.npm\n")
        busyRunner.responses["/fake/npm cache clean --force --no-update-notifier"] = ok("")
        let busy = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC), env: makeEnv(busyRunner, tools: tools)) { _ in }
        precondition(!busy.outcomes[0].ok && busy.outcomes[0].message == RunningOwners.toolBlocker(.npmCache), "\(busy.outcomes)")
        precondition(!busyRunner.calls.contains { $0.contains("cache clean") } && busy.permanentBytes == 0, "\(busyRunner.calls)")
        let goBusyRunner = FakeRunner()
        goBusyRunner.responses["/bin/ps -axo command="] = ok("go run ./cmd/server\n")
        goBusyRunner.responses["/fake/go env GOCACHE"] = ok("/tmp/x/go-build\n")
        goBusyRunner.responses["/fake/go clean -cache"] = ok("")
        let goBusy = CleanupRunner.run(ids: [goC.entry.id], list: list(goC), env: makeEnv(goBusyRunner, tools: tools)) { _ in }
        precondition(!goBusy.outcomes[0].ok && !goBusyRunner.calls.contains("/fake/go clean -cache"), "\(goBusy.outcomes)")
        let psDown = FakeRunner()
        psDown.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/x/.npm\n")
        psDown.responses["/fake/npm cache clean --force --no-update-notifier"] = ok("")
        let unknown = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC), env: makeEnv(psDown, tools: tools)) { _ in }
        precondition(!unknown.outcomes[0].ok && unknown.outcomes[0].message == "无法检查运行状态，请重新扫描", "\(unknown.outcomes)")
        precondition(!psDown.calls.contains { $0.contains("cache clean") })

        // ── 整块清理不可撤回：给足时间，不在删到一半时被杀掉；真超时要说明可能已部分删除
        precondition(ToolCleanCommand.allCases.allSatisfy { $0.timeout >= 1800 }, "\(ToolCleanCommand.allCases.map(\.timeout))")
        precondition(good.timeouts["/fake/npm cache clean --force --no-update-notifier"] == ToolCleanCommand.npmCache.timeout,
            "\(good.timeouts)")
        let slowRunner = FakeRunner()
        slowRunner.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        slowRunner.responses["/fake/npm config get cache --no-update-notifier"] = ok("/tmp/x/.npm\n")
        slowRunner.responses["/fake/npm cache clean --force --no-update-notifier"] = CommandResult(status: 15, stdout: "", stderr: "", timedOut: true)
        let slow = CleanupRunner.run(ids: [npmC.entry.id], list: list(npmC), env: makeEnv(slowRunner, tools: tools)) { _ in }
        precondition(!slow.outcomes[0].ok && slow.outcomes[0].bytes == 0 && slow.permanentBytes == 0)
        precondition(slow.outcomes[0].message == "npm 超过 \(Int(ToolCleanCommand.npmCache.timeout)) 秒没有完成，可能已部分删除", slow.outcomes[0].message)

        // ── brew cleanup 默认还会 autoremove 没人依赖的软件包：执行范围不能超出预览，环境里关掉它，也不自动更新
        let brewEnv = ToolInvocation.environment(for: .brew, executable: "/fake/brew", tools: tools, base: ["PATH": "/usr/bin"])
        precondition(brewEnv["HOMEBREW_NO_AUTOREMOVE"] == "1" && brewEnv["HOMEBREW_NO_AUTO_UPDATE"] == "1", "\(brewEnv)")
        precondition(ToolInvocation.environment(for: .npm, executable: "/fake/npm", tools: tools, base: [:])["HOMEBREW_NO_AUTOREMOVE"] == nil)
        let brewScope = tmp + "/Homebrew"
        try fm.createDirectory(atPath: brewScope, withIntermediateDirectories: true)
        let brewRunner = FakeRunner()
        brewRunner.responses["/bin/ps -axo command="] = ok("/sbin/launchd\n")
        brewRunner.responses["/fake/brew --cache"] = ok(brewScope + "\n")
        brewRunner.responses["/fake/brew cleanup"] = ok("Removing: /x/old.bottle\n")
        let brewRun = CleanupRunner.run(ids: [candidate(.brewCleanup, scope: brewScope).entry.id], list: list(candidate(.brewCleanup, scope: brewScope)),
                                        env: makeEnv(brewRunner, tools: tools)) { _ in }
        precondition(brewRun.outcomes[0].ok, "\(brewRun.outcomes)")
        precondition(brewRunner.environments["/fake/brew cleanup"]?["HOMEBREW_NO_AUTOREMOVE"] == "1", "brew cleanup must not autoremove")

        // ── 复审描述
        let review = try CleanupReview(ids: [npmC.entry.id], list: list(npmC))
        let markdown = try review.markdown(appVersion: "t")
        precondition(markdown.contains("清空由 npm 管理的整个 \(expected)"), markdown)
        // brew cleanup 不只清缓存目录：还会删除已安装软件包的旧版本，描述必须说清楚
        let brewC = candidate(.brewCleanup, scope: "/tmp/x/Homebrew")
        let brewReview = try CleanupReview(ids: [brewC.entry.id], list: list(brewC)).markdown(appVersion: "t")
        precondition(brewReview.contains("旧版本") && !brewReview.contains("清空由 brew 管理的整个"), brewReview)
        precondition(CleanupAction.toolClean(.brewCleanup, scope: "/x").label.contains("旧版本"))
        print("ToolCleanTests passed")
    }
}
