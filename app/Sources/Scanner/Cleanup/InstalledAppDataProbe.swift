// SPDX-License-Identifier: MPL-2.0
// 已安装应用的缓存、日志、自动更新下载的安装包，以及 IDE（JetBrains、Android Studio）按版本存放的缓存与日志。
// 只认能对上某个已安装应用的目录：对不上的归 AppLeftoverProbe（卸载残留）。Apple 自带应用和 Roomy 自己不碰；
// 应用在运行就锁定。一律移到废纸篓，可找回。不进后台自动清理：那边只认 ApplicationCacheProbe 的"应用可重建缓存"。

import Foundation

enum InstalledAppDataProbe {
    static let source = "appdata"
    static let updateGroup = "应用更新安装包"
    static let cacheGroup = "已安装应用的缓存"
    static let logGroup = "已安装应用的日志"
    static let ideGroup = "IDE 缓存与日志"
    static let updatingReason = "正在安装更新，结束后重新扫描"
    static let unverifiedReason = "安装清单不完整，缓存归属不能完全确认；请核实后再清"
    static let androidStudioID = "com.google.android.studio"
    /// 目录名既不是 bundle ID 也不是应用名的别名（小写目录名 → bundle ID）。只收核实过的：
    /// ChatGPT.app（com.openai.codex）的缓存目录叫 Codex
    static let folderAliases: [String: String] = [
        "codex": "com.openai.codex",
    ]
    private static let sparkleFolder = "org.sparkle-project.Sparkle"
    private static let ownBundleID = "com.atlaspaces.roomy"

    private struct Target {
        let path: String
        let title: String
        let group: String
        let tier: CleanupTier
        let reason: String
        let owner: ApplicationRecord?
        let kind: String
        var update = false
    }

    static func probe(home: String = HOME, catalogRoots: [String]? = nil,
                      runner: CommandRunning = ProcessRunner(), tools: ToolLocator = ToolLocator(),
                      sizeOf: (String) -> UInt64? = { ApplicationSession.measure($0) }) -> [CleanupCandidate] {
        // 读不到进程列表就不知道谁在运行：整组不列，免得把正开着的应用的缓存挪走
        guard let ps = tools.path(for: .ps) else { return [] }
        let process = runner.run(ps, ["-axo", "comm="], timeout: 10)
        guard process.ok else { return [] }
        let running = process.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let inventory = ApplicationCatalog.discover(roots: catalogRoots ?? ["/Applications", home + "/Applications", "/System/Applications"],
            runningPaths: running, sizeOf: { _ in 0 })
        let apps = inventory.apps.filter { app in
            let id = app.bundleID.lowercased()
            return !app.system && !id.hasPrefix("com.apple.") && id != ownBundleID
        }
        var byID: [String: [ApplicationRecord]] = [:], byTitle: [String: [ApplicationRecord]] = [:]
        for app in apps {
            byID[app.bundleID.lowercased(), default: []].append(app)
            byTitle[app.title.lowercased(), default: []].append(app)
        }
        let library = home + "/Library", caches = library + "/Caches", logs = library + "/Logs"
        let ruleOwned = RULES.flatMap(\.literalPaths)
        let probeOwned = ApplicationCacheProbe.ownedRelativePaths.map { library + "/" + $0 }
        func claimed(_ path: String) -> Bool {
            (ruleOwned + probeOwned).contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
        }
        func ownersOf(_ folder: String) -> [ApplicationRecord]? {
            let key = folder.lowercased()
            return byID[key] ?? byTitle[key] ?? folderAliases[key].flatMap { byID[$0] }
        }
        func directories(_ dir: String) -> [String] {
            var notices: [String] = []
            return ApplicationAssociations.entries(dir, notices: &notices)
                .filter { $0.isDir && !$0.isLink && !$0.name.hasPrefix(".") }.map(\.name).sorted()
        }
        func exists(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }

        var targets: [Target] = []
        // 1. 缓存目录名就是应用的 bundle ID（或应用名）；Sparkle / Squirrel(ShipIt) 下载的更新安装包单独列
        for name in directories(caches) {
            let path = caches + "/" + name
            if name.hasSuffix(".ShipIt"), let owners = byID[String(name.dropLast(".ShipIt".count)).lowercased()], owners.count == 1 {
                targets.append(.init(path: path, title: owners[0].title + " · 更新安装包", group: updateGroup, tier: .obsolete,
                    reason: "应用自动更新下载的安装包；应用没在运行，需要时会重新下载，可从废纸篓找回", owner: owners[0], kind: "update", update: true))
                continue
            }
            guard let owners = ownersOf(name), owners.count == 1, !claimed(path) else { continue }
            let app = owners[0]
            targets.append(.init(path: path, title: app.title + " · 缓存" + folderNote(name, app), group: cacheGroup, tier: .rebuildable,
                reason: "已安装应用 \(app.title) 的缓存目录，应用会按需重新生成；默认不选，可从废纸篓找回", owner: app, kind: "cache"))
            if exists(path + "/" + sparkleFolder) {
                targets.append(.init(path: path + "/" + sparkleFolder, title: app.title + " · 更新安装包", group: updateGroup, tier: .obsolete,
                    reason: "应用自动更新（Sparkle）下载的安装包；应用没在运行，需要时会重新下载，可从废纸篓找回", owner: app, kind: "update", update: true))
            }
        }
        // 2. 日志目录名是应用的 bundle ID 或应用名
        for name in directories(logs) {
            let path = logs + "/" + name
            guard let owners = ownersOf(name), owners.count == 1, !claimed(path) else { continue }
            targets.append(.init(path: path, title: owners[0].title + " · 日志" + folderNote(name, owners[0]), group: logGroup, tier: .rebuildable,
                reason: "已安装应用 \(owners[0].title) 的日志，删除不影响使用；默认不选，可从废纸篓找回", owner: owners[0], kind: "log"))
        }
        // 3. IDE：按应用自带的 product-info.json 找到当前版本的数据目录名（如 IdeaIC2024.3）
        var studioDirs = Set<String>()
        for app in apps {
            let id = app.bundleID.lowercased()
            let vendor = id.hasPrefix("com.jetbrains.") ? "JetBrains" : id == androidStudioID ? "Google" : nil
            guard let vendor, let dataDir = dataDirectoryName(app.path) else { continue }
            if vendor == "Google" { studioDirs.insert(dataDir) }
            for (base, word) in [(caches, "缓存与索引"), (logs, "日志")] where exists(base + "/" + vendor + "/" + dataDir) {
                targets.append(.init(path: base + "/" + vendor + "/" + dataDir, title: "\(app.title) · \(dataDir) \(word)", group: ideGroup,
                    tier: .rebuildable, reason: "当前安装的 \(app.title) 的\(word)，删除后重新打开项目要重建索引；默认不选，可从废纸篓找回",
                    owner: app, kind: "ide"))
            }
        }
        // Android Studio 其他版本：一个都没装（应用目录和 Spotlight 都找不到）才算卸载残留，否则只列不勾
        let studioGone = studioDirs.isEmpty && androidStudioAbsent(runner: runner, tools: tools)
        for base in [caches, logs] {
            for name in directories(base + "/Google")
            where name.range(of: #"^AndroidStudio[0-9.]+$"#, options: .regularExpression) != nil && !studioDirs.contains(name) {
                let word = base == caches ? "缓存" : "日志"
                targets.append(studioGone
                    ? .init(path: base + "/Google/" + name, title: "Android Studio · \(name) \(word)", group: ideGroup, tier: .obsolete,
                            reason: "找不到 Android Studio（应用目录和 Spotlight 都没有），这是卸载后留下的\(word)；可从废纸篓找回", owner: nil, kind: "ide")
                    : .init(path: base + "/Google/" + name, title: "Android Studio · \(name) \(word)", group: ideGroup, tier: .review,
                            reason: "Android Studio 其他版本留下的\(word)；当前安装的版本不用它，请核实后再清", owner: nil, kind: "ide"))
            }
        }

        let updaterRunning = running.contains { ($0 as NSString).lastPathComponent == "ShipIt" || $0.contains("/" + sparkleFolder + "/") }
        return targets.compactMap { target -> CleanupCandidate? in
            guard let size = sizeOf(target.path) else { return nil }
            let item = ScanItem.trashTarget(path: target.path, name: target.title, size: size, rule: target.group,
                                            evidence: target.reason, risk: .amber)
            var candidate = CleanupCandidate(source: source, key: target.path, title: target.title, size: size,
                evidence: target.reason, risk: .amber, action: .trash(item: item), tier: target.tier, tierReason: target.reason)
            candidate.entry.path = target.path; candidate.entry.group = target.group
            candidate.entry.preferenceKey = CleanupPreferenceKey(owner: target.owner?.bundleID ?? androidStudioID,
                kind: "appdata:" + target.kind, scope: CleanupPreferenceKey.digest(target.path))
            if target.owner?.blockReason == ApplicationCatalog.runningBlockReason { return candidate.locked(ApplicationCatalog.runningBlockReason) }
            if target.update, updaterRunning { return candidate.locked(updatingReason) }
            if !inventory.warnings.isEmpty, target.tier != .review { return candidate.requiringReview(unverifiedReason) }
            return candidate
        }
    }

