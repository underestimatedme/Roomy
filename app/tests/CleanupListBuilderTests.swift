// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func item(_ path: String, rule: String, size: UInt64, risk: Risk = .green, name: String? = nil,
                  mtimeDays: Int? = 120, evidence: String = "纯缓存，缺失时自动重建") -> ScanItem {
    ScanItem(name: name ?? (path as NSString).lastPathComponent, path: path, size: size, atimeDays: nil,
        mtimeDays: mtimeDays, rule: rule, evidence: evidence, risk: risk, gentle: nil, hard: "移到废纸篓",
        undo: true, note: "", rebuild: .free)
}

private final class ScriptedRunner: CommandRunning {
    var responses: [String: CommandResult] = [:]
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        responses[([executable] + arguments).joined(separator: " ")]
            ?? CommandResult(status: 1, stdout: "", stderr: "unexpected", timedOut: false)
    }
}

@main
struct CleanupListBuilderTests {
    static func main() {
        let worktreeItem = ScanItem.trashTarget(path: "/opt/coding/x/.worktrees/a", name: "w", size: 9_000,
            rule: "Git worktree", evidence: "e", risk: .green)
        let worktree = CleanupCandidate(source: "worktree", key: worktreeItem.path, title: "Worktree · a（x）",
            size: 9_000, evidence: "e", risk: .green,
            action: .worktreeRemove(item: worktreeItem, repo: "/opt/coding/x", branch: "b", base: "main"))
        let device = CleanupCandidate(source: "simulator", key: "u", title: "iPhone 模拟器", size: 5_000,
            evidence: "e", risk: .amber, action: .simctlDeleteDevice(udid: "u"))
        let hint = CleanupCandidate(source: "docker", key: "down", title: "Docker 未运行", size: 0,
            evidence: "e", risk: .amber, action: nil)

        let items = [
            item("/Users/me/Library/Caches/pip", rule: "包管理器缓存", size: 3_000),
            item("/Users/me/Library/Developer/CoreSimulator/Devices/U", rule: "iOS 模拟器设备", size: 4_000),
            item("/Users/me/.claude/settings.json", rule: "配置 · 记忆 · 登录态", size: 10, risk: .lock),
            item("/Users/me/.claude/CLAUDE.md", rule: "配置 · 记忆 · 登录态", size: 20, risk: .lock),
            item("/opt/coding/x/.worktrees/a/node_modules", rule: "node_modules", size: 2_000),
            item("/opt/coding/Valley/node_modules", rule: "node_modules", size: 1_000, mtimeDays: 0),
            item("/Users/me/Library/Developer/Xcode/DerivedData/Roomy-abc", rule: "Xcode DerivedData",
                 size: 500, name: "Roomy"),
        ]
        let list = CleanupListBuilder.build(items: items, probes: [worktree, device, hint, device])
        let titles = list.entries.map(\.title)
        // 测试里的 /Users/me 不是真实 HOME，所以 pip 显示完整路径
        precondition(titles == ["Worktree · a（x）", "iPhone 模拟器", "包管理器缓存 · /Users/me/Library/Caches/pip",
                                "node_modules · Valley", "Xcode DerivedData · Roomy",
                                "配置 · 记忆 · 登录态 · /Users/me/.claude/CLAUDE.md",
                                "配置 · 记忆 · 登录态 · /Users/me/.claude/settings.json", "Docker 未运行"], "\(titles)")
        precondition(!titles.contains { $0.contains("CoreSimulator") }, "tool-owned rule items are dropped")
        precondition(titles.filter { $0 == "iPhone 模拟器" }.count == 1, "duplicate ids are dropped")
        precondition(!list.entries.contains { $0.size == 2_000 }, "node_modules inside a listed worktree is not counted twice")
        // 不能删的条目已经在清单里列出，旧的"受保护的 N 项"计数不再重复统计它们
        precondition(list.protectedCount == 0 && list.protectedSize == 0, "locked rule items are listed, not counted again")
        precondition(list.entries.map(\.size) == list.entries.map(\.size).sorted(by: >), "sorted by size desc")
        precondition(list.candidate(id: device.entry.id) != nil && list.candidate(id: "nope") == nil)

        let pip = list.entries.first { $0.title.hasPrefix("包管理器缓存") }!
        precondition(pip.evidence == "纯缓存，缺失时自动重建 · 4 个月没动过", pip.evidence)
        precondition(!pip.defaultChecked && pip.tier == .review && pip.actionLabel == "进废纸篓")
        let valley = list.entries.first { $0.title == "node_modules · Valley" }!
        // node_modules 不在 Git 仓库里（没被忽略）：沿用内容核验结论，没通过 → 只能查看的 C，绝不默认勾选
        precondition(!valley.selectable && !valley.defaultChecked && valley.tier == .review && valley.actionLabel.isEmpty
            && valley.evidence.contains("待核实依赖重建"), "unverified project artifacts outside a repository are view-only: \(valley)")
        // 重建代价高的（会话、模型权重）只凭最外层目录时间不足以默认勾选
        let costly = ScanItem(name: "sessions", path: "/Users/me/.codex/sessions", size: 7, atimeDays: nil,
            mtimeDays: 120, rule: "Codex 会话", evidence: "最后活动时间", risk: .green, gentle: nil,
            hard: "移到废纸篓", undo: true, note: "", rebuild: .costly)
        let costlyEntry = CleanupListBuilder.fromRule(costly).entry
        precondition(!costlyEntry.defaultChecked && costlyEntry.risk == .amber && costlyEntry.selectable)
        // 应用残留探测到的目录如果已被规则覆盖（如 Caches/pip），不重复计算
        let leftoverItem = ScanItem.trashTarget(path: "/Users/me/Library/Caches/pip", name: "pip", size: 3_000,
            rule: "应用残留", evidence: "e", risk: .amber)
        let leftover = CleanupCandidate(source: "leftover", key: leftoverItem.path, title: "应用残留 · pip（Caches）",
            size: 3_000, evidence: "e", risk: .amber, action: .trash(item: leftoverItem))
        let withLeftover = CleanupListBuilder.build(items: items, probes: [leftover])
        precondition(!withLeftover.entries.contains { $0.source == "leftover" }, "\(withLeftover.entries.map(\.title))")
        // 项目缓存写项目名；旧版本写出新版本是哪个
        let projCache = CleanupListBuilder.fromRule(item("/opt/coding/x/Valley/.cache", rule: "项目缓存目录", size: 9))
        precondition(projCache.entry.title == "项目缓存目录 · Valley", projCache.entry.title)
        let jbDir = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-jb-\(UUID().uuidString)").path
        for d in ["GoLand2024.3", "GoLand2025.1"] {
            try? FileManager.default.createDirectory(atPath: jbDir + "/" + d, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(atPath: jbDir) }
        let old = CleanupListBuilder.fromRule(item(jbDir + "/GoLand2024.3", rule: "JetBrains 旧版本配置", size: 9,
                                                   evidence: "同一 IDE 已有更新的版本"))
        precondition(old.entry.evidence.hasPrefix("同一 IDE 已有更新的版本 · 新版本：GoLand2025.1"), old.entry.evidence)

        // risk == .lock 的规则条目进入清单，成为"不能删"：没有动作、不可选，不再计入旧的受保护计数
        let lockedList = CleanupListBuilder.build(items: [
            item("/Users/me/.claude/settings.json", rule: "配置 · 记忆 · 登录态", size: 10, risk: .lock, evidence: "登录态与设置，删了要重新登录"),
        ], probes: [])
        precondition(lockedList.protectedCount == 0 && lockedList.protectedSize == 0, "shown once, in 不能删")
        guard let lockedCandidate = lockedList.candidates.first, lockedList.candidates.count == 1 else {
            preconditionFailure("risk == .lock rule item must be listed: \(lockedList.entries.map(\.title))")
        }
        let lockedEntry = lockedCandidate.entry
        precondition(lockedEntry.tier == .locked && lockedEntry.lockReason == "登录态与设置，删了要重新登录", "\(lockedEntry.lockReason ?? "nil")")
        precondition(!lockedEntry.selectable && !lockedEntry.defaultChecked && lockedCandidate.action == nil)

        // 正在运行的所有者：命中规则的条目锁定并写明怎么解除；没命中不锁
        let derived = item("/Users/me/Library/Developer/Xcode/DerivedData/Roomy-abc", rule: "Xcode DerivedData", size: 500, name: "Roomy")
        let gradle = item("/Users/me/.gradle/caches", rule: "Gradle 缓存", size: 700)
        let wrapper = item("/Users/me/.gradle/wrapper/dists/gradle-7.0", rule: "Gradle 旧版本 wrapper", size: 300)
        let mcp = item("/Users/me/Library/Developer/XcodeBuildMCP/workspaces/w", rule: "XcodeBuildMCP 工作区", size: 200)
        let xcodeRunning = RunningOwners(commands: ["/Applications/Xcode.app/Contents/MacOS/Xcode", "/usr/sbin/cfprefsd agent"])
        let locks = CleanupListBuilder.build(items: [derived, mcp, gradle], probes: [], running: xcodeRunning)
        func entry(_ list: CleanupList, _ rule: String) -> CleanupEntry { list.entries.first { $0.group == rule }! }
        precondition(entry(locks, "Xcode DerivedData").tier == .locked
            && entry(locks, "Xcode DerivedData").lockReason == "Xcode 正在运行，关闭后重新扫描")
        precondition(entry(locks, "XcodeBuildMCP 工作区").lockReason == "Xcode 正在运行，关闭后重新扫描")
        precondition(entry(locks, "Gradle 缓存").tier != .locked, "Xcode does not hold the Gradle cache")
        precondition(locks.protectedCount == 0, "running-owner locks are not user-protected items")
        let gradleRunning = RunningOwners(commands: ["/usr/bin/java -cp x org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.5"])
        let gradleLocks = CleanupListBuilder.build(items: [gradle, wrapper, derived], probes: [], running: gradleRunning)
        let gradleReason = "Gradle 守护进程正在运行，执行 ./gradlew --stop 后重新扫描"
        precondition(entry(gradleLocks, "Gradle 缓存").lockReason == gradleReason)
        precondition(entry(gradleLocks, "Gradle 旧版本 wrapper").lockReason == gradleReason)
        precondition(entry(gradleLocks, "Xcode DerivedData").tier != .locked)
        let idle = CleanupListBuilder.build(items: [derived, gradle], probes: [], running: RunningOwners(commands: []))
        precondition(!idle.entries.contains { $0.tier == .locked }, "no matching process, no lock")
        let unchecked = CleanupListBuilder.build(items: [derived, gradle], probes: [])
        precondition(!unchecked.entries.contains { $0.tier == .locked }, "running == nil means not checked")
        // 无法读取进程列表（capture 返回 nil）：相关条目降为 C 并写明原因，不相关的不动
        let downgraded = RunningOwners.markUnverified(unchecked)
        precondition(entry(downgraded, "Xcode DerivedData").tier == .review
            && entry(downgraded, "Xcode DerivedData").evidence.contains("无法检查运行状态"))
        precondition(entry(downgraded, "Gradle 缓存").tier == .review)
        let pipList = RunningOwners.markUnverified(CleanupListBuilder.build(items: [items[0]], probes: []))
        precondition(!pipList.entries[0].evidence.contains("无法检查运行状态"))

        // capture：ps -axo command=；失败返回 nil
        let psTools = ToolLocator(searchDirectories: [], isExecutable: { _ in true })
        let ps = ScriptedRunner()
        ps.responses["/bin/ps -axo command="] = CommandResult(status: 0, stdout: "/sbin/launchd\n/Applications/Xcode.app/Contents/MacOS/Xcode\n", stderr: "", timedOut: false)
        let captured = RunningOwners.capture(runner: ps, tools: psTools)
        precondition(captured?.commands == ["/sbin/launchd", "/Applications/Xcode.app/Contents/MacOS/Xcode"], "\(String(describing: captured?.commands))")
        precondition(captured?.blocker(forRule: "Xcode DerivedData") == "Xcode 正在运行，关闭后重新扫描")
        precondition(captured?.blocker(forRule: "pip") == nil)
        precondition(RunningOwners.capture(runner: ScriptedRunner(), tools: psTools) == nil, "ps failure yields nil")
        let emptyPs = ScriptedRunner()
        emptyPs.responses["/bin/ps -axo command="] = CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
        precondition(RunningOwners.capture(runner: emptyPs, tools: psTools) == nil, "an empty process list is not trust")
        precondition(RunningOwners.capture(runner: ps, tools: ToolLocator(searchDirectories: [], isExecutable: { _ in false })) == nil)
        // go run 的开发服务器已经跑起编译出的程序：Go 缓存不再因它锁定；还没跑起来、核实不了、或另有 go build 时照旧锁定
        let goRun = ScriptedRunner()
        goRun.responses["/bin/ps -axo command="] = CommandResult(status: 0, stdout: "/opt/homebrew/bin/go run ./cmd/server\n/private/var/folders/x/T/go-build123/b001/exe/server\n", stderr: "", timedOut: false)
        goRun.responses["/bin/ps -axo pid=,ppid=,command="] = CommandResult(status: 0, stdout: "200 1 /opt/homebrew/bin/go run ./cmd/server\n201 200 /private/var/folders/x/T/go-build123/b001/exe/server\n", stderr: "", timedOut: false)
        let serving = RunningOwners.capture(runner: goRun, tools: psTools)
        precondition(serving?.goRunsLaunched == true && serving?.blocker(forTool: .goBuildCache) == nil && serving?.blocker(forTool: .goModCache) == nil)
        goRun.responses["/bin/ps -axo pid=,ppid=,command="] = CommandResult(status: 0, stdout: "200 1 /opt/homebrew/bin/go run ./cmd/server\n202 200 /opt/homebrew/Cellar/go/1.27/libexec/pkg/tool/darwin_arm64/compile -o x\n", stderr: "", timedOut: false)
        precondition(RunningOwners.capture(runner: goRun, tools: psTools)?.blocker(forTool: .goBuildCache) == "go 正在运行，结束后重新扫描", "go run still compiling")
        goRun.responses["/bin/ps -axo pid=,ppid=,command="] = nil
        precondition(RunningOwners.capture(runner: goRun, tools: psTools)?.blocker(forTool: .goBuildCache) != nil, "unverifiable go run stays locked")
        precondition(RunningOwners(commands: ["go run ./cmd/server"]).blocker(forTool: .goBuildCache) != nil, "unchecked go run stays locked")
        precondition(RunningOwners(commands: ["go run ./cmd/server", "go build ./..."], goRunsLaunched: true).blocker(forTool: .goBuildCache) != nil)
        let xcodebuild = RunningOwners(commands: ["/usr/bin/xcodebuild -scheme Roomy build"])
        precondition(xcodebuild.blocker(forRule: "Xcode DerivedData") == "Xcode 正在运行，关闭后重新扫描")

        // 发现阶段给锁定的 worktree 记了占位大小：组装时要换成真实值，不能泄漏出去
        var pending = CleanupCandidate(source: "worktree", key: "/w/a", title: "Worktree · a", size: ToolProbes.placeholder,
            evidence: "e", risk: .amber, action: nil).locked("有未提交的改动或无法完整检查")
        pending.entry.path = "/w/a"
        let index = SizeIndex(targets: ["/w/a": 4_242], dirs: [:])
        let resized = ToolProbes.sized([pending], sizePaths: ["/w/a"], index: index)
        precondition(resized.count == 1 && resized[0].entry.size == 4_242 && resized[0].entry.tier == .locked,
            "\(resized.map(\.entry.size))")
        print("CleanupListBuilderTests passed")
    }
}
