// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Bounded cache leaves only. User databases, cookies, sessions, profile roots
/// and site storage are deliberately outside this probe's authority.
enum ApplicationCacheProbe {
    private enum Layout { case chromium, firefox, electron, sandbox }
    private struct Definition {
        let id: String
        let relative: String
        let layout: Layout
    }
    private static let definitions: [Definition] = [
        .init(id: "com.google.Chrome", relative: "Caches/Google/Chrome", layout: .chromium),
        .init(id: "com.microsoft.edgemac", relative: "Caches/Microsoft Edge", layout: .chromium),
        .init(id: "com.microsoft.edgemac", relative: "Caches/com.microsoft.edgemac", layout: .chromium),
        .init(id: "com.brave.Browser", relative: "Caches/BraveSoftware/Brave-Browser", layout: .chromium),
        .init(id: "org.mozilla.firefox", relative: "Caches/Firefox/Profiles", layout: .firefox),
        .init(id: "com.tinyspeck.slackmacgap", relative: "Application Support/Slack", layout: .electron),
        .init(id: "com.hnc.Discord", relative: "Application Support/discord", layout: .electron),
        .init(id: "notion.id", relative: "Application Support/Notion", layout: .electron),
        .init(id: "md.obsidian", relative: "Application Support/obsidian", layout: .electron),
        .init(id: "com.tencent.xinWeChat", relative: "Containers/com.tencent.xinWeChat", layout: .sandbox),
        .init(id: "net.whatsapp.WhatsApp", relative: "Containers/net.whatsapp.WhatsApp", layout: .sandbox),
        .init(id: "com.microsoft.teams2", relative: "Containers/com.microsoft.teams2", layout: .sandbox)
    ]

    /// 这里按应用和配置管的目录（相对 ~/Library）：InstalledAppDataProbe 不再整块重复列它们
    static var ownedRelativePaths: [String] { definitions.map(\.relative) }

