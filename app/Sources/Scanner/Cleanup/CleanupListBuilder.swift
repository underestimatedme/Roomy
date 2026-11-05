// SPDX-License-Identifier: GPL-3.0-only
// 规则扫描 + 工具探测 → 一张按大小排序的清单。

import Foundation

struct CleanupList {
    var candidates: [CleanupCandidate] = []
    var protectedCount = 0
    var protectedSize: UInt64 = 0

    var entries: [CleanupEntry] { candidates.map(\.entry) }
    func candidate(id: String) -> CleanupCandidate? { candidates.first { $0.entry.id == id } }
}

enum CleanupListBuilder {
    private static let toolOwnedRules = Set(RULES.filter(\.toolOwned).map(\.name))
    private static let projectRules: Set<String> = ["node_modules", "Python 虚拟环境", "Rust 构建产物", "项目缓存目录", "工作空间构建目录"]
    private static let oldVersionRules: Set<String> = ["Playwright 旧版本浏览器", "JetBrains 旧版本缓存与日志", "JetBrains 旧版本配置"]

    /// agentPaths：后台服务启动的程序和工作目录；清单里包含这些路径的项不默认勾选
    /// running：正在运行的进程；命中的规则条目锁定。nil = 不检查（读不到进程列表时由调用方用 RunningOwners.markUnverified 降级）
    /// owners：扫描时各工具报告的缓存位置；给了就先按归属定档（OwnerCachePolicy），nil = 沿用旧逻辑
    static func build(items: [ScanItem], probes: [CleanupCandidate],
                      agentPaths: [(label: String, path: String)] = [],
                      running: RunningOwners? = nil, owners: OwnerContext? = nil,
                      runner: CommandRunning = ProcessRunner(), tools: ToolLocator = ToolLocator()) -> CleanupList {
        var ownerContext = owners
        if ownerContext != nil, ownerContext?.running == nil { ownerContext?.running = running }
        var list = CleanupList()
        let worktreeRoots = probes.compactMap { c -> String? in
            if c.entry.selectable, case .worktreeRemove(let item, _, _, _) = c.action { return item.path }
            return nil
        }
        var merged: [CleanupCandidate] = []
        var artifacts: [ScanItem] = []
        for item in items {
            if toolOwnedRules.contains(item.rule) { continue }
            if item.risk == .lock {
                // 不能删的不再藏起来：进清单，没有动作、不可选，原因就是规则的依据。
                // 已经在"不能删"里列出，不再计入旧的受保护计数，免得界面显示两遍
                merged.append(fromRule(item).locked(item.evidence))
                continue
            }
            if worktreeRoots.contains(where: { item.path.hasPrefix($0 + "/") }) { continue }
            // 项目构建产物：按 .gitignore 定档（B / C），不再逐条目检查内容，也不再拆 npm 依赖子项。
            // 看规则本身是否可撤回，不看 item.undo：扫描时的内容核验已经把这些条目降成 undo = false，
            // 是否被忽略、是否有进程在用由 ProjectArtifactPolicy 自己判断，执行前再复核一次
            if ProjectArtifactPolicy.rules.contains(item.rule), let rule = RULES.first(where: { $0.name == item.rule }), rule.undo, !rule.protect {
                artifacts.append(item)
                continue
            }
            // 归属定档命中：不再做逐条目证据检查，也不再拆 npm 下载缓存 / Go 生成缓存等子项，免得和整块重复
            if let ownerContext, let owned = OwnerCachePolicy.candidates(for: item, context: ownerContext) {
                merged += owned
                continue
            }
            let checked = item.undo && item.cleanupEvidence == nil ? CleanupEvidence.applying(to: item) : item
            let candidate = fromRule(checked)
            if let blocker = running?.blocker(forRule: checked.rule) {
                merged.append(candidate.locked(blocker))
                continue
            }
            merged.append(candidate)
            if !candidate.entry.selectable { merged += CleanupEvidence.generatedChildren(of: checked).map(fromRule) }
        }
        merged += ProjectArtifactPolicy.candidates(for: artifacts, runner: runner, tools: tools, running: running)
        // 应用残留和规则覆盖同一处（或互相包含）时，以规则为准
        let rulePaths = items.map(\.path)
        merged += probes.filter { c in
            guard c.entry.source == "leftover", case .trash(let item)? = c.action else { return true }
            return !rulePaths.contains { $0 == item.path || $0.hasPrefix(item.path + "/") || item.path.hasPrefix($0 + "/") }
        }.map { c in
            // 探测器发现的 Gradle wrapper、自定义位置的 DerivedData 和规则里的同一个所有者：守护进程或 Xcode 在运行就锁定
            guard c.action != nil, let running else { return c }
            if RunningOwners.watchedRules.contains(c.entry.group), let blocker = running.blocker(forRule: c.entry.group) { return c.locked(blocker) }
            if let reason = RunningOwners.directoryUsers[c.entry.group], let path = c.targetPath, running.usesDirectory(path) {
                return c.locked(reason)
            }
            return c
        }
        var seen = Set<String>()
        for c in merged where (c.entry.size > 0 || c.action == nil) && seen.insert(c.entry.id).inserted {
            list.candidates.append(c)
        }
        list.candidates = list.candidates.map { c in
            guard let target = c.targetPath, c.entry.source != "launchagent",
                  let user = agentPaths.first(where: { $0.path == target || $0.path.hasPrefix(target + "/") }) else { return c }
            return c.requiringReview("被后台服务 \(user.label) 使用")
        }
        list.candidates = list.candidates.map(CleanupCategories.assign)
        list.candidates = list.candidates.map { c in
            guard c.entry.preferenceKey == nil, let key = CleanupPreferenceKeys.forCandidate(c) else { return c }
            var keyed = c
            keyed.entry.preferenceKey = key
            return keyed
        }
        list.candidates.sort { $0.entry.size > $1.entry.size }
        return list
    }

