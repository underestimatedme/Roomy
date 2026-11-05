// SPDX-License-Identifier: GPL-3.0-only
// 一键腾出的执行器：按 id 查表 → 执行前复核 → 执行 → 逐项回报 → 写日志。
// "实际多出"只认磁盘剩余空间的前后差值。

import Foundation

struct CleanupEnvironment {
    var runner: CommandRunning = ProcessRunner()
    var tools = ToolLocator()
    var roots: [String] = [HOME] + ALL_CODE_ROOTS
    var selectedCodeRoots: [SavedCodeRoot] = (try? CodeRootStore.shared.records()) ?? []
    /// 扫描与执行前复核共用的范围；测试可注入隔离目录
    var home: String = HOME
    var codeRoots: [String] = CodeRoots.splitProtected(ALL_CODE_ROOTS).fast
    var androidHome: String? = SdkCopyProbe.currentAndroidHome()
    var applicationRoots: [String]? = nil  // nil uses the standard installed-app roots for cache ownership.
    var applicationCacheMeasurement: (String) -> UInt64? = { ApplicationSession.measure($0) }
    var minimumDepth = 2  // An explicit code-root identity can authorize its already-eligible direct child.
    /// 移到废纸篓，返回在废纸篓里的位置（写进日志，方便找回）
    var trash: (String) throws -> String? = { path in
        var out: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
        return out?.path
    }
    var log: ([String: Any]) -> Void = { _ in }
    var diskFree: () -> UInt64 = { diskUsage().1 }
}

struct CleanupOutcome: Codable, Equatable {
    let id: String
    let ok: Bool
    let message: String
    let bytes: UInt64
    var trashedTo: String? = nil
}

struct CleanupRunSummary {
    let outcomes: [CleanupOutcome]
    let freedBytes: UInt64     // 磁盘剩余空间的实测变化
    let trashedBytes: UInt64   // 进了废纸篓的部分：同一卷上不释放空间，清空废纸篓后才释放
    var permanentBytes: UInt64 = 0   // 不可撤回且成功的项的字节合计（工具直接删除，没有废纸篓可找回）
}

enum CleanupRunner {
    static let commandTimeout: TimeInterval = 60

    static func run(ids: [String], list: CleanupList, env: CleanupEnvironment,
                    progress: (CleanupOutcome) -> Void) -> CleanupRunSummary {
        let before = env.diskFree()
        let iso = ISO8601DateFormatter()
        var outcomes: [CleanupOutcome] = []
        var trashed: UInt64 = 0
        var permanent: UInt64 = 0
        for id in ids {
            let candidate = list.candidate(id: id)
            let outcome: CleanupOutcome
            if let candidate, candidate.entry.selectable, let action = candidate.action {
                outcome = execute(action, entry: candidate.entry, env: env)
            } else {
                outcome = CleanupOutcome(id: id, ok: false, message: "不在本次清单里，请重新扫描", bytes: 0)
            }
            env.log(["at": iso.string(from: Date()), "id": id, "title": candidate?.entry.title ?? "",
                     "action": candidate.flatMap { $0.action.map { describe($0, env: env) } } ?? "none",
                     "ok": outcome.ok, "message": outcome.message, "bytes": outcome.bytes,
                     "trashedTo": outcome.trashedTo ?? "", "source": "cleanup"])
            outcomes.append(outcome)
            if outcome.ok, candidate?.action?.reversible == true { trashed += outcome.bytes }
            if outcome.ok, candidate?.action?.reversible == false { permanent += outcome.bytes }
            progress(outcome)
        }
        let after = env.diskFree()
        return CleanupRunSummary(outcomes: outcomes, freedBytes: after > before ? after - before : 0,
                                 trashedBytes: trashed, permanentBytes: permanent)
    }

