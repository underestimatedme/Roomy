// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Independent CLI schedules. Only exact scopes recognized by the native cache probes are authorized.
/// The GUI automation database is never changed; protection, recovery and the operation lease are shared.
enum CLISchedule {
    static func run(_ options: CLIOptions, state: URL, home: String,
                    now: Date = Date(), executable: String? = nil,
                    scopes: (() throws -> [AutomationScope])? = nil,
                    environment: AutomationEnvironment? = nil,
                    cleanup: CleanupEnvironment? = nil,
                    agentRunner: CommandRunning = ProcessRunner(),
                    confirm: (String) throws -> Void) throws -> CLIResponse {
        let store = AutomationStore(directory: state.appendingPathComponent("CLISchedules", isDirectory: true))
        let exists = FileManager.default.fileExists(atPath: store.directory.path)
        let db = exists ? try store.read() : AutomationDatabase()
        guard db.rules.allSatisfy({ $0.task == .cliCleanup }) else { throw cliError("命令行任务记录包含不支持的规则，已停止") }
        let action = options.scheduleAction ?? "list"
        let agent = CLIScheduleAgent(home: home, runner: agentRunner)
        func availableScopes() throws -> [AutomationScope] {
            let found = try scopes?() ?? AutomationDiscovery.scopes(home: home)
            let protection = CleanupProtectionStore(url: state.appendingPathComponent("protected-cleanup.json"))
            return try found.filter { try !protection.blocks(path: $0.path) }
        }
        if action == "scopes" {
            let found = try availableScopes()
            return CLIResponse(data: ["scopes": try cliObject(found)], text: found.isEmpty ? "暂无可授权的缓存范围。" :
                found.map { "\(cliSafeText($0.title))\n  \(cliSafeText($0.path))" }.joined(separator: "\n"))
        }
        if action == "list" || (action == "run" && !options.apply) {
            let rows: [[String: Any]] = try db.rules.map { rule in
                var row = try cliObject(rule) as! [String: Any]
                row["runtime"] = try cliObject(db.runtimes[rule.id] ?? AutomationRuntime())
                return row
            }
            let text = db.rules.map { rule in
                let runtime = db.runtimes[rule.id]
                let due = runtime?.nextDue.map { ISO8601DateFormatter().string(from: $0) } ?? "无"
                return "\(rule.id)  \(rule.enabled ? "已启用" : "已停用")  \(cliSafeText(rule.title))\n  每 \(rule.days ?? 0) 天；\(rule.repeats ? "重复" : "一次")；下次：\(due)"
                    + (runtime?.blocker.map { "\n  已阻断：" + cliSafeText($0) } ?? "")
                    + rule.scopes.map { "\n  " + cliSafeText($0.path) }.joined()
            }.joined(separator: "\n")
            return CLIResponse(data: ["rules": rows, "paused": db.paused, "executionAuthorized": false],
                               text: (text.isEmpty ? "暂无定时清理任务。" : text) + "\n未执行；使用 schedule install --apply 启用系统调度，或 schedule run --apply 检查到期任务。")
        }
        if action == "history" {
            let runs = Array(db.runs.suffix(100).reversed())
            return CLIResponse(data: ["runs": try cliObject(runs)], text: runs.isEmpty ? "暂无执行记录。" : runs.map {
                "\($0.id)  \($0.status.rawValue)  \(cliSafeText($0.title))\n  \(cliSafeText($0.message))"
            }.joined(separator: "\n"))
        }
        if action == "status" {
            let loaded = try agent.loaded()
            return CLIResponse(data: ["loaded": loaded, "plist": agent.url.path, "paused": db.paused, "enabledRules": db.rules.filter(\.enabled).count],
                text: "命令行后台：\(loaded ? "已加载" : "未加载")；已启用任务 \(db.rules.filter(\.enabled).count) 条\n\(cliSafeText(agent.url.path))")
        }
        if action == "add" {
            let found = try availableScopes()
            let selected = options.scheduleScopes.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path }
            guard !selected.isEmpty, Set(selected).count == selected.count,
                  selected.allSatisfy({ path in found.contains { $0.path == path } }) else {
                throw cliError("范围不是当前可授权缓存或已受保护；请先运行 roomy schedule scopes")
            }
            guard let volume = (environment?.volume ?? { AutomationDiscovery.volume(home: home) })() else { throw cliError("无法识别当前本地磁盘") }
            let rule = AutomationRule(title: options.subject ?? "", days: options.everyDays, repeats: !options.once,
                                      metric: nil, threshold: nil, mode: .automatic,
                                      scopes: found.filter { selected.contains($0.path) }, volumeID: volume.id, now: now, task: .cliCleanup)
            try rule.validate()
            let description = "定时清理：\(cliSafeText(rule.title))，每 \(rule.days!) 天\(rule.repeats ? "重复" : "执行一次")\n"
                + rule.scopes.map { "  " + cliSafeText($0.path) }.joined(separator: "\n")
                + "\n到期自动重新核验并移入废纸篓；不会清空废纸篓。"
            if !options.apply { return CLIResponse(data: ["rule": try cliObject(rule), "executionAuthorized": false], text: description + "\n未保存；添加 --apply。") }
            try confirm(description)
            try store.update { db in
                db.rules.append(rule); db.paused = false
                db.runtimes[rule.id] = AutomationRuntime(nextDue: now.addingTimeInterval(Double(rule.days!)*86400))
            }
            return CLIResponse(data: ["rule": try cliObject(rule)], text: "已保存任务：\(rule.id)\n使用 roomy schedule install --apply 启用系统调度。")
        }
        if ["enable", "disable", "remove"].contains(action) {
            guard let rule = db.rules.first(where: { $0.id == options.subject }) else { throw cliError("任务不存在") }
            let verb = ["enable": "启用", "disable": "停用", "remove": "删除任务"][action]!
            let description = "\(verb)：\(cliSafeText(rule.title))（\(rule.id)）"
            if !options.apply { return CLIResponse(data: ["rule": try cliObject(rule), "executionAuthorized": false], text: description + "\n未更改；添加 --apply。") }
            try confirm(description)
            try store.update { db in
                guard let index = db.rules.firstIndex(where: { $0.id == rule.id }) else { throw cliError("任务已变化") }
                if action == "enable", db.runs.contains(where: { $0.ruleID == rule.id && $0.intentID != nil && $0.acknowledgedAt == nil }) {
                    throw cliError("有中断后结果不确定的操作；核对后使用 schedule acknowledge RUNID --apply")
                }
                db.invalidateRuns(ruleID: rule.id, message: "命令行任务已\(verb)")
                if action == "remove" {
                    db.rules.remove(at: index); db.runtimes.removeValue(forKey: rule.id)
                } else {
                    db.rules[index].enabled = action == "enable"
                    db.rules[index].revision += 1; db.rules[index].updatedAt = now
                    if action == "enable" {
                        db.runtimes[rule.id] = AutomationRuntime(nextDue: now.addingTimeInterval(Double(rule.days!)*86400))
                    }
                }
            }
            return CLIResponse(data: ["id": rule.id, "action": action], text: "已\(verb)：\(rule.id)")
        }
        var description = action == "run" ? "执行所有已到期的命令行定时清理任务。" : "定时清理后台操作：\(action)"
        if action == "acknowledge" {
            guard let run = db.runs.first(where: { $0.id == options.subject }), run.status == .needsAttention,
                  run.intentID != nil, run.acknowledgedAt == nil else { throw cliError("没有尚待人工核对的不确定操作") }
            description = "确认已人工核对原目录、废纸篓和恢复记录：\(run.id)\n\(cliSafeText(run.message))"
        }
        if !options.apply { return CLIResponse(data: ["executionAuthorized": false], text: description + "\n未更改；添加 --apply。") }
        try confirm(description)
        if action == "install" {
            let program = executable ?? Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
            try agent.install(executable: program)
            return CLIResponse(data: ["loaded": true, "plist": agent.url.path], text: "已安装命令行调度；登录期间约每 15 分钟检查到期任务。")
        }
        if action == "uninstall" {
            try agent.uninstall()
            return CLIResponse(data: ["loaded": false], text: "已卸载命令行调度；任务和执行记录保留。")
        }
        if action == "acknowledge" {
            try AutomationWorker(store: store, environment: AutomationEnvironment()).acknowledge(runID: options.subject ?? "", now: now)
            return CLIResponse(data: ["acknowledged": options.subject ?? ""], text: "已记录人工核对；使用 schedule enable ID --apply 重新安排任务。")
        }
        guard action == "run" else { throw cliError("未知定时操作") }
        // A bare invocation in a fresh account must not create a worker or touch user files.
        guard exists else { return CLIResponse(data: ["runs": []], text: "暂无定时任务。") }
        var env = environment ?? AutomationEnvironment()
        env.allowsCLICleanup = true
        env.sharedStateDirectory = state
        if environment == nil {
            env.volume = { AutomationDiscovery.volume(home: home) }
            env.cleanup = cleanup ?? CleanupEnvironment()
            env.cleanup.home = home
            env.cleanup.roots = [home]
            let execution = env.cleanup
            env.access = {}
            env.discover = { rule in
                if rule.scopes.contains(where: { $0.kind == .derivedObjects }) {
                    guard let owners = RunningOwners.capture(runner: execution.runner, tools: execution.tools) else { throw cliError("无法检查 Xcode 运行状态") }
                    if owners.blocker(forRule: "Xcode DerivedData") != nil { return [] }
                }
                return try AutomationDiscovery.discover(rule: rule, home: home)
            }
            env.perform = { item, cleanup in
                if item.scope.kind == .derivedObjects {
                    guard let owners = RunningOwners.capture(runner: cleanup.runner, tools: cleanup.tools) else {
                        return CleanupOutcome(id: item.id, ok: false, message: "无法检查 Xcode 运行状态", bytes: 0)
                    }
                    if let reason = owners.blocker(forRule: "Xcode DerivedData") {
                        return CleanupOutcome(id: item.id, ok: false, message: reason, bytes: 0)
                    }
                }
                return CleanupRunner.run(ids: [item.id], list: CleanupList(candidates: [item.candidate]), env: cleanup, progress: { _ in }).outcomes[0]
            }
            // Validate the shared journal before any action. Keep the handle alive through tick().
            let journal = try CLIScheduleJournal(state: state)
            env.recordScheduledOutcome = { item, outcome in try journal.append(item, outcome) }
        }
        let worker = AutomationWorker(store: store, environment: env)
        try worker.tick(now: now)
        let after = try store.read()
        let latest = Array(after.runs.suffix(20))
        let blocked = after.rules.contains { $0.enabled && after.runtimes[$0.id]?.blocker != nil }
        let unsuccessful = latest.contains { $0.updatedAt >= now && [.partial, .needsAttention].contains($0.status) }
        return CLIResponse(data: ["runs": try cliObject(latest), "blocked": blocked],
            text: latest.map { "\($0.id)  \($0.status.rawValue)  \(cliSafeText($0.message))" }.joined(separator: "\n"), status: blocked || unsuccessful ? 3 : 0)
    }
}

