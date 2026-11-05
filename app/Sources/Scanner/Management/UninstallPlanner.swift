// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

struct UninstallPart: Codable { var entry: CleanupEntry; let role: String }
struct UninstallPlan {
    let token: String
    let app: ApplicationRecord
    var candidates: [CleanupCandidate]
    var parts: [UninstallPart]
    let notices: [String]
    let home: String
    var temporaryDirectories: [ApplicationTemporaryDirectory] = []
    var temporaryIdentities: [String: CleanupIdentity] = [:]
    var associationParentIdentities: [String: [String: CleanupIdentity]] = [:]
    var nestedBundleSourceIdentities: [String: CleanupIdentity] = [:]

    func applying(_ store: CleanupProtectionStore) throws -> UninstallPlan {
        var result = self
        result.candidates = try store.apply(to: CleanupList(candidates: candidates)).candidates
        let entries = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.entry.id, $0.entry) })
        result.parts = parts.map { UninstallPart(entry: entries[$0.entry.id] ?? $0.entry, role: $0.role) }
        return result
    }
}

enum UninstallPlanner {
    static func preview(app: ApplicationRecord, catalog: [ApplicationRecord], home: String,
                        temporaryDirectories: [ApplicationTemporaryDirectory] = [],
                        sizeOf: (String) -> UInt64? = { BulkWalker().size(of: $0) }) -> UninstallPlan {
        let fm = FileManager.default
        var candidates: [CleanupCandidate] = [], parts: [UninstallPart] = []
        var notices = ["卸载只移入废纸篓，清空后才释放空间；恢复文件不等于恢复后台服务。",
                       "共享厂商目录、登录钥匙串、系统级辅助程序和无法确认归属的组件不会自动移除。"]
        let duplicate = catalog.filter { $0.bundleID == app.bundleID }.count > 1
        if duplicate { notices.append("存在相同标识的其他安装，关联数据按共享内容保护。") }
        var blocked = app.blockReason
        // Registered services are not silently broken by deleting their executable bundle.
        for dependency in AppLeftoverProbe.agentDependencies(directory: home + "/Library/LaunchAgents") {
            if dependency.path == app.path || dependency.path.hasPrefix(app.path + "/") {
                blocked = "应用注册了后台服务，请使用厂商卸载方式或先自行停用服务"
            }
        }
        func add(_ path: String, title: String, role: String, evidence: String, executable: Bool, defaultChecked: Bool) {
            guard let identity = CleanupIdentity.capture(path: path) else { return }
            var canExecute = executable && blocked == nil && identity.kind != .symbolicLink
            if path != app.path && duplicate { canExecute = false }
            let size = path == app.path ? app.size : sizeOf(path)
            if size == nil { canExecute = false; notices.append("未能完整统计：\(path)") }
            let item = ScanItem.trashTarget(path: path, name: title, size: size ?? 0, rule: "应用卸载", evidence: evidence, risk: .amber)
            var candidate = CleanupCandidate(source: "uninstall", key: path, title: title, size: size ?? 0,
                evidence: blocked ?? (duplicate && path != app.path ? "其他安装仍可能使用此数据" : evidence),
                risk: canExecute ? .amber : .lock, action: canExecute ? .trash(item: item) : nil)
            // Preserve the identity from inventory for the bundle, rather than re-authorize a replacement at preview.
            if path == app.path, canExecute, let expected = app.identity {
                let original = ScanItem(name: item.name, path: item.path, size: item.size, atimeDays: nil, mtimeDays: nil, usedDays: nil,
                    rule: item.rule, evidence: item.evidence, risk: item.risk, gentle: nil, hard: item.hard, undo: true, note: "", rebuild: .costly, identity: expected)
                candidate = CleanupCandidate(source: "uninstall", key: path, title: title, size: item.size, evidence: evidence, risk: .amber, action: .trash(item: original))
            }
            candidate.entry.path = path
            candidate.entry.defaultChecked = canExecute && defaultChecked
            candidate.entry.group = app.title
            candidates.append(candidate); parts.append(UninstallPart(entry: candidate.entry, role: role))
        }
        add(app.path, title: "应用本体 · \(app.title)", role: "bundle", evidence: "移入废纸篓后无法正常打开，恢复本体可重新使用", executable: true, defaultChecked: true)
        guard ApplicationCatalog.validBundleID(app.bundleID) else {
            return UninstallPlan(token: UUID().uuidString, app: app, candidates: candidates, parts: parts, notices: notices, home: home,
            temporaryDirectories: temporaryDirectories, temporaryIdentities: Dictionary(temporaryDirectories.compactMap { root in root.identity().map { (root.path, $0) } }, uniquingKeysWith: { first, _ in first }))
        }
        let locations: [(String, String, String, Bool)] = [
            ("Caches", app.bundleID, "cache", true), ("Logs", app.bundleID, "cache", true),
            ("Preferences", app.bundleID + ".plist", "data", false),
            ("Application Support", app.bundleID, "data", false),
            ("HTTPStorages", app.bundleID, "data", false), ("WebKit", app.bundleID, "data", false),
            ("Saved Application State", app.bundleID + ".savedState", "data", false),
            ("Containers", app.bundleID, "data", false)
        ]
        for (location, name, role, recommended) in locations {
            let parent = home + "/Library/" + location, path = parent + "/" + name
            var st = stat()
            // No association through a symlinked Library or category parent.
            guard ApplicationAssociations.directoryIdentities(parent) != nil else {
                if lstat(parent, &st) == 0 || errno != ENOENT { notices.append("关联目录不可安全读取，已跳过：\(parent)") }
                continue
            }
            if lstat(path, &st) != 0 {
                if errno != ENOENT { notices.append("无法检查关联内容：\(path)") }; continue
            }
            add(path, title: location == "Caches" ? "可重建缓存" : location == "Logs" ? "应用日志" : "应用数据 · \(location)",
                role: role, evidence: recommended ? "按精确应用标识匹配；缺失时可能重新下载或生成" : "可能包含文档、配置或登录状态，请逐项确认",
                executable: true, defaultChecked: recommended)
        }
        let nested = NestedBundleAssociations.discover(app: app, catalog: catalog, home: home,
            temporaryDirectories: temporaryDirectories, notices: &notices)
        let associations = ApplicationAssociations.discover(app: app, catalog: catalog, home: home,
            temporaryDirectories: temporaryDirectories, notices: &notices) + nested.associations
        for association in associations {
            if candidates.contains(where: { $0.entry.path == association.path }) { continue }
            add(association.path, title: association.title, role: association.role, evidence: association.evidence,
                executable: association.executable, defaultChecked: false)
        }
        // Name-only user data and group containers remain read-only.
        for location in ["Application Support", "Group Containers"] {
            let parent = home + "/Library/" + location
            guard ApplicationAssociations.directoryIdentities(parent) != nil else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: parent)) ?? [] {
                let path = parent + "/" + name
                if candidates.contains(where: { $0.entry.path == path }) { continue }
                let normalized = AppLeftoverProbe.normalize(name)
                let titleKey = AppLeftoverProbe.normalize(app.title)
                if (titleKey.count >= 4 && normalized == titleKey) || (location == "Group Containers" && name.hasSuffix(app.bundleID)) {
                    add(path, title: "归属需核查 · \(name)", role: "review", evidence: "仅名称或组标识相似，可能由多个应用共享；只能查看", executable: false, defaultChecked: false)
                }
            }
        }
        let parents = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate -> (String, [String: CleanupIdentity])? in
            guard let path = candidate.entry.path, path != app.path,
                  let identities = ApplicationAssociations.directoryIdentities(URL(fileURLWithPath: path).deletingLastPathComponent().path) else { return nil }
            return (candidate.entry.id, Dictionary(uniqueKeysWithValues: identities))
        })
        return UninstallPlan(token: UUID().uuidString, app: app, candidates: candidates, parts: parts, notices: notices, home: home,
            temporaryDirectories: temporaryDirectories, temporaryIdentities: Dictionary(temporaryDirectories.compactMap { root in root.identity().map { (root.path, $0) } }, uniquingKeysWith: { first, _ in first }),
            associationParentIdentities: parents, nestedBundleSourceIdentities: nested.sourceIdentities)
    }
}
