// SPDX-License-Identifier: GPL-3.0-only
// 后台服务从 …/releases/<版本>/ 里运行（自己部署的 agent、Capistrano 式发布）：每发布一次就留下一整份副本。
// 服务正在用的版本、各自之前最近的一个（回滚用）和比它们都新的版本（可能刚装好还没切过去）保留，其余更早的进 A。
// 先后按目录的创建时间排，不按版本号：0.5.1、0.5.9rc1-a08、147a092 这类名字没有统一的大小顺序。
// 复制出来的版本会带着原目录的创建时间：同一时刻创建的，再按版本名的自然顺序排（a07 在 a08 之前）。

import Darwin
import Foundation

enum ReleaseHistoryProbe {
    static let rule = "旧版本发布目录"
    static let inUse = "有进程正在使用这个版本，结束后重新扫描"
    typealias Agent = (label: String, path: String)
    private struct Release {
        let name: String, seconds: Int, nanoseconds: Int
        /// 先比创建时间，同一时刻再比名字
        func isOlder(than other: Release) -> Bool {
            if (seconds, nanoseconds) != (other.seconds, other.nanoseconds) {
                return (seconds, nanoseconds) < (other.seconds, other.nanoseconds)
            }
            return name.localizedStandardCompare(other.name) == .orderedAscending
        }
    }

    /// 依赖不完整时整个目录都不列；候选与执行前复核使用同一份快照规则
    static func candidates(agents: [Agent]? = nil,
                           agentsDirectory: String = HOME + "/Library/LaunchAgents",
                           sizeOf: ((String) -> UInt64?)? = nil) -> [CleanupCandidate] {
        let snapshot = agents.map { AppLeftoverProbe.AgentDependencySnapshot(agents: $0, status: .complete) }
            ?? AppLeftoverProbe.agentDependencySnapshot(directory: agentsDirectory)
        guard snapshot.isComplete else { return [] }
        return candidates(completeAgents: snapshot.agents, sizeOf: sizeOf)
    }