    static func fromRule(_ original: ScanItem) -> CleanupCandidate {
        let item = original.undo && original.cleanupEvidence == nil ? CleanupEvidence.applying(to: original) : original
        let leaf = (item.path as NSString).lastPathComponent
        let detail: String
        if item.name != leaf {
            detail = item.name                                   // prettyName 已经翻译过
        } else if projectRules.contains(item.rule) {
            detail = ((item.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        } else {
            detail = item.path.hasPrefix(HOME + "/") ? "~" + item.path.dropFirst(HOME.count) : item.path
        }
        let idle = item.mtimeDays.flatMap { Humanize.span(days: $0) }.map { " · \($0)没动过" } ?? ""
        var evidence = item.evidence
        if oldVersionRules.contains(item.rule) {
            let parent = (item.path as NSString).deletingLastPathComponent
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
            if let newer = newerVersion(of: leaf, among: siblings) { evidence += " · 新版本：\(newer)" }
        }
        // 会话、模型权重这类删了难找回的，目录 mtime 又只反映直接子项，不足以默认勾选
        let risk: Risk = item.rebuild == .costly && item.risk == .green ? .amber : item.risk
        let tier = CleanupTierPolicy.forRule(item)
        var candidate = CleanupCandidate(source: "rule", key: item.path, title: "\(item.rule) · \(detail)",
            size: item.size, evidence: evidence + idle, risk: risk,
            action: item.undo ? .trash(item: item) : nil, tier: tier.tier, tierReason: tier.reason)
        candidate.entry.path = item.path
        candidate.entry.category = CleanupCategories.category(forRule: item.rule)
        candidate.entry.group = item.rule
        candidate.entry.preferenceKey = CleanupPreferenceKeys.forRule(item)
        return candidate
    }
}

private final class CandidateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [CleanupCandidate] = []
    func append(_ items: [CleanupCandidate]) { lock.lock(); value += items; lock.unlock() }
    var items: [CleanupCandidate] { lock.lock(); defer { lock.unlock() }; return value }
}

enum ToolProbes {
    /// 代码目录 + AI 代理把 worktree 建在外面的地方（Codex 桌面版放在 ~/.codex/worktrees）
    static func worktreeRoots(codeRoots: [String], home: String = HOME) -> [String] {
        CodeRoots.scanRoots(codeRoots, home: home)
    }

    /// 发现阶段的占位大小：大到能通过各探测器的大小门槛，组装时一律换成真实值
    static let placeholder: UInt64 = 1 << 40

    /// 发现：跑各探测器，但不统计大小；需要大小的路径记下来，交给统一的那一遍遍历
    static func discover(runner: CommandRunning, tools: ToolLocator, roots: [String])
        -> (candidates: [CleanupCandidate], sizePaths: [String]) {
        final class Paths: @unchecked Sendable {
            let lock = NSLock(); var list: [String] = []
            func add(_ p: String) -> UInt64? { lock.lock(); list.append(p); lock.unlock(); return ToolProbes.placeholder }
        }
        let paths = Paths()
        let candidates = run(runner: runner, tools: tools, roots: CodeRoots.scanRoots(roots), sizeOf: { paths.add($0) })
        return (candidates, paths.list)
    }