    /// 目录名和应用名不同时写在标题后面：同名应用（两个都叫 ChatGPT）或一个应用两个目录时能分清是哪一个
    private static func folderNote(_ folder: String, _ app: ApplicationRecord) -> String {
        folder.lowercased() == app.title.lowercased() ? "" : "（\(folder)）"
    }

    /// IDE 自带的 product-info.json 里的 dataDirectoryName；读不到或格式不对返回 nil
    static func dataDirectoryName(_ appPath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: appPath + "/Contents/Resources/product-info.json"),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = info["dataDirectoryName"] as? String,
              name.range(of: #"^[A-Za-z]+[0-9][0-9.]*$"#, options: .regularExpression) != nil else { return nil }
        return name
    }

    /// Spotlight 也找不到 Android Studio。mdfind 不可用或失败都按"可能还装着"处理
    private static func androidStudioAbsent(runner: CommandRunning, tools: ToolLocator) -> Bool {
        guard let mdfind = tools.path(for: .mdfind) else { return false }
        let r = runner.run(mdfind, ["kMDItemCFBundleIdentifier == \"\(androidStudioID)\""], timeout: 20)
        return r.ok && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 执行前复核：重新探测一次，这一项还在且仍可选才放行
    static func executionBlocker(path: String, environment: CleanupEnvironment) -> String? {
        guard let home = environment.roots.filter({ path.hasPrefix($0 + "/Library/") }).max(by: { $0.count < $1.count }) else {
            return "目录不在允许处理的范围内"
        }
        let current = probe(home: home, catalogRoots: environment.applicationRoots, runner: environment.runner,
                            tools: environment.tools, sizeOf: { _ in 0 })
        guard let candidate = current.first(where: { $0.entry.path == path }) else {
            return "应用的安装状态或目录发生变化，请重新扫描"
        }
        return candidate.entry.selectable ? nil : candidate.entry.lockReason ?? candidate.entry.evidence
    }
}