    private static func execute(_ action: CleanupAction, entry: CleanupEntry, env: CleanupEnvironment) -> CleanupOutcome {
        func done(_ bytes: UInt64, _ message: String = "") -> CleanupOutcome {
            CleanupOutcome(id: entry.id, ok: true, message: message, bytes: bytes)
        }
        func fail(_ message: String) -> CleanupOutcome {
            CleanupOutcome(id: entry.id, ok: false, message: message, bytes: 0)
        }
        switch action {
        case .trash(let item):
            if entry.source == "appcache", let blocker = ApplicationCacheProbe.executionBlocker(path: item.path, environment: env) {
                return fail(blocker)
            }
            if entry.source == InstalledAppDataProbe.source, let blocker = InstalledAppDataProbe.executionBlocker(path: item.path, environment: env) {
                return fail(blocker)
            }
            switch trashValidated(item, env: env) {
            case .success(let dest): return CleanupOutcome(id: entry.id, ok: true, message: "", bytes: entry.size, trashedTo: dest)
            case .failure(let why): return fail(why.message)
            }

        case .simctlDeleteDevice(let udid):
            guard CleanupArgument.isUUID(udid) else { return fail("模拟器标识不合法") }
            if let why = SimulatorProbe.deviceBlocker(udid: udid, runner: env.runner, tools: env.tools) { return fail(why) }
            return command(.xcrun, ["simctl", "delete", udid], env: env).failure.map(fail) ?? done(entry.size)

        case .simctlDeleteRuntime(let id):
            guard CleanupArgument.isUUID(id) else { return fail("运行时标识不合法") }
            if let why = SimulatorProbe.runtimeBlocker(id: id, runner: env.runner, tools: env.tools) { return fail(why) }
            return command(.xcrun, ["simctl", "runtime", "delete", id], env: env).failure.map(fail) ?? done(entry.size)

        case .ollamaRemove(let model):
            guard CleanupArgument.isModelName(model) else { return fail("模型名不合法") }
            if let why = OllamaProbe.modelBlocker(model: model, runner: env.runner, tools: env.tools) { return fail(why) }
            return command(.ollama, ["rm", model], env: env).failure.map(fail) ?? done(entry.size)

        case .dockerRemove(let kind, let id, let expectedID):
            // 只删预览里列出的这一个对象；执行前再确认它还在、还是预览时那个、没被容器用上
            guard CleanupArgument.isDockerReference(id) else { return fail("Docker 对象标识不合法") }
            if let why = DockerProbe.objectBlocker(kind: kind, id: id, expectedID: expectedID,
                                                   runner: env.runner, tools: env.tools) { return fail(why) }
            let result = command(.docker, DockerProbe.removeArguments(kind: kind, id: id), env: env, toolInvocation: true)
            return result.failure.map(fail) ?? done(entry.size)

        case .toolClean(let c, let scope):
            if let why = ToolCleanScope.blocker(c, expected: scope, runner: env.runner, tools: env.tools) { return fail(why) }
            // 所有者（npm、go 等）在运行时不清它的整块缓存；读不到进程列表也不清
            if let why = RunningOwners.executionBlocker(forTool: c, runner: env.runner, tools: env.tools) { return fail(why) }
            let result = command(c.tool, c.arguments, env: env, timeout: c.timeout, toolInvocation: true, irreversible: true)
            if let why = result.failure { return fail(why) }
            if c.exactSize { return done(entry.size) }
            // 大小不可知：不报字节，把工具自己说的最后一行留给用户看
            let last = result.output?.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            return done(0, last ?? "")

        case .launchAgentRemove(let label, let item):
            return removeLaunchAgent(label: label, item: item, entry: entry, env: env)

        case .worktreeRemove(let item, let repo, let branch, let base):
            if let why = WorktreeProbe.blocker(path: item.path, repo: repo, branch: branch, base: base,
                                               runner: env.runner, tools: env.tools,
                                               expectedHead: item.cleanupEvidence?.kind == "gitWorktree" ? item.cleanupEvidence?.fingerprint : nil) { return fail(why) }
            // 不 prune：git 那边的记录留着，从废纸篓放回原处 worktree 立即可用；
            // 没放回的，git 会在 gc.worktreePruneExpire（默认约 3 个月）后自己清掉记录
            switch trashValidated(item, env: env) {
            case .success(let dest): return CleanupOutcome(id: entry.id, ok: true, message: "", bytes: entry.size, trashedTo: dest)
            case .failure(let why): return fail(why.message)
            }
        }
    }

