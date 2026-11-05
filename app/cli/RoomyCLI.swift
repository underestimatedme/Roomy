// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

let cliHelp = """
Usage: roomy COMMAND [OPTIONS]
Roomy 腾地儿 · 免费 CLI · macOS 14+ · 默认只预览

  scan [--root PATH]                只读空间扫描（默认当前用户目录）
  disk [PATH]                      按占用排序；默认当前用户目录
      --files --query TEXT --min-bytes N --limit 1..200 --offset N
  apps [--query TEXT]               应用列表，可用 --limit / --offset
  preview APP                      应用关联预览；APP 为路径、精确名称或包标识
  clean [--id ID ...] [--no-overview] 新扫描的分档清单：A 放心清 / B 可选清 / C 确认后清 / 不能删
                                   --apply 时可找回项输入 MOVE 移入废纸篓；找不回的另输入 DELETE：
                                   npm/go/pip/uv/pnpm/brew 官方清理命令、docker builder prune、
                                   逐对象 docker volume/image/container rm、simctl、ollama rm
                                   完整预览会多走一遍磁盘统计空间去向（可能几分钟）；--no-overview 跳过
  uninstall APP [--id ID ...]       新应用预览；逐项选择，绝不自动全选
  history                          操作记录和可恢复记录
  restore ID                       预览恢复到记录中的原路径，不覆盖已有文件
  protect list                     与图形界面共享的保护清单
  protect add PATH                 保护现有路径及其包含/被包含的清理项目
  protect remove ID                移除保护记录
  permissions                      检查受支持应用的实际访问权限
  growth [PATH]                    查看空间变化；指定目录时完整扫描并记录
  tier list                        查看档位调整（你调整的和 Roomy 按你的习惯调整的）与历史
  tier set ID A|B|C                把当前清单中的项目换到 A 放心清 / B 可选清 / C 确认后清
  tier undo KEYID                  撤销一条档位调整
  tier reset                       重置全部手动档位调整
  version                          版本信息
  schedule scopes|list|history|status 查看可授权缓存、定时任务、执行记录和后台状态
  schedule add NAME --every-days N --scope PATH [--scope PATH ...] [--once]
                                   保存定时清理；到期重新核验所选缓存并移入废纸篓
  schedule enable|disable|remove ID 启用、停用或删除任务
  schedule acknowledge RUNID       人工核对中断结果后解除未决标记
  schedule install|uninstall        安装或卸载当前用户的 launchd 调度
  schedule run                     检查并执行到期任务；以上变更均需 --apply

  --json [FILE]                    JSON；省略 FILE 或使用 - 则写标准输出
  --apply                          处理和档位变更的执行开关
  --yes                            配合 --apply 跳过终端确认，用于明确选择的脚本
  --help, -h                       查看帮助，不扫描

执行前核查身份、归属和保护；不提供清空废纸篓的命令，不全盘清空，不自动提权。
无 --apply 时不清理、不卸载、不恢复。移入废纸篓不等于释放空间。
旧 --root、--json FILE、--index-root、--index-json 入口仍可使用。
核心与 CLI 采用 MPL-2.0；匹配源码与许可证随命令行发布包提供。
"""