    static func probe(home: String = HOME, catalogRoots: [String]? = nil,
                      runner: CommandRunning = ProcessRunner(), tools: ToolLocator = ToolLocator(),
                      sizeOf: (String) -> UInt64? = { ApplicationSession.measure($0) }) -> [CleanupCandidate] {
        let process = tools.path(for: .ps).map { runner.run($0, ["-axo", "comm="], timeout: 10) }
        let processAvailable = process?.ok == true
        let running = processAvailable ? process!.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } : []
        let inventory = ApplicationCatalog.discover(roots: catalogRoots ?? ["/Applications", home + "/Applications", "/System/Applications"],
            runningPaths: running, sizeOf: { _ in 0 })
        var result: [CleanupCandidate] = []
        func notice(app: ApplicationRecord, message: String, key: String) {
            var candidate = CleanupCandidate(source: "appcache", key: "notice:" + app.id + ":" + key,
                title: app.title + " · 缓存扫描说明", size: 0, evidence: message, risk: .lock, action: nil)
            candidate.entry.group = app.title
            result.append(candidate)
        }
        for definition in definitions {
            let owners = inventory.apps.filter { $0.bundleID == definition.id }
            guard let app = owners.first else { continue }
            var notices: [String] = []
            let base = home + "/Library/" + definition.relative
            var folders: [(path: String, profile: String)] = []
            var targets: [(path: String, profile: String)] = []
            switch definition.layout {
            case .sandbox:
                targets = SandboxCachePaths.discover(library: home + "/Library", id: definition.id, notices: &notices)
            case .electron: folders = [(base, "默认会话")]
            case .chromium, .firefox:
                for entry in ApplicationAssociations.entries(base, notices: &notices) where entry.isDir && !entry.isLink {
                    let valid: Bool
                    switch definition.layout {
                    case .chromium:
                        valid = ["Default", "Guest Profile", "System Profile"].contains(entry.name) ||
                            entry.name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
                    case .firefox:
                        valid = entry.name.range(of: #"^[A-Za-z0-9]{8}\.[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
                    case .electron, .sandbox: valid = false
                    }
                    if valid { folders.append((base + "/" + entry.name, entry.name)) }
                    else { notices.append("未识别的配置目录未扫描，保留其内容：\(base)/\(entry.name)") }
                }
            }
            let names: Set<String>
            switch definition.layout {
            case .chromium: names = ["Cache", "Code Cache"]
            case .firefox: names = ["cache2", "startupCache", "thumbnails"]
            case .electron: names = ["Cache", "Code Cache", "GPUCache"]
            case .sandbox: names = []
            }
            let blocker: String?
            var ownerRunning = false   // 阻断原因是应用（或它的辅助进程）正在运行 → 本次"不能删"；其他阻断留在 C
            if !processAvailable { blocker = "无法检查运行状态，本次缓存仅供查看；请确认读取权限后重新扫描" }
            else if !inventory.warnings.isEmpty || owners.count != 1 { blocker = "安装清单不完整或有应用副本，缓存归属不能唯一确认；仅供查看" }
            else if SandboxCachePaths.externalHelperRunning(id: definition.id, paths: running) {
                blocker = "Teams 的 WebView 辅助进程正在运行，请先自行退出后重新扫描"; ownerRunning = true
            }
            else if app.blockReason != nil && app.blockReason != ApplicationCatalog.helperBlockReason {
                blocker = app.blockReason; ownerRunning = app.blockReason == ApplicationCatalog.runningBlockReason
            }
            else { blocker = nil }
            for folder in folders {
                for entry in ApplicationAssociations.entries(folder.path, notices: &notices)
                    where names.contains(entry.name) && entry.isDir && !entry.isLink {
                    targets.append((folder.path + "/" + entry.name, folder.profile))
                }
            }
            for target in targets {
                let path = target.path, leaf = (path as NSString).lastPathComponent
                guard let size = sizeOf(path) else {
                    notices.append("缓存大小未能完整读取，未计入可处理空间：\(path)。" + (definition.layout == .sandbox ? SandboxCachePaths.permissionHint : "")); continue
                }
                let evidence = blocker ?? "仅此应用的 \(target.profile) · \(leaf) 缓存；退出应用后手动确认，缺失时会重新下载或生成。保留登录状态、聊天数据库、附件目录、离线内容与网站存储。"
                let item = ScanItem.trashTarget(path: path, name: app.title + " · " + target.profile + " · " + leaf,
                    size: size, rule: "应用可重建缓存", evidence: evidence, risk: .amber)
                var candidate = CleanupCandidate(source: "appcache", key: path, title: item.name,
                    size: size, evidence: evidence, risk: blocker == nil ? .amber : .lock,
                    action: .trash(item: item), tier: blocker == nil ? .rebuildable : .review,
                    tierReason: blocker ?? "已识别应用与配置的缓存子目录；下次使用会下载或生成，默认不选") // Locked entries retain the target only for honest pipeline sizing.
                candidate.entry.path = path; candidate.entry.group = app.title
                if blocker == nil {
                    candidate.entry.preferenceKey = CleanupPreferenceKey(owner: definition.id, kind: "app-cache:" + leaf,
                        scope: CleanupPreferenceKey.digest(path))
                    candidate = candidate.retiered(.obsolete, reason: "已识别应用与配置的缓存子目录，应用未运行；下次使用会重新下载或生成，可从废纸篓找回")
                } else if ownerRunning, let blocker {
                    candidate = candidate.locked(blocker)
                }
                result.append(candidate)
            }
            for (index, message) in notices.enumerated() { notice(app: app, message: message, key: definition.relative + ":" + String(index)) }
        }
        return result
    }

    static func executionBlocker(path: String, environment: CleanupEnvironment) -> String? {
        guard let home = environment.roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else {
            return "缓存不在允许处理的目录中"
        }
        let current = probe(home: home, catalogRoots: environment.applicationRoots,
            runner: environment.runner, tools: environment.tools,
            sizeOf: { $0 == path ? environment.applicationCacheMeasurement($0) : 0 })
        guard let candidate = current.first(where: { $0.entry.path == path }) else {
            return "应用缓存的归属、路径或读取权限发生变化，请重新扫描"
        }
        return candidate.entry.selectable ? nil : candidate.entry.evidence
    }
}
