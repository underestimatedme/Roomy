// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class FakeRunner: CommandRunning {
    var responses: [String: CommandResult] = [:]
    private(set) var calls: [String] = []
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        calls.append(key)
        return responses[key] ?? CommandResult(status: 1, stdout: "", stderr: "unexpected \(key)", timedOut: false)
    }
}

private func ok(_ text: String) -> CommandResult { CommandResult(status: 0, stdout: text, stderr: "", timedOut: false) }

private func makeApp(_ path: String, id: String, name: String, display: String? = nil) throws {
    try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
    var plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name]
    if let display { plist["CFBundleDisplayName"] = display }
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
}

private func makeDir(_ path: String, ageDays: Int, bytes: Int = 2_000_000) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data(count: bytes).write(to: URL(fileURLWithPath: path + "/blob"))
    let date = Date().addingTimeInterval(-Double(ageDays) * 86_400)
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: path + "/blob")
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

@main
struct AppLeftoverProbeTests {
    static func main() throws {
        precondition(AppLeftoverProbe.normalize("HBuilder X") == "hbuilderx")
        precondition(AppLeftoverProbe.normalize("微信 开发者-工具") == "微信开发者工具")
        precondition(AppLeftoverProbe.isBundleIDShaped("com.bambulab.bambu-studio"))
        precondition(!AppLeftoverProbe.isBundleIDShaped("QClaw") && !AppLeftoverProbe.isBundleIDShaped("v2.0"))

        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("roomy-leftover-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let tmp = realpath(temporary, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }!
        defer { try? fm.removeItem(atPath: tmp) }
        try makeApp(tmp + "/Applications/Cursor.app", id: "com.todesktop.230313mzl4w4u92", name: "Cursor")
        try makeApp(tmp + "/Applications/wechatwebdevtools.app", id: "com.tencent.webplusdevtools", name: "wechatwebdevtools",
                    display: "Wechat Devtools")
        try makeApp(tmp + "/Applications/Microsoft Word.app", id: "com.microsoft.Word", name: "Microsoft Word")

        let software = AppLeftoverProbe.InstalledSoftware.collect(
            appPaths: [tmp + "/Applications/Cursor.app", tmp + "/Applications/wechatwebdevtools.app",
                       tmp + "/Applications/Microsoft Word.app"],
            processes: ["/usr/local/bin/openclaw-gateway", "Finder", "com.apple.WebKit.WebContent"], commandNames: ["codex", "node"])
        precondition(AppLeftoverProbe.matches("Cursor", software))
        precondition(AppLeftoverProbe.matches("com.todesktop.230313mzl4w4u92.ShipIt", software), "helper of an installed app")
        precondition(AppLeftoverProbe.matches("com.microsoft.Word", software))
        precondition(AppLeftoverProbe.matches("Codex", software), "a CLI tool's data is not an app leftover")
        precondition(AppLeftoverProbe.matches("openclaw", software), "data of a running process is in use")
        precondition(!AppLeftoverProbe.matches("com.bambulab.bambu-studio", software))
        precondition(!AppLeftoverProbe.matches("riot-client-ux", software))
        precondition(AppLeftoverProbe.matches("com.microsoft.Excel", software), "same vendor still installed → not sure, keep")
        precondition(!AppLeftoverProbe.matches("com.electron.lark", software), "com.electron is a generic prefix")

        // 中文应用名、目录用英文：首个单词是已安装应用名称的开头 → 算已安装
        try makeApp(tmp + "/Applications/Riot用戶端.app", id: "com.riotgames.RiotGames.RiotClient", name: "Riot用戶端")
        let withRiot = AppLeftoverProbe.InstalledSoftware.collect(appPaths: [tmp + "/Applications/Riot用戶端.app"],
            processes: [], commandNames: [])
        precondition(AppLeftoverProbe.matches("riot-client-ux", withRiot))
        precondition(AppLeftoverProbe.matches("com.riotgames.LeagueofLegends.LeagueClient", withRiot))

        let lib = tmp + "/Library"
        try makeDir(lib + "/Application Support/riot-client-ux", ageDays: 300)          // 列出
        try makeDir(lib + "/Caches/com.bambulab.bambu-studio", ageDays: 120)             // 列出
        // 网络框架建的 WebKit / fsCachedData 子目录不能让它对上系统进程 com.apple.WebKit.WebContent
        for kid in ["WebKit", "fsCachedData"] {
            try fm.createDirectory(atPath: lib + "/Caches/com.bambulab.bambu-studio/" + kid, withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-120 * 86_400)], ofItemAtPath: lib + "/Caches/com.bambulab.bambu-studio/" + kid)
        }
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-120 * 86_400)], ofItemAtPath: lib + "/Caches/com.bambulab.bambu-studio")
        try makeDir(lib + "/Application Support/微信开发者工具", ageDays: 3)               // 名字对不上，但最近还在写 → 不列
        try makeDir(lib + "/Caches/微信开发者工具", ageDays: 200)                          // 同名目录别处最近还在写 → 也不列
        try makeDir(lib + "/Application Support/Cursor", ageDays: 400)                   // 已安装 → 不列
        try makeDir(lib + "/Application Support/CrashReporter", ageDays: 400)            // 系统共享目录 → 不列
        try makeDir(lib + "/Application Support/Google", ageDays: 400)                   // 厂商目录 → 不列
        try makeDir(lib + "/Caches/com.apple.Safari", ageDays: 400)                      // Apple → 不列
        try makeDir(lib + "/Application Support/Roomy", ageDays: 400)                    // 自己 → 不列
        try makeDir(lib + "/Application Support/tiny", ageDays: 400, bytes: 10)          // 太小 → 不列
        try makeDir(lib + "/Saved Application State/com.old.Tool.savedState", ageDays: 90)  // 列出
        // 外层目录很旧，但里面的文件今天还被写过 → 不列
        try makeDir(lib + "/Application Support/StillWriting", ageDays: 200)
        try Data(count: 10).write(to: URL(fileURLWithPath: lib + "/Application Support/StillWriting/today.log"))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-200 * 86_400)],
                             ofItemAtPath: lib + "/Application Support/StillWriting")

        let found = AppLeftoverProbe.candidates(library: lib, software: software, now: Date())
        let titles = found.map(\.entry.title).sorted()
        precondition(titles == ["应用残留 · com.bambulab.bambu-studio（Caches）", "应用残留 · com.old.Tool（Saved Application State）",
                                "应用残留 · riot-client-ux"], "\(titles)")
        for c in found {
            precondition(c.entry.defaultChecked == (c.entry.tier == .obsolete) && c.entry.risk == .amber && c.entry.reversible, "only A tier is pre-checked")
            precondition(c.entry.evidence.hasPrefix("找不到对应的应用或命令行工具 · "), c.entry.evidence)
            guard case .trash(let item) = c.action else { preconditionFailure("leftovers go to the Trash") }
            precondition(item.identity != nil)
        }
        precondition(found.first { $0.entry.path?.contains("/Caches/") == true }?.entry.tier == .obsolete)
        precondition(found.filter { $0.entry.path?.contains("/Caches/") != true }.allSatisfy { $0.entry.tier == .review })
        let cache = lib + "/Caches/com.bambulab.bambu-studio"
        try fm.createDirectory(atPath: cache + "/nested/deep", withIntermediateDirectories: true)
        try Data("recent cache write".utf8).write(to: URL(fileURLWithPath: cache + "/nested/deep/recent"))
        let oldDate = Date().addingTimeInterval(-120 * 86400)
        for path in [cache, cache + "/nested", cache + "/nested/deep"] {
            try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: path)
        }
        let activeCache = AppLeftoverProbe.candidates(library: lib, software: software, now: Date()).first { $0.entry.path == cache }
        precondition(activeCache?.entry.tier == .review, "deep current activity must not be labeled confirmed obsolete from shallow timestamps")

        // Spotlight 失败或结果异常少：宁可一项都不列，也不能把所有东西当成残留
        let runner = FakeRunner()
        let tools = ToolLocator(searchDirectories: [], isExecutable: { _ in true })
        precondition(AppLeftoverProbe.probe(runner: runner, tools: tools, library: lib).isEmpty)
        runner.responses["/usr/bin/mdfind kMDItemContentType == \"com.apple.application-bundle\""] =
            ok(tmp + "/Applications/Cursor.app\n")
        precondition(AppLeftoverProbe.probe(runner: runner, tools: tools, library: lib).isEmpty,
                     "too few apps from Spotlight → index is unreliable")

        // 启动程序已不存在的后台服务
        let agents = tmp + "/LaunchAgents"
        try fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
        func agent(_ label: String, program: [String]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": program],
                                                          format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: agents + "/\(label).plist"))
        }
        try agent("com.gone.helper", program: [tmp + "/Applications/Gone.app/Contents/MacOS/helper", "--run"])
        try agent("com.alive.helper", program: ["/bin/sh", "-c", "true"])
        try agent("-evil", program: [tmp + "/missing"])
        let services = AppLeftoverProbe.launchAgentCandidates(directory: agents)
        precondition(services.map(\.entry.title) == ["后台服务残留 · com.gone.helper"], "\(services.map(\.entry.title))")
        precondition(services[0].entry.tier == .obsolete && services[0].entry.defaultChecked && services[0].entry.evidence.contains("启动的程序已不存在"), "A 档即使 amber 也默认勾选")
        guard case .launchAgentRemove(let label, let item) = services[0].action else { preconditionFailure("action") }
        precondition(label == "com.gone.helper" && item.path == agents + "/com.gone.helper.plist")

        // 依赖快照：ProgramArguments 的所有绝对路径；坏/读不到的 plist 标为未知，旧 API 保持兼容
        let depsDir = tmp + "/DependencyAgents"
        try fm.createDirectory(atPath: depsDir, withIntermediateDirectories: true)
        func dependency(_ label: String, _ plist: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: depsDir + "/\(label).plist"))
        }
        let directProgram = tmp + "/agent/releases/0.4/bin/agent"
        let wrappedProgram = tmp + "/agent/releases/0.2/bin/agent"
        try dependency("com.direct", ["Label": "com.direct", "Program": directProgram,
                                      "WorkingDirectory": tmp + "/agent/releases/0.4"])
        try dependency("com.wrapped", ["Label": "com.wrapped", "ProgramArguments": ["/bin/sh", wrappedProgram]])
        let dependencies = AppLeftoverProbe.agentDependencySnapshot(directory: depsDir)
        precondition(dependencies.isComplete)
        precondition(Set(dependencies.agents.map(\.path))
            == [directProgram, wrappedProgram, tmp + "/agent/releases/0.4", "/bin/sh"], "\(dependencies.agents)")
        precondition(Set(AppLeftoverProbe.agentDependencies(directory: depsDir).map(\.path))
            == Set(dependencies.agents.map(\.path)), "old callers keep working")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: depsDir + "/com.broken.plist"))
        let broken = AppLeftoverProbe.agentDependencySnapshot(directory: depsDir)
        precondition(!broken.isComplete && broken.agents.count == 4, "\(broken.status)")
        precondition(AppLeftoverProbe.agentDependencies(directory: depsDir).count == 4,
            "old callers still get readable dependencies")
        precondition(!AppLeftoverProbe.agentDependencySnapshot(directory: tmp + "/NoSuchAgents").isComplete,
            "a missing LaunchAgents directory is unknown, not proof of no dependencies")
        if getuid() != 0 {
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: depsDir + "/com.direct.plist")
            precondition(!AppLeftoverProbe.agentDependencySnapshot(directory: depsDir).isComplete,
                "an unreadable plist is unknown, not absent")
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: depsDir + "/com.direct.plist")
            let unreadableDir = tmp + "/UnreadableAgents"
            try fm.createDirectory(atPath: unreadableDir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDir)
            precondition(!AppLeftoverProbe.agentDependencySnapshot(directory: unreadableDir).isComplete,
                "an unreadable LaunchAgents directory is unknown")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDir)
        }

        // 执行：先 bootout，再把 plist 移进废纸篓；程序又出现了就不动
        let svcRunner = FakeRunner()
        svcRunner.responses["/bin/launchctl print gui/\(getuid())/com.gone.helper"] = ok("path = \(agents)/com.gone.helper.plist")
        svcRunner.responses["/bin/launchctl bootout gui/\(getuid())/com.gone.helper"] = ok("")
        var trashed: [String] = []
        var env = CleanupEnvironment()
        env.runner = svcRunner; env.tools = tools; env.roots = [tmp]; env.diskFree = { 0 }
        env.trash = { trashed.append($0); return nil }
        var list = CleanupList(); list.candidates = services
        let done = CleanupRunner.run(ids: [services[0].entry.id], list: list, env: env) { _ in }
        precondition(done.outcomes[0].ok, done.outcomes[0].message)
        precondition(svcRunner.calls == ["/bin/launchctl print gui/\(getuid())/com.gone.helper",
                                         "/bin/launchctl bootout gui/\(getuid())/com.gone.helper"] && trashed == [item.path],
                     "\(svcRunner.calls)")

        try makeApp(tmp + "/Applications/Gone.app", id: "com.gone", name: "Gone")
        try fm.createDirectory(atPath: tmp + "/Applications/Gone.app/Contents/MacOS", withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: tmp + "/Applications/Gone.app/Contents/MacOS/helper"))
        let back = CleanupRunner.run(ids: [services[0].entry.id], list: list, env: env) { _ in }
        precondition(!back.outcomes[0].ok && back.outcomes[0].message == "它启动的程序又出现了，不再是残留")
        // 程序还在、但一直崩溃重启的后台服务：只提示，不能清理
        try agent("com.loop.gateway", program: ["/bin/sh", "-c", "exit 1"])
        try agent("com.fine.helper", program: ["/bin/sh", "-c", "true"])
        let health = FakeRunner()
        health.responses["/bin/launchctl print gui/\(getuid())/com.loop.gateway"] =
            ok("gui/502/com.loop.gateway = {\n\tstate = spawn scheduled\n\truns = 6361\n\tlast exit code = 1\n}")
        health.responses["/bin/launchctl print gui/\(getuid())/com.fine.helper"] =
            ok("gui/502/com.fine.helper = {\n\tstate = running\n\truns = 1\n\tlast exit code = (never exited)\n}")
        health.responses["/bin/launchctl print gui/\(getuid())/com.alive.helper"] =
            ok("gui/502/com.alive.helper = {\n\tstate = not running\n\truns = 3\n\tlast exit code = 1\n}")
        let failing = AppLeftoverProbe.failingAgentCandidates(directory: agents, runner: health, tools: tools)
        precondition(failing.map(\.entry.title) == ["后台服务反复失败 · com.loop.gateway"], "\(failing.map(\.entry.title))")
        precondition(!failing[0].entry.selectable && failing[0].action == nil)
        precondition(failing[0].entry.evidence.hasPrefix("已被拉起 6361 次，上次退出码 1"), failing[0].entry.evidence)
        print("AppLeftoverProbeTests passed")
    }
}