struct CLIResponse {
    var data: [String: Any]
    var text: String
    var status: Int32 = 0
    func addingPreferenceWarnings(_ warnings: [String]) -> CLIResponse {
        guard !warnings.isEmpty else { return self }
        var response = self
        response.data["warnings"] = (data["warnings"] as? [String] ?? []) + warnings
        response.text += "\n" + warnings.map(cliSafeText).joined(separator: "\n")
        return response
    }
}
private final class CLIAsyncBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
    let signal = DispatchSemaphore(value: 0)
}
private func cliAwait<T>(_ body: @escaping () async throws -> T) throws -> T {
    let box = CLIAsyncBox<T>()
    Task { do { box.result = .success(try await body()) } catch { box.result = .failure(error) }; box.signal.signal() }
    box.signal.wait()
    return try box.result!.get()
}
func cliObject<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
func cliSafeText(_ value: String) -> String {
    value.unicodeScalars.map { CharacterSet.controlCharacters.union(.newlines).contains($0) ? String(format: "\\u%04X", $0.value) : String($0) }.joined()
}
func cliBytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
func cliEntries(_ entries: [CleanupEntry]) -> String {
    entries.map { entry in
        let size = entry.source == "appcache" && entry.actionLabel.isEmpty && entry.size == 0 ? "未统计" : cliBytes(entry.size)
        return "\(entry.id)  \(size)  \((entry.tier ?? .review).title)  \(entry.selectable ? (entry.reversible ? "可恢复" : "不可撤回") : "受保护/仅查看")  \(cliSafeText(entry.title))\n"
        + "  \(cliSafeText(entry.path ?? ""))\n  \(cliSafeText(entry.evidence))"
        + (entry.tierReason.map { "\n  分级依据：" + cliSafeText($0) } ?? "")
    }.joined(separator: "\n")
}

private func cliInteractive() -> Bool { isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1 }
private func cliPrompt(_ text: String) -> String? { fputs(text, stderr); return readLine() }

final class CLIEngine {
    private let home = NSHomeDirectory()
    private lazy var state = URL(fileURLWithPath: home + "/Library/Application Support/Roomy", isDirectory: true)
    private lazy var store = CleanupProtectionStore(url: state.appendingPathComponent("protected-cleanup.json"))
    private lazy var preferenceStore = CleanupPreferenceStore(directory: state)
    private lazy var ledger = TrashLedger(url: state.appendingPathComponent("pending-trash.json"))
    private var logHandle: FileHandle?
    private var logError: String?
    private var lease: OperationLease?

