// SPDX-License-Identifier: MPL-2.0
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
struct CleanupRunnerTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-run-\(UUID().uuidString)").resolvingSymlinksInPath().path
        defer { try? fm.removeItem(atPath: root) }
        let cache = root + "/proj/cache"
        let changed = root + "/proj/changed.bin"
        let outside = fm.temporaryDirectory.appendingPathComponent("roomy-outside-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: cache, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: outside) }
        try Data("v1".utf8).write(to: URL(fileURLWithPath: changed))

        func trashCandidate(_ path: String) -> CleanupCandidate {
            let item = ScanItem.trashTarget(path: path, name: "n", size: 100, rule: "r", evidence: "e", risk: .green)
            return CleanupCandidate(source: "rule", key: path, title: path, size: 100, evidence: "e",
                risk: .green, action: .trash(item: item))
        }
        let cacheC = trashCandidate(cache)
        let changedC = trashCandidate(changed)
        let outsideC = trashCandidate(outside + "/x")
        try Data("v2-longer".utf8).write(to: URL(fileURLWithPath: changed))   // 扫描后被改写

        let booted = "A86E8B12-7CF0-4A69-B453-6DC989371771", idle = "11111111-2222-3333-4444-555555555555"
        let bootedC = CleanupCandidate(source: "simulator", key: booted, title: "b", size: 10, evidence: "e",
            risk: .amber, action: .simctlDeleteDevice(udid: booted))
        let idleC = CleanupCandidate(source: "simulator", key: idle, title: "i", size: 20, evidence: "e",
            risk: .amber, action: .simctlDeleteDevice(udid: idle))
        let badModel = CleanupCandidate(source: "ollama", key: "-rf", title: "bad", size: 1, evidence: "e",
            risk: .amber, action: .ollamaRemove(model: "-rf"))
        let model = CleanupCandidate(source: "ollama", key: "llama3.1:70b", title: "m", size: 30, evidence: "e",
            risk: .amber, action: .ollamaRemove(model: "llama3.1:70b"))
        let docker = CleanupCandidate(source: "docker", key: "volume:v1", title: "d", size: 40, evidence: "e",
            risk: .amber, action: .dockerRemove(kind: .volume, id: "v1"))
        let hint = CleanupCandidate(source: "docker", key: "down", title: "h", size: 0, evidence: "e",
            risk: .amber, action: nil)

        var list = CleanupList()
        list.candidates = [cacheC, changedC, outsideC, bootedC, idleC, badModel, model, docker, hint]

        let runner = FakeRunner()
        let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"\(booted)","name":"A","state":"Booted"},{"udid":"\(idle)","name":"B","state":"Shutdown"}]}}
        """
        runner.responses["/usr/bin/xcrun simctl list -j devices"] = ok(devices)
        runner.responses["/usr/bin/xcrun simctl delete \(idle)"] = ok()
        runner.responses["/fake/ollama list"] = ok("NAME  ID  SIZE  MODIFIED\nllama3.1:70b  abc  39 GB  3 months ago\n")
        runner.responses["/fake/ollama rm llama3.1:70b"] = ok()
        runner.responses["/fake/docker info --format {{.ServerVersion}}"] = ok("27.0")
        runner.responses["/fake/docker context inspect --format {{.Endpoints.docker.Host}}"] = ok("unix:///var/run/docker.sock")
        runner.responses["/fake/docker volume inspect --format {{.Name}} v1"] = ok("v1\n")
        runner.responses["/fake/docker ps -a --filter volume=v1 -q"] = ok("")
        runner.responses["/fake/docker volume rm v1"] = ok("v1\n")

        var trashed: [String] = []
        var logged: [[String: Any]] = []
        var free: [UInt64] = [1_000, 6_000]
        var env = CleanupEnvironment()
        env.runner = runner
        env.tools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { _ in true }, dockerHost: nil)
        env.roots = [root]
        env.trash = { trashed.append($0); return "/Trash/" + ($0 as NSString).lastPathComponent }
        env.log = { logged.append($0) }
        env.diskFree = { free.removeFirst() }

        var progressed: [String] = []
        let ids = [cacheC, changedC, outsideC, bootedC, idleC, badModel, model, docker, hint].map(\.entry.id) + ["unknown"]
        let summary = CleanupRunner.run(ids: ids, list: list, env: env) { progressed.append($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: summary.outcomes.map { ($0.id, $0) })

        precondition(byID[cacheC.entry.id]!.ok && trashed == [cache], "\(trashed)")
        precondition(!byID[changedC.entry.id]!.ok && byID[changedC.entry.id]!.message.contains("重新扫描"))
        precondition(!byID[outsideC.entry.id]!.ok && byID[outsideC.entry.id]!.message == "不在允许清理的目录里")
        precondition(byID[bootedC.entry.id]!.message == "这台模拟器正在运行，先关掉它")
        precondition(!runner.calls.contains("/usr/bin/xcrun simctl delete \(booted)"), "booted device is never deleted")
        precondition(byID[idleC.entry.id]!.ok && byID[idleC.entry.id]!.bytes == 20)
        precondition(!byID[badModel.entry.id]!.ok && !runner.calls.contains { $0.contains(" rm -rf") })
        precondition(byID[model.entry.id]!.ok)
        precondition(byID[docker.entry.id]!.ok && byID[docker.entry.id]!.bytes == 40, "docker objects report the previewed size")
        precondition(runner.calls.contains("/fake/docker volume rm v1") && !runner.calls.contains { $0.contains("system prune") })
        precondition(!byID[hint.entry.id]!.ok && !byID["unknown"]!.ok)
        precondition(summary.outcomes.count == ids.count && progressed == ids, "every id reported in order")
        precondition(summary.freedBytes == 5_000, "freed is the measured disk delta")
        precondition(summary.trashedBytes == 100, "only the trashed item counts as trashed: \(summary.trashedBytes)")
        precondition(logged.count == ids.count && logged.allSatisfy { $0["id"] != nil && $0["action"] != nil })

        // 命令失败：退出码和 stderr 写进消息
        let failing = FakeRunner()
        failing.responses["/usr/bin/xcrun simctl list -j devices"] = ok(devices)
        failing.responses["/usr/bin/xcrun simctl delete \(idle)"] =
            CommandResult(status: 2, stdout: "", stderr: "Unable to delete", timedOut: false)
        env.runner = failing
        free = [0, 0]
        var one = CleanupList(); one.candidates = [idleC]
        let failed = CleanupRunner.run(ids: [idleC.entry.id], list: one, env: env) { _ in }
        precondition(!failed.outcomes[0].ok && failed.outcomes[0].message.contains("退出码 2")
            && failed.outcomes[0].message.contains("Unable to delete"), failed.outcomes[0].message)
        // worktree：真实 git。目录"进废纸篓"（这里用改名模拟），worktree 记录被 prune，分支保留
        let gitRoot = root + "/code"
        let repo = gitRoot + "/proj/repo", wt = gitRoot + "/proj/.worktrees/done"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func git(_ args: [String], _ dir: String) -> CommandResult {
            ProcessRunner().run("/usr/bin/git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t",
                "-c", "commit.gpgsign=false"] + args, timeout: 20)
        }
        precondition(git(["init", "-q", "-b", "main"], repo).ok)
        precondition(git(["commit", "-q", "--allow-empty", "-m", "init"], repo).ok)
        precondition(git(["worktree", "add", "-q", "-b", "codex/done", wt], repo).ok)
        let realGitRoot = realpath(gitRoot, nil).map { p in defer { Darwin.free(p) }; return String(cString: p) }!
        let found = WorktreeProbe.probe(roots: [realGitRoot], runner: ProcessRunner(), tools: ToolLocator(),
            now: Date().addingTimeInterval(30 * 86_400), sizeOf: { _ in 1 })
        precondition(found.count == 1, "\(found.map(\.entry.title))")
        // 扫描后、执行前出现了新文件 → 执行时跳过，目录原封不动
        try "late".write(toFile: wt + "/late.txt", atomically: true, encoding: .utf8)
        var lateEnv = CleanupEnvironment(); lateEnv.roots = [realGitRoot]; lateEnv.diskFree = { 0 }
        lateEnv.trash = { _ in preconditionFailure("must not trash a worktree that changed after the scan") }
        var lateList = CleanupList(); lateList.candidates = found
        let late = CleanupRunner.run(ids: [found[0].entry.id], list: lateList, env: lateEnv) { _ in }
        precondition(!late.outcomes[0].ok && late.outcomes[0].message == "这个 worktree 有未提交的改动", late.outcomes[0].message)
        try fm.removeItem(atPath: wt + "/late.txt")
        // 目录内容变过，身份已不同：按真实流程重新扫描一次再执行
        let rescanned = WorktreeProbe.probe(roots: [realGitRoot], runner: ProcessRunner(), tools: ToolLocator(),
            now: Date().addingTimeInterval(30 * 86_400), sizeOf: { _ in 1 })
        precondition(rescanned.count == 1)
        var wtList = CleanupList(); wtList.candidates = rescanned
        var gitEnv = CleanupEnvironment()
        gitEnv.roots = [realGitRoot]
        gitEnv.diskFree = { 0 }
        let trashDir = root + "/Trash"
        try fm.createDirectory(atPath: trashDir, withIntermediateDirectories: true)
        gitEnv.trash = { path in
            let dest = trashDir + "/" + (path as NSString).lastPathComponent
            try fm.moveItem(atPath: path, toPath: dest)
            return dest
        }
        var gitLog: [[String: Any]] = []
        gitEnv.log = { gitLog.append($0) }
        let removed = CleanupRunner.run(ids: [rescanned[0].entry.id], list: wtList, env: gitEnv) { _ in }
        precondition(removed.outcomes[0].ok, removed.outcomes[0].message)
        precondition(fm.fileExists(atPath: trashDir + "/done") && !fm.fileExists(atPath: wt))
        precondition(gitLog.first?["trashedTo"] as? String == trashDir + "/done", "trash location is logged: \(gitLog)")
        precondition(git(["rev-parse", "--verify", "--quiet", "refs/heads/codex/done"], repo).ok, "branch kept")
        // 不做 prune：从废纸篓放回原处，worktree 立即恢复可用
        try fm.moveItem(atPath: trashDir + "/done", toPath: wt)
        precondition(git(["status", "--porcelain"], wt).ok, "restored worktree works again")
        precondition(git(["worktree", "list"], repo).stdout.contains(".worktrees/done"))
        print("CleanupRunnerTests passed")
    }
}
