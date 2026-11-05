// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private final class Processes: CommandRunning {
    var ps = CommandResult(status: 0, stdout: "/sbin/launchd\n", stderr: "", timedOut: false)
    var mdfind = CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        if executable == "/bin/ps" { precondition(arguments == ["-axo", "comm="]); return ps }
        if executable == "/usr/bin/mdfind" { return mdfind }
        preconditionFailure("unexpected command \(executable)")
    }
}

@main struct InstalledAppDataProbeTests {
    static func main() throws {
        let fm = FileManager.default, temporary = fm.temporaryDirectory.path
        let root = (temporary.hasPrefix("/var/") ? "/private" + temporary : temporary) + "/roomy-appdata-\(UUID())"
        defer { try? fm.removeItem(atPath: root) }
        let home = root + "/Home", installs = root + "/Applications", library = home + "/Library"
        func file(_ path: String, _ bytes: Data = Data(count: 2_000)) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        func app(_ name: String, _ id: String, dataDir: String? = nil) throws -> String {
            let path = installs + "/" + name + ".app"
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try file(path + "/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
            if let dataDir {
                try file(path + "/Contents/Resources/product-info.json", JSONSerialization.data(withJSONObject: ["dataDirectoryName": dataDir]))
            }
            return path
        }
        let wechat = try app("WeChat", "com.tencent.xinWeChat")
        _ = try app("Claude", "com.anthropic.claudefordesktop")
        _ = try app("Malus", "com.getmalus.malus")
        let chatgpt = try app("ChatGPT", "com.openai.codex")                   // 缓存目录叫 Codex：靠别名对上
        let idea = try app("IntelliJ IDEA CE", "com.jetbrains.intellij.ce", dataDir: "IdeaIC2024.3")
        _ = try app("Safari", "com.apple.Safari")
        _ = try app("Microsoft Edge", "com.microsoft.edgemac")

        try file(library + "/Caches/com.tencent.xinWeChat/Cache.db")
        try file(library + "/Caches/com.tencent.xinWeChat/org.sparkle-project.Sparkle/Installation/update.zip")
        try file(library + "/Caches/com.anthropic.claudefordesktop.ShipIt/update.x/Claude.zip")
        try file(library + "/Caches/Codex/Default/data")                       // 别名 → com.openai.codex
        try file(library + "/Caches/JetBrains/IdeaIC2024.3/index/x")
        try file(library + "/Caches/Google/AndroidStudio2024.3.2/x")
        try file(library + "/Logs/JetBrains/IdeaIC2024.3/idea.log")
        try file(library + "/Logs/Google/AndroidStudio2024.3.2/idea.log")
        try file(library + "/Logs/com.getmalus.malus/run.log")
        try file(library + "/Logs/Claude/main.log")
        try file(library + "/Caches/com.apple.Safari/x")                      // Apple 自带：不碰
        try file(library + "/Caches/com.microsoft.edgemac/Default/Cache/x")   // ApplicationCacheProbe 管：不重复
        try file(library + "/Caches/com.gone.app/x")                          // 对不上已装应用：归卸载残留
        try file(library + "/Caches/com.atlaspaces.roomy/x")                  // 自己

        let runner = Processes(), tools = ToolLocator(isExecutable: { ["/bin/ps", "/usr/bin/mdfind"].contains($0) })
        func probe() -> [String: CleanupCandidate] {
            let found = InstalledAppDataProbe.probe(home: home, catalogRoots: [installs], runner: runner, tools: tools, sizeOf: { _ in 5_000_000 })
            return Dictionary(found.map { ($0.entry.path!.replacingOccurrences(of: library + "/", with: ""), $0) }, uniquingKeysWith: { a, _ in a })
        }
        var rows = probe()
        precondition(Set(rows.keys) == ["Caches/com.tencent.xinWeChat", "Caches/com.tencent.xinWeChat/org.sparkle-project.Sparkle",
            "Caches/com.anthropic.claudefordesktop.ShipIt", "Caches/Codex", "Caches/JetBrains/IdeaIC2024.3", "Logs/JetBrains/IdeaIC2024.3",
            "Caches/Google/AndroidStudio2024.3.2", "Logs/Google/AndroidStudio2024.3.2", "Logs/com.getmalus.malus", "Logs/Claude"], "\(rows.keys.sorted())")
        for row in rows.values {
            precondition(row.entry.source == "appdata" && row.entry.reversible && row.entry.selectable, row.entry.title)
            guard case .trash(let item)? = row.action else { preconditionFailure("app data goes to the Trash") }
            precondition(item.rule != "应用可重建缓存", "background automation must not pick these up")
        }
        // 更新包和卸载后的 Android Studio：A；应用缓存、日志、当前 IDE：B 不默认勾选
        for key in ["Caches/com.tencent.xinWeChat/org.sparkle-project.Sparkle", "Caches/com.anthropic.claudefordesktop.ShipIt",
                    "Caches/Google/AndroidStudio2024.3.2", "Logs/Google/AndroidStudio2024.3.2"] {
            precondition(rows[key]!.entry.tier == .obsolete && rows[key]!.entry.defaultChecked, key)
        }
        for key in ["Caches/com.tencent.xinWeChat", "Caches/Codex", "Caches/JetBrains/IdeaIC2024.3", "Logs/JetBrains/IdeaIC2024.3",
                    "Logs/com.getmalus.malus", "Logs/Claude"] {
            precondition(rows[key]!.entry.tier == .rebuildable && !rows[key]!.entry.defaultChecked, key)
        }

        // 标题带上和应用名不同的目录名，同名应用分得清
        precondition(rows["Caches/com.tencent.xinWeChat"]!.entry.title == "WeChat · 缓存（com.tencent.xinWeChat）")
        precondition(rows["Caches/Codex"]!.entry.title == "ChatGPT · 缓存（Codex）" && rows["Logs/Claude"]!.entry.title == "Claude · 日志")
        // 别名指向的应用没装：Codex 目录不归已装应用，留给卸载残留去判断
        try fm.removeItem(atPath: chatgpt)
        precondition(probe()["Caches/Codex"] == nil, "an alias only counts when its app is installed")
        _ = try app("ChatGPT", "com.openai.codex")

        // 应用在运行：它的缓存、更新包、IDE 目录都锁定；别的应用不受影响
        runner.ps = CommandResult(status: 0, stdout: "\(wechat)/Contents/MacOS/WeChat\n\(idea)/Contents/MacOS/idea\n", stderr: "", timedOut: false)
        rows = probe()
        for key in ["Caches/com.tencent.xinWeChat", "Caches/com.tencent.xinWeChat/org.sparkle-project.Sparkle",
                    "Caches/JetBrains/IdeaIC2024.3", "Logs/JetBrains/IdeaIC2024.3"] {
            precondition(rows[key]!.entry.tier == .locked && !rows[key]!.entry.selectable && rows[key]!.action == nil, key)
        }
        precondition(rows["Logs/Claude"]!.entry.selectable)
        // 更新程序（ShipIt）正在安装：更新包锁定
        runner.ps = CommandResult(status: 0, stdout: "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt\n", stderr: "", timedOut: false)
        rows = probe()
        precondition(rows["Caches/com.anthropic.claudefordesktop.ShipIt"]!.entry.lockReason == InstalledAppDataProbe.updatingReason)
        runner.ps = CommandResult(status: 0, stdout: "/sbin/launchd\n", stderr: "", timedOut: false)

        // Spotlight 还能找到 Android Studio（装在别处）或查不了：不当卸载残留，只列不勾
        runner.mdfind = CommandResult(status: 0, stdout: "/opt/Android Studio.app\n", stderr: "", timedOut: false)
        precondition(probe()["Caches/Google/AndroidStudio2024.3.2"]!.entry.tier == .review)
        runner.mdfind = CommandResult(status: 1, stdout: "", stderr: "", timedOut: false)
        precondition(probe()["Caches/Google/AndroidStudio2024.3.2"]!.entry.tier == .review)
        // 装着另一个版本的 Android Studio：当前版本 B，其他版本 C
        runner.mdfind = CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
        _ = try app("Android Studio", InstalledAppDataProbe.androidStudioID, dataDir: "AndroidStudio2025.1")
        try file(library + "/Caches/Google/AndroidStudio2025.1/x")
        rows = probe()
        precondition(rows["Caches/Google/AndroidStudio2025.1"]!.entry.tier == .rebuildable)
        precondition(rows["Caches/Google/AndroidStudio2024.3.2"]!.entry.tier == .review)

        // 读不到进程列表：整组不列
        runner.ps = CommandResult(status: 1, stdout: "", stderr: "", timedOut: false)
        precondition(probe().isEmpty, "unknown running state lists nothing")
        runner.ps = CommandResult(status: 0, stdout: "/sbin/launchd\n", stderr: "", timedOut: false)

        // 执行前复核：还在且可选才放行；应用开起来了就拦下
        var env = CleanupEnvironment()
        env.runner = runner; env.tools = tools; env.roots = [home]; env.applicationRoots = [installs]
        precondition(InstalledAppDataProbe.executionBlocker(path: library + "/Logs/Claude", environment: env) == nil)
        runner.ps = CommandResult(status: 0, stdout: "\(wechat)/Contents/MacOS/WeChat\n", stderr: "", timedOut: false)
        precondition(InstalledAppDataProbe.executionBlocker(path: library + "/Caches/com.tencent.xinWeChat", environment: env) == ApplicationCatalog.runningBlockReason)
        precondition(InstalledAppDataProbe.executionBlocker(path: library + "/Caches/com.gone.app", environment: env) != nil)
        precondition(InstalledAppDataProbe.executionBlocker(path: "/tmp/elsewhere", environment: env) != nil)

        print("InstalledAppDataProbeTests passed")
    }
}