    private func prepareMutation() throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        guard ApplicationAssociations.directoryIdentities(state.path) != nil else { throw cliError("记录目录不可安全读取") }
        lease = try OperationLease.acquire(path: state.appendingPathComponent("operation.lock").path)
        _ = try store.all()
        let url = state.appendingPathComponent("pending-trash.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard CleanupIdentity.capture(path: url.path)?.kind == .file else { throw cliError("恢复记录不是普通文件") }
            _ = try JSONDecoder().decode([TrashedItem].self, from: Data(contentsOf: url))
        }
        let fd = open(state.appendingPathComponent("operations.jsonl").path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw cliError("操作日志无法写入，已暂停操作") }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1 else {
            close(fd); throw cliError("操作日志类型或所有者异常")
        }
        logHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    private func log(_ entry: [String: Any]) {
        do {
            var entry = entry; entry["client"] = "cli"
            var data = try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys); data.append(10)
            try logHandle?.write(contentsOf: data); try logHandle?.synchronize()
        } catch { logError = error.localizedDescription }
    }
    private func confirm(_ options: CLIOptions, preview: String, verb: String) throws {
        try CLIConfirmation.confirm(preview: preview, verb: verb, yes: options.yes, interactive: cliInteractive(),
                                    emit: { fputs($0, stderr) }, prompt: cliPrompt)
    }
    private func rootURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard CleanupIdentity.capture(path: url.path)?.kind == .directory else { throw cliError("扫描目录不存在、不可读取或为符号链接：\(path)") }
        return url
    }
    private func runningPaths() throws -> [String] {
        let result = ProcessRunner().run("/bin/ps", ["-axo", "comm="], timeout: 10)
        guard result.ok else { throw cliError("无法核查应用运行状态") }
        return result.stdout.split(separator: "\n").map(String.init)
    }
    private func applications() -> (ApplicationInventory, Bool) {
        let paths = try? runningPaths()
        return (ApplicationCatalog.discover(roots: ["/Applications", home + "/Applications", "/System/Applications"],
            runningPaths: paths ?? [], sizeOf: ApplicationSession.measure), paths != nil)
    }
    private func appPlan(_ subject: String) throws -> (UninstallPlan, Bool) {
        let (inventory, available) = applications()
        let path = URL(fileURLWithPath: (subject as NSString).expandingTildeInPath).path
        let matches = inventory.apps.filter { $0.path == path || $0.bundleID == subject || $0.id == subject || $0.title.caseInsensitiveCompare(subject) == .orderedSame }
        guard matches.count == 1, let app = matches.first else { throw cliError("应用不存在或有多个匹配，请使用准确安装路径") }
        var plan = try UninstallPlanner.preview(app: app, catalog: inventory.apps, home: home,
            temporaryDirectories: ApplicationTemporaryDirectory.current(), sizeOf: ApplicationSession.measure).applying(store)
        if !available { for i in plan.parts.indices { plan.parts[i].entry.selectable = false; plan.parts[i].entry.defaultChecked = false } }
        return (plan, available)
    }
    private func results(_ summary: CleanupRunSummary) throws -> CLIResponse {
        let recorded = Set(ledger.recoveryItems().map(\.path))
        var warnings: [String] = []
        if summary.outcomes.contains(where: { $0.ok && $0.trashedTo != nil && !recorded.contains($0.trashedTo!) }) {
            warnings.append("恢复记录未完整保存；请保留 outcomes 的废纸篓路径以手动恢复")
        }
        if let logError { warnings.append("日志写入失败：\(logError)") }
        let text = summary.outcomes.map { "\($0.id)  \($0.ok ? "完成" : "失败")  \(cliSafeText($0.message))  \(cliSafeText($0.trashedTo ?? ""))" }.joined(separator: "\n")
            + "\n移入废纸篓：\(cliBytes(summary.trashedBytes))；永久删除：\(cliBytes(summary.permanentBytes))；磁盘空闲变化：\(cliBytes(summary.freedBytes))（可能受其他进程影响）\n"
            + warnings.map(cliSafeText).joined(separator: "\n")
        return CLIResponse(data: ["outcomes": try cliObject(summary.outcomes), "trashedBytes": summary.trashedBytes,
            "permanentBytes": summary.permanentBytes, "observedFreeSpaceIncreaseBytes": summary.freedBytes, "warnings": warnings], text: text,
            status: summary.outcomes.contains(where: { !$0.ok }) || !warnings.isEmpty ? 3 : 0)
    }
    /// 与 `clean` 相同的新扫描：同样的清单、同样的预览标识
    private func freshCleanupList() throws -> (ScanPipelineResult, CleanupList) {
        let found = ScanPipeline.run(stage: { _, _, _ in })
        let running = RunningOwners.capture(runner: ProcessRunner(), tools: ToolLocator())
        let owners = OwnerContext(scopes: found.ownerScopes, running: running, now: Date())
        let built = CleanupListBuilder.build(items: found.items, probes: found.probes, agentPaths: AppLeftoverProbe.agentDependencies(),
                                             running: running, owners: owners)
        return (found, CLISelection.scoped(try store.apply(to: running == nil ? RunningOwners.markUnverified(built) : built)))
    }
    private func tierCommand(_ options: CLIOptions) throws -> CLIResponse {
        let confirmTier: (String) throws -> Void = { try self.confirm(options, preview: $0, verb: "TIER") }
        switch options.tierAction {
        case "list":
            return try CLITier.list(store: preferenceStore)
        case "undo":
            return try CLITier.undo(keyID: options.subject ?? "", apply: options.apply, store: preferenceStore,
                                    prepare: prepareMutation, confirm: confirmTier)
        case "reset":
            return try CLITier.reset(apply: options.apply, store: preferenceStore, prepare: prepareMutation, confirm: confirmTier)
        case "set":
            guard let id = options.subject, let tier = options.tier else { throw cliError("用法：roomy tier set ID A|B|C") }
            let (_, list) = try freshCleanupList()
            let learning = CleanupPreferenceLearning(store: preferenceStore, source: .cli)
            guard let entry = learning.decorate(list.entries).first(where: { $0.id == id }) else { throw cliError("项目不在当前清单中，请重新运行 roomy clean 查看") }
            return try CLITier.set(entry: entry, tier: tier, apply: options.apply, store: preferenceStore,
                                   prepare: prepareMutation, confirm: confirmTier).addingPreferenceWarnings(learning.warnings)
        default: throw cliError("用法：roomy tier list | set ID A|B|C | undo KEYID | reset")
        }
    }
    func run(_ options: CLIOptions) throws -> CLIResponse {
        if options.command == "schedule" {
            return try CLISchedule.run(options, state: state, home: home, confirm: {
                try self.confirm(options, preview: $0, verb: "SCHEDULE")
            })
        }
        if ["permissions", "growth"].contains(options.command) { return try CLIMaintenance.run(options, prepareMutation: prepareMutation) }
        switch options.command {
        case "tier": return try tierCommand(options)
        case "scan":
            let root = try rootURL(options.root)
            let report = options.legacy ? runLegacyRuleScan() : try cliAwait { try await runUnifiedScan(root: root) }
            let rows = report.layers.flatMap(\.items).sorted { $0.size > $1.size }.prefix(options.limit)
            return CLIResponse(data: ["root": root.path, "report": try cliObject(report)], text:
                "只读扫描：\(cliSafeText(root.path))\n\(report.stats.files) 文件 / \(report.stats.dirs) 目录；读不到 \(report.stats.denied) 处\n"
                + "已读到的实际占用：\(cliBytes(report.diskTree.allocatedBytes))；所在卷可用：\(cliBytes(report.machine.diskFree))\n"
                + rows.map { "\(cliBytes($0.size))  \(cliSafeText($0.path))  \(cliSafeText($0.evidence))" }.joined(separator: "\n")
                + "\n命中大小不等于可释放空间；使用 roomy clean 查看可处理项目。")
        case "disk":
            let root = try rootURL(options.root)
            let scan = try cliAwait { try await runIndexScan(root: root, workerCount: 4) }
            let page = try DiskExplorer(index: scan.index, diagnostics: scan.diagnostics).page(id: "0", query: options.query,
                filesOnly: options.filesOnly, minBytes: options.minBytes, offset: options.offset, limit: options.limit)
            return CLIResponse(data: ["page": try cliObject(page)], text:
                "只读占用：\(cliSafeText(page.path)) · \(cliBytes(page.size)) · \(page.total) 个结果 · 跳过 \(page.skipped) 处\n"
                + page.items.map { "\(cliBytes($0.size))  \($0.kind)  \(cliSafeText($0.path))\($0.incomplete ? " [统计不完整]" : "")" }.joined(separator: "\n"))
        case "apps":
            let (inventory, available) = applications()
            let filtered = inventory.apps.filter { options.query.isEmpty || ($0.title + " " + $0.bundleID + " " + $0.path).localizedCaseInsensitiveContains(options.query) }
            let start = min(options.offset, filtered.count), end = min(start + options.limit, filtered.count), page = Array(filtered[start..<end])
            return CLIResponse(data: ["apps": try cliObject(page), "total": filtered.count, "offset": start, "warnings": inventory.warnings, "processCheckAvailable": available],
                text: "应用 \(filtered.count) 个；当前返回 \(page.count) 个\(available ? "" : " [运行状态未知，仅查看]")\n"
                + page.map { "\($0.id)  \(cliBytes($0.size))  \(cliSafeText($0.title))  \(cliSafeText($0.bundleID))\n  \(cliSafeText($0.path))" }.joined(separator: "\n")
                + inventory.warnings.map { "\n警告：\(cliSafeText($0))" }.joined())
        case "preview", "uninstall":
            if options.apply { try prepareMutation() }
            let (plan, available) = try appPlan(options.subject!)
            let shown = CLISelection.scoped(CleanupList(candidates: plan.candidates), context: CLISelection.identityKey(plan.app.identity))
            let shownByNativeID = Dictionary(uniqueKeysWithValues: zip(plan.candidates, shown.candidates).map { ($0.entry.id, $1.entry.id) })
            var parts = plan.parts
            for i in parts.indices {
                if let display = shown.entries.first(where: { $0.id == shownByNativeID[parts[i].entry.id] }) {
                    let selectable = parts[i].entry.selectable
                    parts[i].entry = display
                    parts[i].entry.selectable = selectable && display.selectable
                    if !available { parts[i].entry.defaultChecked = false }
                }
            }
            let selected = parts.filter { options.ids.contains($0.entry.id) }
            if !options.apply {
                return CLIResponse(data: ["app": try cliObject(plan.app), "parts": try cliObject(parts), "notices": plan.notices,
                    "processCheckAvailable": available, "executionAuthorized": false],
                    text: "\(cliSafeText(plan.app.title)) · 关联预览\n" + cliEntries(parts.map(\.entry)) + "\n" + plan.notices.map(cliSafeText).joined(separator: "\n") + "\n未执行；需逐项 --id 并明确 --apply。")
            }
            guard available else { throw cliError("运行状态无法核查，未执行卸载") }
            guard Set(options.ids).isSubset(of: Set(selected.map { $0.entry.id })), selected.allSatisfy({ $0.entry.selectable }) else { throw cliError("选择中含未知或受保护项，未执行卸载") }
            try confirm(options, preview: "准备移入废纸篓：\n" + cliEntries(selected.map(\.entry)), verb: "MOVE")
            let nativeIDs = plan.candidates.filter { options.ids.contains(shownByNativeID[$0.entry.id] ?? "") }.map { $0.entry.id }
            var env = CleanupEnvironment()
            env.log = { entry in
                self.log(entry)
                // Record each completed move before the runner starts its next
                // item, so partial interruption retains already-finished work.
                CLIWorkflow.recordMove(entry, list: CleanupList(candidates: plan.candidates), ledger: self.ledger)
            }
            let summary = try UninstallRunner.run(plan: plan, ids: nativeIDs, store: store,
                appRoots: ["/Applications", home + "/Applications"], catalogRoots: ["/Applications", home + "/Applications", "/System/Applications"], env: env, runningPaths: runningPaths)
            let visible = summary.outcomes.map { result in
                CleanupOutcome(id: shownByNativeID[result.id] ?? result.id, ok: result.ok, message: result.message, bytes: result.bytes, trashedTo: result.trashedTo)
            }
            return try results(CleanupRunSummary(outcomes: visible, freedBytes: summary.freedBytes, trashedBytes: summary.trashedBytes, permanentBytes: summary.permanentBytes))
        case "clean":
            if options.apply {
                guard !options.ids.isEmpty else { throw cliError("请逐项指定本轮扫描返回的 --id") }
                try prepareMutation()
            }
            let (found, list) = try freshCleanupList()
            let learning = CleanupPreferenceLearning(store: preferenceStore, source: .cli)
            let entries = learning.decorate(list.entries)
            let selected = options.ids.isEmpty ? entries : entries.filter { options.ids.contains($0.id) }
            guard options.ids.isEmpty || Set(options.ids).isSubset(of: Set(selected.map(\.id))) else { throw cliError("项目不在当前清单中，请重新扫描") }
            if !options.apply {
                // 清单和 --id 解析已经完成；空间去向和健康提醒在这之后才算（要走一遍磁盘，会慢一些）
                // 只有完整预览（没有 --id）才走一遍磁盘；指定 --id 或 --no-overview 时跳过，结论和健康提醒照常
                let wantOverview = !options.noOverview && options.ids.isEmpty
                let agents = list.candidates.filter { $0.entry.source == "agenthealth" }
                let inputs = CLIReport.gather(wantOverview: wantOverview, home: home,
                    usage: SpaceOverview.dataVolumeUsage,
                    walk: { let w = ScanPipeline.folderWalk(roots: found.sizeRoots, reuse: found.measured); return (w.rootTotals, w.unreadable) },
                    health: { HealthReport.collect(runner: ProcessRunner(), tools: ToolLocator(), launchAgents: agents) },
                    progress: { fputs($0 + "\n", stderr) })
                let report = try CLIReport.preview(entries: entries, shown: selected, overview: inputs.overview,
                    overviewError: inputs.overviewError,
                    overviewSkipped: wantOverview ? nil : (options.noOverview ? "--no-overview" : "指定 --id 时不统计"),
                    health: inputs.health,
                    pendingTrash: (ledger.pending().count, ledger.pending().reduce(UInt64(0)) { $0 + $1.bytes }),
                    free: inputs.free, home: home)
                var data = report.data
                data["warnings"] = learning.warnings + found.rootWarnings
                data["codeRoots"] = found.codeRoots
                data["executionAuthorized"] = false
                data["scope"] = "fast rules and tool probes including bounded application sandbox caches; unreadable content is not measured"
                return CLIResponse(data: data, text:
                    "只读清理预览（含支持的沙盒缓存；读取失败会单独提示，未统计不代表零占用）：\n" + report.text + "\n未执行；用 --id ID --apply 执行。")
            }
            guard selected.allSatisfy({ $0.selectable && $0.tier != .locked }) else { throw cliError("所选内容受保护或不能删，未执行") }
            // 先问可找回项（MOVE），再问不可撤回项（DELETE）；任一取消都在执行前抛错，整体不执行
            try CLIConfirmation.confirmClean(selected, yes: options.yes, interactive: cliInteractive(),
                                             emit: { fputs($0, stderr) }, prompt: cliPrompt)
            var env = CleanupEnvironment(); env.log = log
            return try results(CLIWorkflow.clean(ids: options.ids, list: list, store: store, ledger: ledger, environment: env, learning: learning))
                .addingPreferenceWarnings(learning.warnings)
        case "history":
            let items = ledger.recoveryItems(), operations = try OperationHistory.read(url: state.appendingPathComponent("operations.jsonl"))
            let records: [[String: Any]] = items.map { ["id": $0.recoveryID, "title": $0.title, "bytes": $0.bytes,
                "originalPath": $0.originalPath ?? "", "trashPath": $0.path, "at": $0.recordedAt ?? "", "note": $0.recoveryNote ?? ""] }
            return CLIResponse(data: ["recoverable": records, "operations": operations], text: "可恢复记录 \(items.count) 项；近期操作 \(operations.count) 项\n"
                + items.map { "\($0.recoveryID)  \(cliSafeText($0.title))\n  原位置：\(cliSafeText($0.originalPath ?? "旧记录缺少原路径，请手动恢复"))" }.joined(separator: "\n"))
        case "restore":
            guard ledger.recoveryItems().contains(where: { $0.recoveryID == options.subject }) else { throw cliError("恢复记录不存在或文件身份已变化") }
            if options.apply { try prepareMutation() }
            guard let item = ledger.recoveryItems().first(where: { $0.recoveryID == options.subject }) else { throw cliError("记录不存在或文件身份已变化") }
            let preview = "恢复 \(cliSafeText(item.title))\n\(cliSafeText(item.path)) → \(cliSafeText(item.originalPath ?? "旧记录缺少原路径"))"
            if !options.apply { return CLIResponse(data: ["item": try cliObject(item), "id": item.recoveryID, "executionAuthorized": false], text: preview + "\n未执行；添加 --apply 恢复。") }
            try confirm(options, preview: preview, verb: "RESTORE")
            let learning = CleanupPreferenceLearning(store: preferenceStore, source: .cli)
            let restored = try learning.restore(ledger: ledger, id: item.recoveryID)
            // 恢复没有本轮清单：只让已学到的档位按恢复降一档
            learning.applyLearning(entries: [])
            log(["at": ISO8601DateFormatter().string(from: Date()), "source": "restore", "ok": true, "title": restored.title,
                 "path": restored.originalPath ?? "", "bytes": restored.bytes, "action": "还原到原位置"])
            return CLIResponse(data: ["restored": try cliObject(restored), "warnings": logError.map { [$0] } ?? []], text: "已恢复：\(cliSafeText(restored.originalPath ?? ""))", status: logError == nil ? 0 : 3).addingPreferenceWarnings(learning.warnings)
        case "protect":
            let parts = options.subject!.components(separatedBy: "\u{0}")
            if parts[0] != "list" { try prepareMutation() }
            let learning = CleanupPreferenceLearning(store: preferenceStore, source: .cli)
            if parts[0] == "add" {
                let path = URL(fileURLWithPath: (parts[1] as NSString).expandingTildeInPath).path
                guard let identity = CleanupIdentity.capture(path: path), identity.kind != .symbolicLink else { throw cliError("保护路径不存在或为符号链接") }
                let item = ScanItem.trashTarget(path: path, name: (path as NSString).lastPathComponent, size: 0, rule: "manual", evidence: "命令行手动保护", risk: .lock)
                let candidate = CleanupCandidate(source: "manual-protection", key: path, title: item.name, size: 0, evidence: item.evidence, risk: .lock, action: .trash(item: item))
                try store.set(candidate, protected: true)
                learning.attempt { try preferenceStore.protect(candidateID: candidate.entry.id, title: item.name, path: path, key: nil) }
            } else if parts[0] == "remove" {
                guard try store.all().contains(where: { $0.id == parts[1] }) else { throw cliError("保护记录不存在") }; try store.remove(id: parts[1])
                learning.attempt { try preferenceStore.unprotect(candidateID: parts[1]) }
            }
            let records = try store.all()
            return CLIResponse(data: ["protections": try cliObject(records)], text: records.map { "\($0.id)  \(cliSafeText($0.title))  \(cliSafeText($0.path ?? ""))" }.joined(separator: "\n")).addingPreferenceWarnings(learning.warnings)
        default: throw cliError("未知命令")
        }
    }
}

