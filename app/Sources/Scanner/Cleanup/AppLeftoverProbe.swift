// SPDX-License-Identifier: MPL-2.0
// 已卸载应用留下的数据。"装没装"问 Spotlight（全盘所有 .app）、正在运行的进程和命令行工具；
// 名字对不上不等于卸载了（中文目录名、厂商目录、命令行工具），所以只列很久没动过的，永远不默认勾选。
// 不扫 Containers / Group Containers：新版 macOS 读它们会弹"访问其他应用的数据"，且多属仍安装的沙盒应用。

import Darwin
import Foundation

enum AppLeftoverProbe {
    struct InstalledSoftware {
        var bundleIDs: Set<String> = []   // 小写
        var names: Set<String> = []       // normalize 之后

        static func collect(appPaths: [String], processes: [String], commandNames: [String]) -> InstalledSoftware {
            var sw = InstalledSoftware()
            for app in appPaths {
                sw.names.insert(normalize(((app as NSString).lastPathComponent as NSString).deletingPathExtension))
                guard let data = FileManager.default.contents(atPath: app + "/Contents/Info.plist"),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }
                if let id = plist["CFBundleIdentifier"] as? String { sw.bundleIDs.insert(id.lowercased()) }
                for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                    if let name = plist[key] as? String { sw.names.insert(normalize(name)) }
                }
            }
            for p in processes { sw.names.insert(normalize((p as NSString).lastPathComponent)) }
            for c in commandNames { sw.names.insert(normalize(c)) }
            sw.names.remove("")
            return sw
        }
    }

    static let locations = ["Application Support", "Caches", "HTTPStorages", "WebKit", "Saved Application State", "Logs"]

    /// 系统共享目录、厂商目录（下面挂好几个应用）、Roomy 自己
    private static let shared: Set<String> = [
        "caches", "crashreporter", "addressbook", "mobilesync", "clouddocs", "icloud", "knowledge", "callhistorydb",
        "callhistorytransactions", "dock", "familycircle", "fileprovider", "syncservices", "networkserviceproxy",
        "animoji", "accounts", "containermanager", "cloudkit", "homekit", "identityservices", "quicklook",
        "sirianalytics", "spotlight", "dmd", "appstore", "gamekit", "storeassetd", "locationaccessstored", "cef",
        "roomy", "google", "microsoft", "adobe", "jetbrains", "apple", "mozilla", "com", "org", "tmp", "logs",
    ]

    private static let genericVendors: Set<String> = ["com.electron", "com.github", "org.chromium", "com.google.chrome"]

    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || (0x4E00...0x9FFF).contains($0.value)
        }.map(Character.init))
    }

    static func isBundleIDShaped(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty } && parts[0].allSatisfy { $0.isLetter }
    }

    /// true = 有对应的已安装软件（或拿不准），不算残留
    static func matches(_ folder: String, _ sw: InstalledSoftware) -> Bool {
        let name = folder.hasSuffix(".savedState") ? String(folder.dropLast(".savedState".count)) : folder
        let lower = name.lowercased()
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") { return true }
        let key = normalize(name)
        if !isBundleIDShaped(name), key.isEmpty || shared.contains(key) { return true }
        return softwareMatches(name, sw)
    }

    /// 只看是否对得上某个已安装软件（不含"系统目录 / 厂商目录"这类拿不准的放行）
    private static func softwareMatches(_ name: String, _ sw: InstalledSoftware) -> Bool {
        let lower = name.lowercased()
        if isBundleIDShaped(name) {
            if sw.bundleIDs.contains(where: { lower == $0 || lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) {
                return true
            }
            // 同一厂商还有应用装着（com.riotgames.*、com.microsoft.*）：拿不准，不列。com.electron 之类是通用前缀
            let vendor = lower.split(separator: ".").prefix(2).joined(separator: ".")
            if !genericVendors.contains(vendor), sw.bundleIDs.contains(where: { $0.hasPrefix(vendor + ".") }) { return true }
            // com.openai.codex 之类：末段就是一个已安装的命令行工具或进程
            let last = normalize(String(name.split(separator: ".").last ?? ""))
            return last.count >= 4 && sw.names.contains(last)
        }
        let key = normalize(name)
        if key.isEmpty { return false }
        if sw.names.contains(key) { return true }
        // 应用名是中文、目录是英文（"Riot用戶端" ↔ riot-client-ux）：目录名首个单词是某个已安装名称的开头
        let firstWord = normalize(String(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first ?? ""))
        if firstWord.count >= 4, sw.names.contains(where: { $0.hasPrefix(firstWord) }) { return true }
        return key.count >= 4 && sw.names.contains { $0.count >= 4 && ($0.contains(key) || key.contains($0)) }
    }

    static func candidates(library: String, software: InstalledSoftware, now: Date, minAgeDays: Int = 30,
                           minBytes: UInt64 = 1_000_000,
                           sizeOf: (String) -> UInt64? = { BulkWalker().size(of: $0) }) -> [CleanupCandidate] {
        // 先把所有位置里的同名目录汇总：任何一处最近还在写，就说明应用还在用
        var found: [(location: String, name: String, path: String)] = []
        var newestByName: [String: TimeInterval] = [:]
        for location in locations {
            let dir = library + "/" + location
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = dir + "/" + name
                guard isDirectory(path), !matches(name, software), !descendantMatches(path, software),
                      let newest = newestModification(path) else { continue }
                let key = normalize(name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : name)
                newestByName[key] = max(newestByName[key] ?? 0, newest)
                found.append((location, name, path))
            }
        }
        var out: [CleanupCandidate] = []
        for (location, name, path) in found {
            let key = normalize(name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : name)
            let newest = newestByName[key] ?? 0
            let days = Int(now.timeIntervalSince1970 - newest) / 86_400
            guard days >= minAgeDays, let size = sizeOf(path), size >= minBytes else { continue }
            let shown = name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : name
            let title = location == "Application Support" ? "应用残留 · \(shown)" : "应用残留 · \(shown)（\(location)）"
            let cacheProof = location == "Caches" && isBundleIDShaped(name) ? CleanupEvidence.inventory(path, limit: 10_000) : nil
            let obsoleteCache = cacheProof.map { now.timeIntervalSince1970 - Double($0.newestModifiedAt) >= Double(minAgeDays) * 86400 } ?? false
            let evidence = cacheProof != nil && !obsoleteCache ? "找不到对应的应用或命令行工具 · 目录深处近期仍有修改，需核实" :
                "找不到对应的应用或命令行工具 · \(Humanize.span(days: days) ?? "\(days) 天")没动过"
            let item = ScanItem.trashTarget(path: path, name: title, size: size, rule: "应用残留",
                                            evidence: evidence, risk: .amber)
            out.append(CleanupCandidate(source: "leftover", key: path, title: title, size: size,
                evidence: evidence, risk: .amber, action: .trash(item: item),
                tier: obsoleteCache ? .obsolete : .review,
                tierReason: obsoleteCache ?
                    "已完整检查应用标识对应的缓存，全部内容长期未修改；软件清单与运行进程未发现对应应用，仍需手动确认" :
                    "应用残留可能包含独有数据；未找到应用和长期未修改不足以证明可丢弃"))
        }
        return out
    }

    /// 厂商目录套应用目录（PremiumSoft CyberTech/Navicat CC/Navicat Premium）：往下两层有对得上的就算已安装
    /// 框架自己建的子目录（WebKit、fsCachedData、Electron 的 Cache…）谁家都有，不能当成"属于某个已装软件"的证据：
    /// "webkit" 会模糊匹配上系统进程 com.apple.WebKit.WebContent，让卸载残留永远显示成已安装
    private static let genericChildren: Set<String> = [
        "webkit", "fscacheddata", "cache", "codecache", "gpucache", "dawncache", "blobstorage", "crashpad", "sentry",
        "networkcache", "cachestorage", "indexeddb", "localstorage", "sessionstorage", "serviceworker", "logs", "log",
        "orgsparkleprojectsparkle", "shipit", "updates", "temp", "tmp", "default",
    ]

    private static func descendantMatches(_ path: String, _ sw: InstalledSoftware, depth: Int = 2) -> Bool {
        guard depth > 0, let kids = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        for kid in kids.prefix(40) where !kid.hasPrefix(".") && !genericChildren.contains(normalize(kid)) && isDirectory(path + "/" + kid) {
            if normalize(kid).count >= 4, softwareMatches(kid, sw) { return true }
            if descendantMatches(path + "/" + kid, sw, depth: depth - 1) { return true }
        }
        return false
    }

    /// 只有 ENOENT 才算"程序不存在"：没权限读（EPERM / EACCES）或外接盘没插上，都不能下结论
    static func programMissing(_ program: String) -> Bool {
        guard program.hasPrefix("/"), !program.hasPrefix("/Volumes/") else { return false }
        var st = stat()
        return stat(program, &st) != 0 && errno == ENOENT
    }

    /// 依赖收集是否完整：坏 plist、读不到或枚举失败都不能当成"没有依赖"
    enum AgentDependencyStatus: Equatable {
        case complete
        case unknown(String)
    }

    struct AgentDependencySnapshot {
        let agents: [(label: String, path: String)]
        let status: AgentDependencyStatus

        var isComplete: Bool { status == .complete }
    }

    /// 每个后台服务启动的程序、工作目录和 ProgramArguments 里所有绝对路径；任一启动项读不到或解析不了都标为未知
    static func agentDependencySnapshot(directory: String = HOME + "/Library/LaunchAgents") -> AgentDependencySnapshot {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            // 枚举失败（包括目录不存在或读不到）不能当成"没有启动项"
            return AgentDependencySnapshot(agents: [], status: .unknown("无法读取启动项目录"))
        }
        var out: [(label: String, path: String)] = []
        var complete = true
        for name in names.sorted() where name.hasSuffix(".plist") {
            guard let data = FileManager.default.contents(atPath: directory + "/" + name),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any],
                  let label = dict["Label"] as? String,
                  let paths = agentPaths(in: dict) else {
                complete = false
                continue
            }
            var seen: Set<String> = []
            out += paths.filter { seen.insert($0).inserted }.map { (label, $0) }
        }
        return AgentDependencySnapshot(agents: out, status: complete ? .complete : .unknown("部分启动项无法读取或解析"))
    }

    /// 启动项里可明确识别的绝对路径：程序、工作目录和 ProgramArguments 的每一项
    private static func agentPaths(in dict: [String: Any]) -> [String]? {
        var out: [String] = []
        func append(_ value: Any?) -> Bool {
            guard let value else { return true }
            guard let text = value as? String else { return false }
            if text.hasPrefix("/") { out.append(text) }
            return true
        }
        guard append(dict["Program"]), append(dict["WorkingDirectory"]) else { return nil }
        if let raw = dict["ProgramArguments"] {
            guard let arguments = raw as? [String] else { return nil }
            out += arguments.filter { $0.hasPrefix("/") }
        }
        return out
    }

    /// 兼容旧调用者：只返回能读到的依赖；需要区分完整/未知时用 agentDependencySnapshot
    static func agentDependencies(directory: String = HOME + "/Library/LaunchAgents") -> [(label: String, path: String)] {
        agentDependencySnapshot(directory: directory).agents
    }

    /// 启动的程序已经不存在的 LaunchAgent：应用删了，开机启动项还在
    static func launchAgentCandidates(directory: String) -> [CleanupCandidate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var out: [CleanupCandidate] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            let plist = directory + "/" + name
            guard let (label, program) = readAgent(plist), CleanupArgument.isLaunchLabel(label),
                  programMissing(program) else { continue }
            let shownProgram = program.hasPrefix(HOME + "/") ? "~" + program.dropFirst(HOME.count) : program
            let evidence = "启动的程序已不存在：\(shownProgram)"
            let size = (try? FileManager.default.attributesOfItem(atPath: plist)[.size] as? UInt64) ?? 1
            let item = ScanItem.trashTarget(path: plist, name: label, size: max(size, 1), rule: "后台服务残留",
                                            evidence: evidence, risk: .amber)
            out.append(CleanupCandidate(source: "launchagent", key: plist, title: "后台服务残留 · \(label)",
                size: max(size, 1), evidence: evidence, risk: .amber,
                action: .launchAgentRemove(label: label, item: item), tier: .obsolete,
                tierReason: "启动项引用的程序已确认不存在，执行前会再次核实"))
        }
        return out
    }

    /// 程序还在、却一直崩溃重启的后台服务（应用删了、配置没了，launchd 还在拉它）：只提示，不能清理
    static func failingAgentCandidates(directory: String, runner: CommandRunning, tools: ToolLocator,
                                       minRuns: Int = 20) -> [CleanupCandidate] {
        guard let launchctl = tools.path(for: .launchctl),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var out: [CleanupCandidate] = []
        for name in names.sorted() where name.hasSuffix(".plist") {
            guard let (label, program) = readAgent(directory + "/" + name), CleanupArgument.isLaunchLabel(label),
                  FileManager.default.fileExists(atPath: program) else { continue }
            let r = runner.run(launchctl, ["print", "gui/\(getuid())/\(label)"], timeout: 10)
            guard r.ok else { continue }
            var runs = 0, exitCode: Int?
            for line in r.stdout.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if line.hasPrefix("runs = ") { runs = Int(line.dropFirst("runs = ".count)) ?? 0 }
                if line.hasPrefix("last exit code = ") { exitCode = Int(line.dropFirst("last exit code = ".count)) }
            }
            guard runs >= minRuns, let code = exitCode, code != 0 else { continue }
            let shown = program.hasPrefix(HOME + "/") ? "~" + program.dropFirst(HOME.count) : program
            out.append(CleanupCandidate(source: "agenthealth", key: label, title: "后台服务反复失败 · \(label)", size: 0,
                evidence: "已被拉起 \(runs) 次，上次退出码 \(code) · 启动的程序：\(shown)", risk: .amber, action: nil))
        }
        return out
    }

    /// 执行前复核：启动的程序又出现了（重新装回来了）就不动
    static func launchAgentBlocker(plist: String) -> String? {
        guard let (_, program) = readAgent(plist) else { return "启动项已经不存在了" }
        return programMissing(program) ? nil : "它启动的程序又出现了，不再是残留"
    }

    static func probe(runner: CommandRunning, tools: ToolLocator, library: String = HOME + "/Library",
                      agentsDir: String = HOME + "/Library/LaunchAgents", now: Date = Date(),
                      sizeOf: (String) -> UInt64? = { BulkWalker().size(of: $0) }) -> [CleanupCandidate] {
        // Spotlight 是"装没装"的唯一可靠来源；失败或结果少得反常（索引被关）时一项都不列
        guard let mdfind = tools.path(for: .mdfind) else { return [] }
        let apps = runner.run(mdfind, ["kMDItemContentType == \"com.apple.application-bundle\""], timeout: 20)
        let appPaths = apps.stdout.split(separator: "\n").map(String.init).filter { $0.hasSuffix(".app") }
        guard apps.ok, appPaths.count >= 20 else { return [] }
        let ps = tools.path(for: .ps).map { runner.run($0, ["-axo", "comm="], timeout: 10) }
        guard let ps, ps.ok else { return [] }
        let commandDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", HOME + "/.local/bin", HOME + "/.cargo/bin",
                           HOME + "/go/bin", HOME + "/.npm-global/bin", HOME + "/.bun/bin",
                           "/usr/local/lib/node_modules", "/opt/homebrew/lib/node_modules"]
        let commands = commandDirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        let software = InstalledSoftware.collect(appPaths: appPaths,
            processes: ps.stdout.split(separator: "\n").map(String.init), commandNames: commands)
        return candidates(library: library, software: software, now: now, sizeOf: sizeOf)
            + launchAgentCandidates(directory: agentsDir)
    }

    private static func readAgent(_ plist: String) -> (label: String, program: String)? {
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = dict["Label"] as? String else { return nil }
        let program = dict["Program"] as? String ?? (dict["ProgramArguments"] as? [String])?.first
        return program.map { (label, $0) }
    }

    /// 目录自己和直接子项里最新的修改时间（目录 mtime 只在直接子项增删时才变）
    private static func newestModification(_ path: String) -> TimeInterval? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var newest = TimeInterval(st.st_mtimespec.tv_sec)
        for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            if lstat(path + "/" + child, &st) == 0 { newest = max(newest, TimeInterval(st.st_mtimespec.tv_sec)) }
        }
        return newest
    }
}
