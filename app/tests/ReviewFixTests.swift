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
private func ok(_ t: String) -> CommandResult { CommandResult(status: 0, stdout: t, stderr: "", timedOut: false) }

@main
struct ReviewFixTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-fix2-\(UUID().uuidString)").path
        defer { _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp + "/.Trash/locked"); try? fm.removeItem(atPath: tmp) }
        func dir(_ p: String) throws { try fm.createDirectory(atPath: tmp + "/" + p, withIntermediateDirectories: true) }
        func age(_ p: String, days: Double) throws {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: tmp + "/" + p)
        }

        // I1：最外层目录很旧，但第 3 层里两周内还有新模块 → 按最近的活动算
        try dir("mod/github.com/yuin/gopher-lua@v1.1.1"); try dir("mod/golang.org/x/text@v0.3.0")
        for p in ["mod/golang.org/x/text@v0.3.0", "mod/golang.org/x", "mod/golang.org", "mod/github.com/yuin", "mod/github.com", "mod"] {
            try age(p, days: 107)
        }
        try age("mod/github.com/yuin/gopher-lua@v1.1.1", days: 3)
        try age("mod/github.com/yuin", days: 107); try age("mod/github.com", days: 107); try age("mod", days: 107)
        precondition(newestActivityDays(tmp + "/mod") == 3, "\(String(describing: newestActivityDays(tmp + "/mod")))")

        // M6：.venv* 必须真的是虚拟环境
        try dir("code/p1/.venv312"); FileManager.default.createFile(atPath: tmp + "/code/p1/.venv312/pyvenv.cfg", contents: Data())
        try dir("code/p2/.venv-notes")
        precondition(expandPaths(["<codescan:.venv*@has:pyvenv.cfg>"], codeRoots: [tmp + "/code"]) == [tmp + "/code/p1/.venv312"])
        precondition(RULES.first { $0.name == "Python 虚拟环境" }!.paths == ["<codescan:.venv*@has:pyvenv.cfg>"])
        // M1 / M9
        precondition(!RULES.first { $0.name == "Playwright 旧版本浏览器" }!.precheck, "live installs may still use old revisions")
        precondition(RULES.first { $0.name == "自动更新残留" }!.rebuild == .cheap && RULES.first { $0.name == "安装临时目录" }!.rebuild == .cheap)

        // I5：被后台服务用着的目录不默认勾选
        let venv = ScanItem.trashTarget(path: "/opt/coding/KnowHub/.venv", name: ".venv", size: 9, rule: "Python 虚拟环境",
                                        evidence: "e", risk: .green)
        let venvC = CleanupCandidate(source: "rule", key: venv.path, title: "Python 虚拟环境 · KnowHub", size: 9,
                                     evidence: "所在项目最后修改时间", risk: .green, action: .trash(item: venv))
        let list = CleanupListBuilder.build(items: [], probes: [venvC],
                                            agentPaths: [("com.kp.sync", "/opt/coding/KnowHub/.venv/bin/python")])
        precondition(!list.entries[0].defaultChecked && list.entries[0].risk == .amber, "used by a launch agent")
        precondition(list.entries[0].evidence.hasPrefix("被后台服务 com.kp.sync 使用 · "), list.entries[0].evidence)
        precondition(list.entries[0].id == venvC.entry.id && list.entries[0].selectable)

        // I3：启动程序的判断——只有 ENOENT 才算不存在；/Volumes 下的不判断
        let agents = tmp + "/LaunchAgents"
        try dir("LaunchAgents")
        func agent(_ label: String, _ program: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [program]],
                                                          format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: agents + "/\(label).plist"))
        }
        try dir("private-dir/bin"); FileManager.default.createFile(atPath: tmp + "/private-dir/bin/tool", contents: Data())
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: tmp + "/private-dir")
        defer { _ = try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp + "/private-dir") }
        try agent("com.eperm.tool", tmp + "/private-dir/bin/tool")
        try agent("com.ext.disk", "/Volumes/External/app/helper")
        try agent("com.gone.helper", tmp + "/Gone.app/helper")
        let dead = AppLeftoverProbe.launchAgentCandidates(directory: agents)
        precondition(dead.map(\.entry.title) == ["后台服务残留 · com.gone.helper"], "\(dead.map(\.entry.title))")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp + "/private-dir")

        // I3：bootout 只停"确实由这个 plist 加载"的服务；同名服务来自别处时只移走 plist
        let gone = dead[0]
        guard case .launchAgentRemove(_, let plistItem) = gone.action else { preconditionFailure("action") }
        let tools = ToolLocator(searchDirectories: [], isExecutable: { _ in true })
        var env = CleanupEnvironment(); env.tools = tools; env.roots = [tmp]; env.diskFree = { 0 }
        var trashed: [String] = []
        env.trash = { trashed.append($0); return nil }
        var one = CleanupList(); one.candidates = [gone]
        let target = "gui/\(getuid())/com.gone.helper"
        let elsewhere = FakeRunner()
        elsewhere.responses["/bin/launchctl print \(target)"] = ok("\(target) = {\n\tpath = /Applications/New.app/Contents/Library/LaunchAgents/com.gone.helper.plist\n}")
        env.runner = elsewhere
        precondition(CleanupRunner.run(ids: [gone.entry.id], list: one, env: env) { _ in }.outcomes[0].ok)
        precondition(!elsewhere.calls.contains { $0.contains("bootout") } && trashed == [plistItem.path], "\(elsewhere.calls)")
        let mine = FakeRunner()
        mine.responses["/bin/launchctl print \(target)"] = ok("\(target) = {\n\tpath = \(plistItem.path)\n}")
        mine.responses["/bin/launchctl bootout \(target)"] = ok("")
        env.runner = mine; trashed = []
        precondition(CleanupRunner.run(ids: [gone.entry.id], list: one, env: env) { _ in }.outcomes[0].ok)
        precondition(mine.calls.contains("/bin/launchctl bootout \(target)") && trashed == [plistItem.path])

        // I4：名字对不上，但子目录名是已安装应用 → 不是残留
        try dir("Applications/Navicat Premium.app/Contents")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.prect.NavicatPremium15",
            "CFBundleName": "Navicat Premium"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: tmp + "/Applications/Navicat Premium.app/Contents/Info.plist"))
        let sw = AppLeftoverProbe.InstalledSoftware.collect(appPaths: [tmp + "/Applications/Navicat Premium.app"],
                                                           processes: [], commandNames: [])
        try dir("Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium")
        try dir("Library/Application Support/OldThing/Cache")
        for p in ["Library/Application Support/PremiumSoft CyberTech/Navicat CC/Navicat Premium",
                  "Library/Application Support/PremiumSoft CyberTech/Navicat CC", "Library/Application Support/PremiumSoft CyberTech",
                  "Library/Application Support/OldThing/Cache", "Library/Application Support/OldThing"] { try age(p, days: 200) }
        let leftovers = AppLeftoverProbe.candidates(library: tmp + "/Library", software: sw, now: Date(), minBytes: 0,
                                                    sizeOf: { _ in 5_000_000 })
        precondition(leftovers.map(\.entry.title) == ["应用残留 · OldThing"], "\(leftovers.map(\.entry.title))")

        // M2：读不到（EPERM）不等于不存在，账本不能忘掉
        let trash = tmp + "/.Trash"
        try dir(".Trash/locked/item")
        let ledger = TrashLedger(url: URL(fileURLWithPath: tmp + "/ledger.json"), trashRoots: [trash])
        ledger.record([TrashedItem(path: trash + "/locked/item", bytes: 1, title: "item")])
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: trash + "/locked")
        precondition(ledger.pending().isEmpty)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash + "/locked")
        precondition(ledger.pending().map(\.title) == ["item"], "an unreadable item must not be forgotten")

        // M4：统计大目录时跳过受隐私保护的目录
        try dir("home/Library/Containers/com.tencent.xinWeChat"); try dir("home/Documents"); try dir("home/code")
        FileManager.default.createFile(atPath: tmp + "/home/Documents/a.bin", contents: Data(count: 4096))
        FileManager.default.createFile(atPath: tmp + "/home/code/b.bin", contents: Data(count: 4096))
        let map = UnexplainedSpace.sizeMap(roots: [tmp + "/home"], threshold: 1, home: tmp + "/home")
        precondition(map[tmp + "/home/code"] != nil && map[tmp + "/home/Documents"] == nil
                     && map[tmp + "/home/Library/Containers"] == nil, "\(map.keys.sorted())")

        // M5：过期批次的结果不进清单
        let session = ScanGenerations()
        let g1 = session.begin(), g2 = session.begin()
        precondition(!session.isCurrent(g1) && session.isCurrent(g2))
        print("ReviewFixTests passed")
    }
}
