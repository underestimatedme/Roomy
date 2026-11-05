// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

enum AutomationDiscovery {
    static func volume(home: String = NSHomeDirectory()) -> AutomationVolume? {
        var info = statfs()
        guard statfs(home, &info) == 0, info.f_blocks > 0, (info.f_flags & UInt32(MNT_LOCAL)) != 0,
              let values = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeUUIDStringKey]),
              let uuid = values.volumeUUIDString else { return nil }
        return AutomationVolume(id: uuid, path: home, total: UInt64(info.f_blocks) * UInt64(info.f_bsize), available: UInt64(info.f_bavail) * UInt64(info.f_bsize))
    }
    static func scopes(home: String = NSHomeDirectory()) throws -> [AutomationScope] {
        guard volume(home: home) != nil else { throw automationError("无法识别当前用户所在的本地磁盘") }
        let deadline = Date().addingTimeInterval(300)
        var scopes = ApplicationCacheProbe.probe(home: home, sizeOf: { path in
            guard Date() < deadline else { return nil }
            return CleanupEvidence.inventory(path)?.bytes
        }).compactMap { candidate -> AutomationScope? in
            guard candidate.entry.selectable, case .trash(let item)? = candidate.action else { return nil }
            return .init(kind: .appCache, path: item.path, title: item.name)
        }
        let root = home + "/Library/Developer/Xcode/DerivedData"
        if ApplicationAssociations.directoryIdentities(root) != nil {
            var notices: [String] = []
            for entry in ApplicationAssociations.entries(root, notices: &notices).prefix(100) where entry.isDir && !entry.isLink {
                guard Date() < deadline else { throw automationError("读取范围超时，请缩小范围后重试") }
                let path = root + "/" + entry.name + "/Build/Intermediates.noindex"
                guard let tree = CleanupEvidence.inventory(path), tree.bytes > 0 else { continue }
                let item = CleanupEvidence.applying(to: ScanItem.trashTarget(path: path, name: entry.name + " 编译对象", size: tree.bytes, rule: "Xcode 生成缓存", evidence: "", risk: .amber))
                if item.undo { scopes.append(.init(kind: .derivedObjects, path: path, title: item.name)) }
            }
        }
        guard Date() < deadline else { throw automationError("读取范围超时，请重新检查") }
        return scopes.filter { sameVolume($0.path, home: home) }.sorted { $0.path < $1.path }
    }
    static func sameVolume(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        var a = stat(), b = stat()
        return lstat(home, &a) == 0 && lstat(path, &b) == 0 && a.st_dev == b.st_dev
    }
    static func discover(rule: AutomationRule, home: String = NSHomeDirectory()) throws -> [CleanupCandidate] {
        try rule.validate()
        guard let current = volume(home: home), current.id == rule.volumeID else { throw automationError("磁盘身份改变或无法读取") }
        let started = Date()
        let permissionHint = "请在系统设置的隐私与安全性中检查 Roomy 及后台组件的文件访问权限，核对目录后恢复规则"
        // ENOENT is a genuinely absent cache. Every other inspection failure must preserve due work.
        var present: [AutomationScope] = []
        for scope in rule.scopes {
            var info = stat()
            if lstat(scope.path, &info) != 0 {
                let code = errno
                if code == ENOENT { continue }
                if [EAGAIN, EINTR, ETIMEDOUT, EBUSY].contains(code) {
                    throw automationError("范围暂时不可读取：\(scope.title)", transient: true)
                }
                throw automationError("范围不可读取：\(scope.title)；" + permissionHint)
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR, sameVolume(scope.path, home: home) else {
                throw automationError("范围的类型或磁盘已变化：\(scope.title)；" + permissionHint)
            }
            present.append(scope)
        }
        var incomplete: String?
        let appCandidates = present.contains { $0.kind == .appCache } ? ApplicationCacheProbe.probe(home: home, sizeOf: { path in
            guard Date().timeIntervalSince(started) < 300 else { return nil }
            guard present.contains(where: { $0.kind == .appCache && $0.path == path }) else { return 0 }
            guard let tree = CleanupEvidence.inventory(path) else { incomplete = path; return nil }
            return tree.bytes
        }) : []
        guard Date().timeIntervalSince(started) < 300 else { throw automationError("范围扫描超时", transient: true) }
        if let incomplete { throw automationError("无法完整检查缓存：\(incomplete)；" + permissionHint) }
        var result: [CleanupCandidate] = []
        for scope in present {
            guard Date().timeIntervalSince(started) < 300 else { throw automationError("范围扫描超时", transient: true) }
            switch scope.kind {
            case .appCache:
                guard let candidate = appCandidates.first(where: { $0.entry.path == scope.path }) else {
                    throw automationError("无法核实缓存的归属或读取权限：\(scope.title)；" + permissionHint)
                }
                if candidate.entry.selectable { result.append(candidate) }
                // The existing probe explicitly identifies running apps. Other blockers require repair.
                else if !candidate.entry.evidence.contains("正在运行") {
                    throw automationError(candidate.entry.evidence + "；" + permissionHint)
                }
            case .derivedObjects:
                let root = home + "/Library/Developer/Xcode/DerivedData/"
                guard scope.path.hasPrefix(root), scope.path.hasSuffix("/Build/Intermediates.noindex"),
                      String(scope.path.dropFirst(root.count)).split(separator: "/").count == 3 else {
                    throw automationError("编译缓存范围已失效，请重新选择范围")
                }
                guard let tree = CleanupEvidence.inventory(scope.path) else {
                    throw automationError("无法完整检查编译缓存：\(scope.title)；" + permissionHint)
                }
                guard tree.bytes > 0 else { continue }
                let item = CleanupEvidence.applying(to: ScanItem.trashTarget(path: scope.path, name: scope.title, size: tree.bytes, rule: "Xcode 生成缓存", evidence: "", risk: .amber))
                guard item.undo else { throw automationError("编译缓存证据无法验证：\(scope.title)") }
                result.append(CleanupListBuilder.fromRule(item))
            }
        }
        return result
    }

    /// Read-only scheduled scan used by the background worker. It deliberately stops before protected folders,
    /// full-folder walks, permission prompts, cleanup plans and any deletion.
    static func scan(directory: URL, now: Date = Date()) throws -> AutomationScanSummary {
        let found = ScanPipeline.run(stage: { _, _, _ in })
        let running = RunningOwners.capture(runner: ProcessRunner(), tools: ToolLocator())
        let owners = OwnerContext(scopes: found.ownerScopes, running: running, now: now)
        var list = CleanupListBuilder.build(items: found.items, probes: found.probes,
            agentPaths: AppLeftoverProbe.agentDependencies(), running: running, owners: owners)
        // A failed process listing is unknown, never "nothing is running".
        if running == nil { list = RunningOwners.markUnverified(list) }
        // The same protected-cleanup.json the execution boundary reads. A protected row stays visible but is
        // never counted as actionable here.
        let protection = CleanupProtectionStore(url: directory.appendingPathComponent("protected-cleanup.json"))
        list = try protection.apply(to: list)
        let entries = list.candidates.map(\.entry).filter { $0.selectable && $0.userProtected != true }
        // Nested paths are deduplicated by the shared report rules. Free space is intentionally unknown: this
        // summary never promises released bytes.
        let total = ReportSummary.compute(entries: entries, free: nil).total
        var warnings = found.rootWarnings
        if running == nil { warnings.append("无法检查运行中的程序，相关项目已标记为需确认") }
        let protected = list.candidates.filter { $0.entry.userProtected == true }.count
        if protected > 0 { warnings.append("已排除 \(protected) 个受保护项目") }
        warnings = warnings.filter { !$0.isEmpty }.map { String($0.prefix(300)) }
        if warnings.count > 20 { warnings = Array(warnings.prefix(20)) }
        // Display only: title and bytes, no path, action, item or token.
        let preview = entries.prefix(5).map { AutomationScanSummary.Preview(title: $0.title, bytes: $0.size) }
        return AutomationScanSummary(scannedAt: Date(), itemCount: list.candidates.count,
            actionableCount: entries.count, estimatedBytes: total.bytes,
            warnings: warnings, preview: preview.isEmpty ? nil : preview)
    }
}