private final class CLIScheduleJournal {
    let handle: FileHandle
    init(state: URL) throws {
        let fd = open(state.appendingPathComponent("operations.jsonl").path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw cliError("定时清理操作日志无法安全打开") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else {
            close(fd); throw cliError("定时清理操作日志类型或所有者异常")
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func append(_ item: AutomationItem, _ outcome: CleanupOutcome) throws {
        var data = try JSONSerialization.data(withJSONObject: [
            "at": ISO8601DateFormatter().string(from: Date()), "client": "cli-schedule", "source": "cleanup",
            "id": item.id, "title": item.item.name, "path": item.item.path, "action": "定时移入废纸篓",
            "ok": outcome.ok, "bytes": outcome.bytes, "message": outcome.message, "trashedTo": outcome.trashedTo ?? ""
        ], options: .sortedKeys)
        data.append(10)
        try handle.write(contentsOf: data); try handle.synchronize()
    }
}

/// A per-user agent with direct argv, no shell interpolation, sudo, or changes to the GUI scheduler.
struct CLIScheduleAgent {
    static let label = "com.atlaspaces.roomy.cli-cleanup"
    let home: String
    var runner: CommandRunning = ProcessRunner()
    var domain: String { "gui/\(getuid())" }
    var target: String { domain + "/" + Self.label }
    var url: URL { URL(fileURLWithPath: home + "/Library/LaunchAgents/" + Self.label + ".plist") }
    func loaded() throws -> Bool {
        let result = runner.run("/bin/launchctl", ["print", target], timeout: 10)
        if result.ok { return true }
        guard !result.timedOut, [3, 113].contains(result.status) else { throw cliError("无法读取 launchd 状态：" + result.stderr) }
        return false
    }
    static func plist(executable: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Label": label,
            "ProgramArguments": [executable, "schedule", "run", "--apply", "--yes"],
            "StartInterval": 900, "RunAtLoad": true, "ProcessType": "Background", "Umask": 0o077], format: .xml, options: 0)
    }
    private func checkExisting() throws {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            guard errno == ENOENT else { throw cliError("无法检查调度文件") }; return
        }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_mode & 0o022 == 0,
              let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              value["Label"] as? String == Self.label,
              let args = value["ProgramArguments"] as? [String], args.count == 5,
              Array(args.dropFirst()) == ["schedule", "run", "--apply", "--yes"] else { throw cliError("已有调度文件不属于 Roomy 命令行，未覆盖或移除") }
    }
    func install(executable: String) throws {
        let absolute = URL(fileURLWithPath: executable).path
        guard let resolved = realpath(absolute, nil) else { throw cliError("调度程序路径不存在或无法读取") }
        defer { free(resolved) }
        let program = String(cString: resolved)
        var st = stat()
        guard program.hasPrefix("/"), lstat(program, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              [getuid(), 0].contains(st.st_uid), st.st_mode & 0o022 == 0,
              FileManager.default.isExecutableFile(atPath: program),
              ApplicationAssociations.directoryIdentities((program as NSString).deletingLastPathComponent) != nil else {
            throw cliError("调度需要安全、可执行的 roomy 绝对路径；请先将 CLI 安装到固定目录")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard ApplicationAssociations.directoryIdentities(url.deletingLastPathComponent().path) != nil else { throw cliError("LaunchAgents 目录包含符号链接") }
        try checkExisting()
        // Unload before replacing; failed bootstrap leaves an explicit failure instead of claiming success.
        if try loaded() { try command(["bootout", target]) }
        let data = try Self.plist(executable: program)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".roomy-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw cliError("无法创建调度文件") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw cliError("无法保存调度文件") }
        do {
            try command(["enable", target])
            try command(["bootstrap", domain, url.path])
            guard try loaded() else { throw cliError("调度注册后未加载，请检查系统后台活动设置") }
        }
        catch {
            // Do not leave a new auto-loaded job configured after reporting a failed installation.
            _ = runner.run("/bin/launchctl", ["bootout", target], timeout: 15)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    func uninstall() throws {
        guard ApplicationAssociations.directoryIdentities(url.deletingLastPathComponent().path) != nil else {
            if !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) { return }
            throw cliError("LaunchAgents 目录不可安全读取")
        }
        try checkExisting()
        if try loaded() { try command(["bootout", target]) }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func command(_ arguments: [String]) throws {
        let result = runner.run("/bin/launchctl", arguments, timeout: 15)
        guard result.ok else { throw cliError("launchd 操作失败：" + result.stderr) }
    }
}