    /// 组装：只给发现阶段要过大小的那些路径换上真实大小；拿不到或为 0 的丢掉，小于 1 MB 的应用残留也丢掉。
    /// measurement：同一次统计的详细结果（大小 + 完整性）。appcache 只有 complete 才直接复用字节，
    /// 不再二次遍历；incomplete 直接输出锁定 notice；没传或 unknown 时保留原来的独立复核。
    static func sized(_ candidates: [CleanupCandidate], sizePaths: Set<String>, index: SizeIndex,
                      measurement: MeasuredTargets? = nil,
                      verify: (String) -> UInt64? = { ApplicationSession.measure($0) }) -> [CleanupCandidate] {
        func notice(_ c: CleanupCandidate, path: String, evidence: String) -> CleanupCandidate {
            var notice = CleanupCandidate(source: "appcache", key: path, title: c.entry.title, size: 0,
                evidence: evidence, risk: .lock, action: nil)
            notice.entry.path = path; notice.entry.group = c.entry.group
            return notice
        }
        let incompleteNotice = "缓存内部存在无法读取的内容，统计不完整；保留并仅供查看，请检查读取权限后重新扫描"
        let missingNotice = "缓存大小未能完整读取，未计入可处理空间；请检查读取权限后重新扫描"
        return candidates.compactMap { c in
            // 锁定的条目没有动作，路径在 entry 上；漏掉它们占位大小就会泄漏出去
            guard let path = c.targetPath ?? c.entry.path, sizePaths.contains(path) else { return c }
            // 只有同一次统计（index 的 batch 与这份详细结果一致）且 proof 的大小与 index 里这个路径的值一致，
            // 才复用那次遍历的结论；batch 不同、或大小对不上，都退回独立复核，绝不把别处的 proof 贴到这份 index 上
            if c.entry.source == "appcache", let measurement, index.trusts(measurement),
               let proof = measurement.measurement(for: path), proof.size == index.targets[path] {
                switch proof.completeness {
                case .complete:
                    guard let size = proof.size, size > 0 else {
                        return proof.size == nil ? notice(c, path: path, evidence: missingNotice) : nil
                    }
                    return c.withSize(size)
                case .incomplete:
                    return notice(c, path: path, evidence: incompleteNotice)
                case .unknown:
                    break   // 本次没走到：退回独立复核，不拿未知当完整
                }
            }
            if c.entry.source == "appcache", verify(path) == nil {
                return notice(c, path: path, evidence: incompleteNotice)
            }
            guard let size = index.targets[path], size > 0 else {
                if c.entry.source == "appcache", index.targets[path] == nil {
                    return notice(c, path: path, evidence: missingNotice)
                }
                return nil
            }
            if c.entry.source == "leftover" || c.entry.source == InstalledAppDataProbe.source, size < 1_000_000 { return nil }
            return c.withSize(size)
        }
    }

    /// 测试与 CLI 用：发现 + 统计 + 组装
    static func runAll(runner: CommandRunning, tools: ToolLocator, roots: [String]) -> [CleanupCandidate] {
        let found = discover(runner: runner, tools: tools, roots: roots)
        let measurement = BulkWalker().measureTargetsDetailed(found.sizePaths)
        // index 和 proof 出自同一次遍历：batch 一起带上，sized 才敢直接复用字节
        let index = SizeIndex.from(measurement)
        return sized(found.candidates, sizePaths: Set(found.sizePaths), index: index, measurement: measurement)
    }

    private static func run(runner: CommandRunning, tools: ToolLocator, roots: [String],
                            sizeOf: @escaping (String) -> UInt64?) -> [CleanupCandidate] {
        let box = CandidateBox()
        let group = DispatchGroup()
        let jobs: [() -> [CleanupCandidate]] = [
            { SimulatorProbe.probe(runner: runner, tools: tools) },
            { OllamaProbe.probe(runner: runner, tools: tools) },
            { DockerProbe.probe(runner: runner, tools: tools) },
            { WorktreeProbe.probe(roots: worktreeRoots(codeRoots: roots), runner: runner, tools: tools, sizeOf: sizeOf) },
            { AppLeftoverProbe.probe(runner: runner, tools: tools, sizeOf: sizeOf) },
            { AppLeftoverProbe.failingAgentCandidates(directory: HOME + "/Library/LaunchAgents", runner: runner, tools: tools) },
            { ApplicationCacheProbe.probe(runner: runner, tools: tools, sizeOf: sizeOf) },
            { InstalledAppDataProbe.probe(runner: runner, tools: tools, sizeOf: sizeOf) },
            { GradleWrapperProbe.candidates(codeRoots: roots, sizeOf: sizeOf) },
            { SdkCopyProbe.candidates(searchRoots: [HOME + "/.local/share"] + roots, codeRoots: roots, sizeOf: sizeOf) },
            { DerivedDataCopyProbe.candidates(sizeOf: sizeOf) },
            { ReleaseHistoryProbe.candidates(sizeOf: sizeOf) },
            { OwnerCachePolicy.npxCandidate(sizeOf: sizeOf).map { [$0] } ?? [] },
        ]
        for job in jobs { DispatchQueue.global(qos: .userInitiated).async(group: group) { box.append(job()) } }
        group.wait()
        return box.items
    }
}
