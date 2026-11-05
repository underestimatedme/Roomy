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

private func ok(_ text: String = "") -> CommandResult { CommandResult(status: 0, stdout: text, stderr: "", timedOut: false) }

@main
struct CLIWorkflowTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-cli-workflow-" + UUID().uuidString
        try fm.createDirectory(atPath: root + "/home/cache", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/trash", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let path = root + "/home/cache/sample"
        let bytes = Data("keep original bytes".utf8)
        try bytes.write(to: URL(fileURLWithPath: path))
        let item = ScanItem.trashTarget(path: path, name: "sample", size: 4096, rule: "sample", evidence: "fixture", risk: .green)
        let candidate = CleanupCandidate(source: "test", key: path, title: "sample", size: 4096, evidence: "fixture", risk: .green, action: .trash(item: item))
        let irreversible = CleanupCandidate(source: "test", key: "docker", title: "docker", size: 1, evidence: "fixture", risk: .amber, action: .dockerRemove(kind: .volume, id: "v1"))
        let lockedC = CleanupCandidate(source: "test", key: "locked", title: "locked", size: 7, evidence: "fixture", risk: .amber,
            action: .dockerRemove(kind: .volume, id: "v2")).locked("正被进程使用")
        // tier 为 locked 但 selectable 仍为 true 的坏数据：tier 检查必须单独拦住它
        let lockedSelectable = CleanupCandidate(source: "test", key: "locked-selectable", title: "ls", size: 5, evidence: "fixture", risk: .amber,
            action: .dockerRemove(kind: .volume, id: "v3"), tier: .locked, tierReason: "fixture")
        precondition(lockedSelectable.entry.selectable && lockedSelectable.entry.tier == .locked)
        let runner = FakeRunner()
        runner.responses["/fake/docker info --format {{.ServerVersion}}"] = ok("27.0")
        runner.responses["/fake/docker context inspect --format {{.Endpoints.docker.Host}}"] = ok("unix:///var/run/docker.sock")
        runner.responses["/fake/docker volume inspect --format {{.Name}} v1"] = ok("v1\n")
        runner.responses["/fake/docker ps -a --filter volume=v1 -q"] = ok("")
        runner.responses["/fake/docker volume rm v1"] = ok("v1\n")
        let store = CleanupProtectionStore(url: URL(fileURLWithPath: root + "/protected.json"))
        let ledgerURL = URL(fileURLWithPath: root + "/ledger.json")
        let ledger = TrashLedger(url: ledgerURL, trashRoots: [root + "/trash"])
        var environment = CleanupEnvironment()
        environment.roots = [root + "/home"]
        environment.diskFree = { 100 }
        environment.runner = runner
        environment.tools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { _ in true }, dockerHost: nil)
        environment.trash = { source in
            let target = root + "/trash/sample"
            try fm.moveItem(atPath: source, toPath: target)
            return target
        }
        let list = CleanupList(candidates: [candidate, irreversible, lockedC, lockedSelectable])
        // 未知 id 或 locked 条目：整批拒绝，什么都不执行
        for ids in [[candidate.entry.id, "unknown"], [candidate.entry.id, lockedC.entry.id], [lockedC.entry.id], [lockedSelectable.entry.id]] {
            do { _ = try CLIWorkflow.clean(ids: ids, list: list, store: store, ledger: ledger, environment: environment); fatalError("must refuse the whole invalid selection") }
            catch { precondition("\(error)".contains("所选项目未知、受保护或不能删；未执行任何清理"), "\(error)") }
            precondition(fm.fileExists(atPath: path))
            precondition(runner.calls.isEmpty, "refused selection must not run any command: \(runner.calls)")
        }
        // 不可撤回项（docker volume rm）现在可执行，字节计入 permanentBytes
        let permanent = try CLIWorkflow.clean(ids: [irreversible.entry.id], list: list, store: store, ledger: ledger, environment: environment)
        precondition(permanent.outcomes.count == 1 && permanent.outcomes[0].ok, "\(permanent.outcomes)")
        precondition(permanent.permanentBytes == 1 && permanent.trashedBytes == 0, "permanent \(permanent.permanentBytes) trashed \(permanent.trashedBytes)")
        precondition(runner.calls.contains("/fake/docker volume rm v1"), "\(runner.calls)")
        precondition(ledger.recoveryItems().isEmpty, "irreversible items leave no trash record")
        try store.set(candidate, protected: true)
        do { _ = try CLIWorkflow.clean(ids: [candidate.entry.id], list: list, store: store, ledger: ledger, environment: environment); fatalError("persistent protection must block CLI") }
        catch {}
        precondition(fm.fileExists(atPath: path))
        try store.remove(id: candidate.entry.id)
        let result = try CLIWorkflow.clean(ids: [candidate.entry.id], list: list, store: store, ledger: ledger, environment: environment)
        precondition(result.outcomes.count == 1 && result.outcomes[0].ok)
        precondition(result.freedBytes == 0 && result.trashedBytes == 4096 && result.permanentBytes == 0)
        let reloaded = TrashLedger(url: ledgerURL, trashRoots: [root + "/trash"])
        let recorded = reloaded.recoveryItems()
        precondition(recorded.count == 1 && recorded[0].originalPath == path)
        _ = try reloaded.restore(id: recorded[0].recoveryID)
        let restored = try Data(contentsOf: URL(fileURLWithPath: path))
        precondition(restored == bytes)

        // ── clean 预览：六段同序输出，JSON 带 overview / health / summary
        func tiered(_ c: CleanupCandidate, _ t: CleanupTier) -> CleanupEntry { var e = c.entry; e.tier = t; e.path = e.path ?? "/x/" + e.id; return e }
        let report: [CleanupEntry] = [tiered(candidate, .obsolete), tiered(irreversible, .rebuildable)]
        let overview = SpaceOverview.compute(dataUsed: 434, free: 22, areaSizes: ["/Users/j": 146, "/opt": 96],
                                             unreadable: ["/private/var/root", "/Users/j/Desktop"], home: "/Users/j")
        let finding = HealthFinding(id: "docker-context:old", title: "Docker 上下文 old 已失效", detail: "socket 不存在",
                                    advice: "确认后可删除", command: "docker context rm old")
        let titles = ["结论", "空间去向", "读不到的空间", "分档清单", "健康提醒", "清理顺序"]
        func order(_ text: String) -> [Int] { titles.map { (text.range(of: "== \($0) ==")?.lowerBound.utf16Offset(in: text)) ?? -1 } }
        let full = try CLIReport.preview(entries: report, shown: report, overview: overview, overviewError: nil, health: [finding],
                                         pendingTrash: (count: 2, bytes: 3000), free: 22, home: "/Users/j")
        for key in ["overview", "health", "summary", "entries"] { precondition(full.data[key] != nil, "missing \(key)") }
        precondition(!(full.data["overview"] is NSNull) && (full.data["health"] as? [Any])?.count == 1)
        precondition((full.data["summary"] as? [String: Any])?["freeAfterA"] != nil, "\(full.data["summary"] ?? "nil")")
        let positions = order(full.text)
        precondition(positions.allSatisfy { $0 >= 0 } && positions == positions.sorted(), "six sections in order: \(positions)")
        precondition(full.text.contains("只清 A 后约") && full.text.contains("清 A+B 后约") && full.text.contains("清空废纸篓后才释放"), full.text)
        precondition(full.text.contains("另有 1 个系统目录无权读取") && full.text.contains("~/Desktop"), full.text)
        precondition(full.text.contains("完全磁盘访问权限") && full.text.contains("docker context rm old"), full.text)
        precondition(full.text.contains("先处理可找回的部分，用一两天确认没问题") && full.text.contains("再在 Finder 清空废纸篓")
                     && full.text.contains("不可撤回的放最后") && full.text.contains("2 项"), full.text)
        // 量不出来就说无法测量，不写 0
        let failed = try CLIReport.preview(entries: report, shown: report, overview: nil, overviewError: "无法读取磁盘用量", health: [],
                                           pendingTrash: (count: 0, bytes: 0), free: nil, home: "/Users/j")
        precondition(failed.data["overview"] is NSNull && failed.data["overviewError"] as? String == "无法读取磁盘用量")
        precondition(failed.data["health"] != nil && failed.data["summary"] != nil)
        precondition(failed.text.contains("无法测量") && !failed.text.contains("只清 A 后约"), failed.text)
        let failedPositions = order(failed.text)
        precondition(failedPositions.allSatisfy { $0 >= 0 } && failedPositions == failedPositions.sorted(), "\(failedPositions)")

        // 结论以"现在可用"开头：有数据卷可用空间就写它，读不到写无法测量
        precondition(full.text.hasPrefix("== 结论 ==\n现在可用 \(cliBytes(22))\n"), full.text)
        precondition(failed.text.hasPrefix("== 结论 ==\n现在可用：无法测量\n"), failed.text)
        let fromOverview = try CLIReport.preview(entries: report, shown: report, overview: overview, overviewError: nil, health: [],
                                                 pendingTrash: (count: 0, bytes: 0), free: nil, home: "/Users/j")
        precondition(fromOverview.text.hasPrefix("== 结论 ==\n现在可用 \(cliBytes(overview.free))\n"), fromOverview.text)

        // ── --no-overview 选项；只有完整预览（无 --id、无 --apply）才走磁盘遍历
        let withFlag = try CLIOptions.parse(["clean", "--no-overview"]), withoutFlag = try CLIOptions.parse(["clean"])
        precondition(withFlag.noOverview && !withoutFlag.noOverview)
        for bad in [["scan", "--no-overview"], ["clean", "--no-overview", "--no-overview"]] {
            do { _ = try CLIOptions.parse(bad); preconditionFailure("accepted \(bad)") } catch {}
        }
        var walks = 0, healthRuns = 0, progress: [String] = []
        func gather(_ want: Bool) -> CLIReport.Inputs {
            CLIReport.gather(wantOverview: want, home: "/Users/j", usage: { (used: 434, free: 22) },
                walk: { walks += 1; return (["/Users/j": 146], []) }, health: { healthRuns += 1; return [] },
                progress: { progress.append($0) })
        }
        let skipped = gather(false)
        precondition(walks == 0 && healthRuns == 1 && progress.isEmpty, "walk must not run: \(walks) \(healthRuns) \(progress)")
        precondition(skipped.overview == nil && skipped.overviewError == nil && skipped.free == 22, "free space is cheap and stays known")
        let walked = gather(true)
        precondition(walks == 1 && healthRuns == 2 && progress.count == 1 && progress[0].contains("--no-overview"), "\(walks) \(progress)")
        precondition(walked.overview?.areas.first?.bytes == 146 && walked.free == 22)
        let skippedReport = try CLIReport.preview(entries: report, shown: report, overview: nil, overviewError: nil,
            overviewSkipped: "--no-overview", health: [], pendingTrash: (count: 0, bytes: 0), free: 22, home: "/Users/j")
        precondition(skippedReport.data["overview"] is NSNull && skippedReport.data["overviewSkipped"] as? Bool == true)
        precondition(skippedReport.data["overviewError"] == nil)
        precondition(skippedReport.text.contains("未统计（--no-overview）") && !skippedReport.text.contains("无法测量"), skippedReport.text)
        precondition(skippedReport.text.contains("只清 A 后约"), "the conclusion does not depend on the walk")
        let skippedPositions = order(skippedReport.text)
        precondition(skippedPositions.allSatisfy { $0 >= 0 } && skippedPositions == skippedPositions.sorted())

        // ── 帮助文字与 v2 一致：clean 也会执行找不回的官方命令（DELETE 确认），只是没有清空废纸篓的命令
        for stale in ["只执行可恢复", "不提供永久删除"] {
            precondition(!cliHelp.contains(stale), "help still says \(stale)")
        }
        for wanted in ["MOVE", "DELETE", "--no-overview", "tier list", "tier set ID A|B|C", "不提供清空废纸篓的命令"] {
            precondition(cliHelp.contains(wanted), "help must mention \(wanted)")
        }
        // DELETE 列表与 docs/cli.md 一致：官方清理命令之外还有 docker builder prune、simctl、ollama rm
        for tool in ["npm", "go", "pip", "uv", "pnpm", "brew", "docker builder prune", "docker volume/image/container rm", "simctl", "ollama rm"] {
            precondition(cliHelp.contains(tool), "help DELETE list must mention \(tool)")
        }
        print("CLI workflow protection and durable recovery ok")
    }
}