    private static func removeLaunchAgent(label: String, item: ScanItem, entry: CleanupEntry,
                                          env: CleanupEnvironment) -> CleanupOutcome {
        func fail(_ m: String) -> CleanupOutcome { CleanupOutcome(id: entry.id, ok: false, message: m, bytes: 0) }
        guard CleanupArgument.isLaunchLabel(label) else { return fail("启动项标签不合法") }
        if let why = AppLeftoverProbe.launchAgentBlocker(plist: item.path) { return fail(why) }
        let target = "gui/\(getuid())/\(label)"
        // 只停"确实由这个 plist 加载"的服务。同名服务来自别处（比如应用更新后自己注册的）时不碰它，只移走过期的 plist
        let loaded = command(.launchctl, ["print", target], env: env)
        if loaded.failure == nil, let output = loaded.output {
            let from = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("path = ") }.map { String($0.dropFirst("path = ".count)) }
            if from == item.path, let why = command(.launchctl, ["bootout", target], env: env).failure { return fail(why) }
        }
        switch trashValidated(item, env: env) {
        case .success(let dest): return CleanupOutcome(id: entry.id, ok: true, message: "", bytes: entry.size, trashedTo: dest)
        case .failure(let why): return fail(why.message)
        }
    }

    struct Failure: Error { let message: String }

    /// 成功时返回废纸篓里的位置
    private static func trashValidated(_ item: ScanItem, env: CleanupEnvironment) -> Result<String?, Failure> {
        func canonical(_ path: String) -> String {
            realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? GitRepositoryDiscovery.normalizedPath(path)
        }
        let target = canonical(item.path)
        guard !env.roots.contains(where: { canonical($0) == target }),
              !env.selectedCodeRoots.contains(where: { canonical($0.path) == target }) else {
            return .failure(Failure(message: "扫描根目录本身不能清理；请选择其内部已核验的项目。"))
        }
        guard let root = env.roots.filter({ item.path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
            return .failure(Failure(message: "不在允许清理的目录里"))
        }
        let selected = env.selectedCodeRoots.first { $0.path == root }
        switch CleanupValidator().validate(path: item.path, expected: item, home: root,
            minimumDepth: env.minimumDepth, selectedRoot: selected,
            runner: env.runner, tools: env.tools,
            probeCodeRoots: env.codeRoots, probeHome: env.home, probeAndroidHome: env.androidHome) {
        case .allowed(let live):
            _ = live.parentDescriptor   // 持有父目录 fd 直到移走为止
            do { return .success(try env.trash(item.path)) } catch {
                let ns = error as NSError
                switch ns.code {
                case NSFileWriteNoPermissionError, 513:
                    return .failure(Failure(message: "没有权限。到 系统设置 → 隐私与安全性 → 完全磁盘访问 里勾上腾地儿"))
                case NSFileLockingError: return .failure(Failure(message: "文件正被别的程序占用，先退出那个程序"))
                default: return .failure(Failure(message: ns.localizedDescription))
                }
            }
        case .changed(let reason): return .failure(Failure(message: "扫描后发生了变化：\(reason)，请重新扫描"))
        case .blocked(let reason): return .failure(Failure(message: reason))
        }
    }

    /// toolInvocation：包管理器整体清理和 docker 删除对象，按 ToolInvocation 的 PATH、工作目录和环境运行
    private static func command(_ tool: Tool, _ args: [String], env: CleanupEnvironment,
                                timeout: TimeInterval = commandTimeout,
                                toolInvocation: Bool = false, irreversible: Bool = false) -> (output: String?, failure: String?) {
        guard let exe = env.tools.path(for: tool) else { return (nil, "找不到 \(tool.rawValue)") }
        let r = toolInvocation
            ? ToolInvocation.run(tool, executable: exe, args, runner: env.runner, tools: env.tools, timeout: timeout)
            : env.runner.run(exe, args, timeout: timeout)
        // 整块清理被超时打断时已经删掉的部分找不回来：如实告诉用户
        if r.timedOut { return (nil, "\(tool.rawValue) 超过 \(Int(timeout)) 秒没有完成" + (irreversible ? "，可能已部分删除" : "")) }
        guard r.status == 0 else { return (nil, "\(tool.rawValue) 退出码 \(r.status)：\(String(r.stderr.suffix(2048)))") }
        return (r.stdout, nil)
    }

    private static func describe(_ action: CleanupAction, env: CleanupEnvironment) -> String {
        switch action {
        case .trash(let item): return "trash \(item.path)"
        case .simctlDeleteDevice(let udid): return "xcrun simctl delete \(udid)"
        case .simctlDeleteRuntime(let id): return "xcrun simctl runtime delete \(id)"
        case .ollamaRemove(let model): return "ollama rm \(model)"
        case .dockerRemove(let kind, let id, _):
            return ([env.tools.path(for: .docker) ?? "docker"] + DockerProbe.removeArguments(kind: kind, id: id)).joined(separator: " ")
        case .toolClean(let c, let scope):
            let exe = env.tools.path(for: c.tool) ?? c.tool.rawValue
            return ([exe] + c.arguments).joined(separator: " ") + " scope=\(scope)"
        case .worktreeRemove(let item, _, _, _): return "trash worktree \(item.path)"
        case .launchAgentRemove(let label, let item): return "launchctl bootout \(label) + trash \(item.path)"
        }
    }
}