    private static func candidates(completeAgents agents: [Agent],
                                   sizeOf: ((String) -> UInt64?)?) -> [CleanupCandidate] {
        // releases 目录 → 正在用的版本 → 用它的服务
        let active = activeReleases(agents: agents)
        var found: [(path: String, reason: String)] = []
        for (dir, users) in active.sorted(by: { $0.key < $1.key }) {
            // 应用包内部不碰：删掉旧版本会破坏代码签名，应用应自行更新
            guard !insideAppBundle(dir), let plan = plan(for: dir, users: users), !plan.stale.isEmpty else { continue }
            let running = users.sorted { $0.key < $1.key }
                .map { "\($0.value.sorted().joined(separator: "、")) 正在用 \($0.key)" }.joined(separator: "；")
            let reason = "后台服务 \(running)；回滚用的 \(plan.rollbacks.sorted().joined(separator: "、")) 保留，"
                + "更早的版本没有服务在用；可从废纸篓找回"
            found += plan.stale.map { (path: dir + "/" + $0.name, reason: reason) }
        }
        let sizes = sizeOf == nil ? BulkWalker().measureTargets(found.map(\.path)) : [:]
        return found.map { f in
            let name = (f.path as NSString).lastPathComponent
            let app = (((f.path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let item = ScanItem.trashTarget(path: f.path, name: name, size: sizeOf?(f.path) ?? sizes[f.path] ?? 0, rule: rule,
                                            evidence: "后台服务已经换到更新的版本，这是更早的发布副本", risk: .amber)
            return OwnerCachePolicy.ownedCandidate(item, title: "\(rule) · \(app) \(name)", role: "release")
                .retiered(.obsolete, reason: f.reason)
        }
    }

    /// 执行前复核：扫描之后服务又切回了这个版本就不删；切回上一个回滚版本后，这个版本可能变成新的回滚副本，
    /// 也要保留。nil = 可以执行
    static func executionBlocker(path: String, agents: [Agent]? = nil,
                                 agentsDirectory: String = HOME + "/Library/LaunchAgents") -> String? {
        let snapshot = agents.map { AppLeftoverProbe.AgentDependencySnapshot(agents: $0, status: .complete) }
            ?? AppLeftoverProbe.agentDependencySnapshot(directory: agentsDirectory)
        guard snapshot.isComplete else { return "启动项依赖无法完整读取，请重新扫描" }
        return executionBlocker(path: path, completeAgents: snapshot.agents)
    }

    private static func executionBlocker(path: String, completeAgents agents: [Agent]) -> String? {
        let target = canonical(path)
        for agent in agents {
            guard let (dir, release) = location(agent.path), dir + "/" + release == target else { continue }
            return "后台服务 \(agent.label) 现在用的是这个版本，请重新扫描"
        }
        guard let (dir, release) = location(target) else { return "发布目录状态已变化，请重新扫描" }
        if insideAppBundle(dir) { return "发布目录在应用包内，请使用应用自己的更新方式" }
        let active = activeReleases(agents: agents)
        guard let users = active[dir], let plan = plan(for: dir, users: users) else {
            return "后台服务指向的版本或发布目录状态已变化，请重新扫描"
        }
        guard plan.stale.contains(where: { $0.name == release }) else {
            return "这个版本现在需要保留（服务正在用、用于回滚或比服务版本更新），请重新扫描"
        }
        return nil
    }

    /// releases 目录 → 正在用的版本 → 用它的服务
    private static func activeReleases(agents: [Agent]) -> [String: [String: [String]]] {
        var active: [String: [String: [String]]] = [:]
        for agent in agents {
            guard let (dir, release) = location(agent.path), !insideAppBundle(dir) else { continue }
            active[dir, default: [:]][release, default: []].append(agent.label)
        }
        return active
    }

    private struct Plan {
        let rollbacks: Set<String>
        let stale: [Release]
    }

    /// 按当前服务状态重新计算：每个正在用的版本保留它之前最近的一个（回滚用），更早的才是可清的。
    /// 服务指向的版本不在时返回 nil（情况不明，整个目录都不动）
    private static func plan(for dir: String, users: [String: [String]]) -> Plan? {
        let releases = installed(in: dir)
        let current = releases.filter { users[$0.name] != nil }
        guard current.count == users.count, let newestActive = current.max(by: { $0.isOlder(than: $1) }) else { return nil }
        let idle = releases.filter { users[$0.name] == nil }
        let rollbacks = Set(current.compactMap { r in idle.filter { $0.isOlder(than: r) }.max { $0.isOlder(than: $1) }?.name })
        let stale = idle.filter { $0.isOlder(than: newestActive) && !rollbacks.contains($0.name) }
        return Plan(rollbacks: rollbacks, stale: stale)
    }

    /// 代码签名的应用包内部不碰
    private static func insideAppBundle(_ path: String) -> Bool {
        path.split(separator: "/").contains { String($0).lowercased().hasSuffix(".app") }
    }

    /// 服务的程序或工作目录落在哪个 releases 目录的哪个版本里；releases/current 这类符号链接先解析
    private static func location(_ path: String) -> (dir: String, release: String)? {
        let parts = (canonical(path) as NSString).pathComponents
        guard let i = parts.lastIndex(of: "releases"), i > 1, i + 1 < parts.count else { return nil }
        return (NSString.path(withComponents: Array(parts[...i])), parts[i + 1])
    }

    /// releases 目录下的各个版本：真目录（不含 current 这类符号链接和隐藏项）及其创建时间
    private static func installed(in dir: String) -> [Release] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { name -> Release? in
            var st = stat()
            guard !name.hasPrefix("."), lstat(dir + "/" + name, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            return Release(name: name, seconds: st.st_birthtimespec.tv_sec, nanoseconds: st.st_birthtimespec.tv_nsec)
        }
    }

    /// 解析符号链接；路径不存在时（服务指向已删除的版本）按原样逐级规范化
    private static func canonical(_ path: String) -> String {
        realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? GitRepositoryDiscovery.normalizedPath(path)
    }
}