func runRoomyCLI(_ args: [String]) -> Int32 {
    OpenFileLimit.raise()
    let options: CLIOptions
    do { options = try CLIOptions.parse(args) }
    catch { fputs(cliSafeText(error.localizedDescription) + "\n", stderr); return 2 }
    if options.command == "help" { print(cliHelp); return 0 }
    if options.command == "version" { print("roomy 0.1.8"); return 0 }
    let mutating = options.apply || (options.command == "protect" && options.subject?.hasPrefix("list") == false)
    var destination: FileHandle?
    var responseData: Data?
    do {
        if let output = options.json, output != "-" {
            let path = (output as NSString).expandingTildeInPath
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw cliError("导出文件无法创建，未覆盖原文件：\(String(cString: strerror(errno)))") }
            destination = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let response = try CLIEngine().run(options)
        if let output = options.json {
            let payload: [String: Any] = ["schemaVersion": 1, "command": options.command, "readOnly": !mutating, "data": response.data]
            var data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]); data.append(10)
            responseData = data
            if output == "-" { try FileHandle.standardOutput.write(contentsOf: data) }
            else {
                try destination?.write(contentsOf: data); try destination?.synchronize(); try destination?.close()
                print("已导出：\(cliSafeText(output))")
            }
        } else { print(response.text) }
        return response.status
    } catch {
        fputs(cliSafeText(error.localizedDescription) + "\n", stderr)
        if mutating, let responseData {
            // The operation may already have completed. Preserve its outcomes
            // even if the export disk fails; never report it as an unrun action.
            try? FileHandle.standardOutput.write(contentsOf: responseData)
            return 3
        }
        return 1
    }
}
