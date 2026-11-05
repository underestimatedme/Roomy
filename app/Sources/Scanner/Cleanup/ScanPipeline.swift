// SPDX-License-Identifier: GPL-3.0-only
// 一次扫描 = 发现 → 统计 → 组装，之后清单就能用了。
// "看不懂的大目录"要把整个家目录走一遍（受磁盘元数据速度限制），所以放在清单之后单独跑；
// 统计时已经完整走过的子树（约六成的目录）记在 measured 里，这次遍历直接取用，省掉重复读一遍目录的开销。
// 具体耗时随机器、磁盘状态和目录数量变化，这里不记录某次样本的数字。

import Foundation

struct ScanPipelineResult {
    let items: [ScanItem]
    let probes: [CleanupCandidate]
    let sizeRoots: [String]
    let codeRoots: [String]
    let rootWarnings: [String]
    /// 扫描时各包管理器报告的缓存位置（OwnerContext.scopes）；工具缺失或查询失败的不在里面
    var ownerScopes: [ToolCleanCommand: String] = [:]
    /// 统计时完整走过的子树，留给紧接着的 folderWalk 取用
    var measured: MeasuredSubtrees? = nil
}

enum ScanPipeline {
    /// stage 回调只在调用线程上触发：(阶段, running|done, 本阶段用时秒数)
    static func run(runner: CommandRunning = ProcessRunner(), tools: ToolLocator = ToolLocator(),
                    stage: (_ stage: String, _ state: String, _ seconds: Double) -> Void) -> ScanPipelineResult {
        let configuration = CodeRoots.configuration(includeAutomaticCandidates: false)
        let codeRoots = CodeRoots.scanRoots(configuration.roots)
        let measurementRoots = [HOME] + codeRoots.filter { !$0.hasPrefix(HOME + "/") }
        let sizeRoots = measurementRoots.filter { path in !measurementRoots.contains { $0 != path && path.hasPrefix($0 + "/") } }
        let fastRoots = CodeRoots.splitProtected(codeRoots).fast

        // ① 发现 + ② 统计，两路重叠：规则展开只要一两秒，展开完立刻开始统计规则目标；
        //    与此同时工具探测在跑 git 等命令。探测完成后再统计探测器要的那些路径
        var t0 = Date()
        stage("discover", "running", 0)
        final class Found: @unchecked Sendable {
            var rules: [RuleTarget] = []
            var ruleSizes: [String: UInt64] = [:]
            var probes: (candidates: [CleanupCandidate], sizePaths: [String]) = ([], [])
            var ownerScopes: [ToolCleanCommand: String] = [:]
        }
        let found = Found()
        let measured = MeasuredSubtrees()
        let rulesDone = DispatchGroup(), probesDone = DispatchGroup(), ownersDone = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: rulesDone) {
            found.rules = planRuleTargets(codeRoots: fastRoots, protected: false)   // 受保护文件夹的放到清单之后（会弹授权框）
            found.ruleSizes = BulkWalker().measureTargets(found.rules.map(\.path), record: measured)
        }
        DispatchQueue.global(qos: .userInitiated).async(group: probesDone) {
            found.probes = ToolProbes.discover(runner: runner, tools: tools, roots: fastRoots)
        }
        // 问各包管理器"缓存在哪"：与发现、统计并行，每个查询 10 秒超时，组装前才等它
        DispatchQueue.global(qos: .userInitiated).async(group: ownersDone) {
            found.ownerScopes = OwnerContext.capture(runner: runner, tools: tools).scopes
        }
        probesDone.wait()
        stage("discover", "done", Date().timeIntervalSince(t0))

        t0 = Date()
        stage("measure", "running", 0)
        // 与规则那一路互不读写：探测器这些路径的详细结果（大小 + 完整性）单独成一批
        let probeMeasurement = BulkWalker().measureTargetsDetailed(found.probes.sizePaths, record: measured)
        rulesDone.wait()
        var index = SizeIndex()
        index.targets = found.ruleSizes.merging(probeMeasurement.sizes) { a, _ in a }
        // 只有 probe 那批的大小带着同批 proof；规则那一路的大小没有 proof，sized 也不会去认领
        index.measurementBatch = probeMeasurement.batch
        stage("measure", "done", Date().timeIntervalSince(t0))

        // ③ 组装
        t0 = Date()
        stage("assemble", "running", 0)
        let items = buildRuleItems(found.rules) { index.targets[$0] }
        let probes = ToolProbes.sized(found.probes.candidates, sizePaths: Set(found.probes.sizePaths),
                                      index: index, measurement: probeMeasurement)
        ownersDone.wait()
        stage("assemble", "done", Date().timeIntervalSince(t0))
        return ScanPipelineResult(items: items, probes: probes, sizeRoots: sizeRoots,
            codeRoots: codeRoots, rootWarnings: configuration.warnings, ownerScopes: found.ownerScopes,
            measured: measured)
    }

    /// 受保护文件夹里的规则条目（下载里的安装包、文稿里的模型权重）：可能卡在授权框上，所以在清单之后单独做
    /// 也包括落在这些文件夹里的代码目录（codescan 规则和 worktree）
    static func protectedResults(runner: CommandRunning = ProcessRunner(), tools: ToolLocator = ToolLocator())
        -> (items: [ScanItem], probes: [CleanupCandidate]) {
        let guardedRoots = CodeRoots.splitProtected(ALL_CODE_ROOTS).protected
        var targets = planRuleTargets(protected: true)
        if !guardedRoots.isEmpty {
            targets += planRuleTargets(codeRoots: guardedRoots, protected: false)
                .filter { t in guardedRoots.contains { t.path.hasPrefix($0 + "/") } }
        }
        let sizes = BulkWalker().measureTargets(targets.map(\.path))
        let probes = guardedRoots.isEmpty ? [] : WorktreeProbe.probe(roots: guardedRoots, runner: runner, tools: tools)
        return (buildRuleItems(targets) { sizes[$0] }, probes)
    }

    /// 报告里"空间去向"要看的系统区域（`du -x`：不跨挂载点）；家目录和代码根另算，已在 sizeRoots 里
    static func systemAreaRoots() -> [String] {
        ["/Applications", "/opt/homebrew", "/Library", "/private/var"]
    }

    /// 完整遍历：6 层以内、不小于 threshold（默认 200 MB）的目录大小，跳过隐私保护目录。
    /// 给"按文件夹看"、空间去向和空间变化用。
    /// 增长对比的一级子目录不受 threshold 截断；一级文件不单独进 dirs，但根总量包含它们——
    /// 增长看的是目录，总量仍是实际占用。
    /// 系统区域根跟着同一次遍历一起走（不另起一轮）；rootTotals 是每个根的总占用（读不了的根不在里面），unreadable 是没读成的路径，给 SpaceOverview 用。
    /// reuse：同一次扫描里统计清单时已经走过的子树（ScanPipelineResult.measured），不再读第二遍
    /// shouldContinue：取消用；complete 说明这次遍历是否真的跑到了结尾（被取消的是 false，结果不能当完整报告）
    static func folderWalk(roots: [String], systemRoots: [String] = systemAreaRoots(), threshold: UInt64 = 200_000_000,
                           reuse: MeasuredSubtrees? = nil, shouldContinue: @escaping () -> Bool = { true })
        -> (dirs: [String: UInt64], rootTotals: [String: UInt64], unreadable: [String], complete: Bool) {
        var all = roots
        for r in systemRoots where !all.contains(r) { all.append(r) }
        let walker = BulkWalker()
        let index = walker.measure(roots: all, targets: [], dirDepth: 6, dirThreshold: threshold,
                                   skip: UnexplainedSpace.protectedSubtrees(home: HOME), reuse: reuse,
                                   shouldContinue: shouldContinue, includeAllRootChildren: true)
        // complete 只说"这次遍历跑到了结尾、没有中途取消"，不代表整个卷都读得到：
        // 读不了的路径（含深层缺口所属的并行任务）照旧记在 unreadable 里，页面仍要标"已统计部分 / 未知"；
        // 空间增长记录前还要用 SpaceGrowthStore.coverageComplete 再拒绝一次。
        // 回调后来恢复成 true 也不能把中途取消过的遍历称成完整，所以看 walker.cancelled。
        return (index.dirs, index.roots, index.unreadable, walker.cancelled == 0 && shouldContinue())
    }

    /// 只含传入的根里的目录大小（不带系统区域）
    static func folderSizes(roots: [String]) -> [String: UInt64] {
        folderWalk(roots: roots, systemRoots: []).dirs
    }
}

/// 首屏缓存：只存界面要显示的数据，不存任何可执行的动作
enum CleanupCache {
    static let version = 1

    /// scannedAt 只代表这份清单生成的时间。深度统计可能晚很久才完成，报告字段更新时不能把旧清单的
    /// scannedAt 刷成统计完成时间；缺失或无效时才生成，已有有效时间原样保留。
    static func validScannedAt(_ payload: [String: Any]) -> String? {
        guard let text = payload["scannedAt"] as? String,
              ISO8601DateFormatter().date(from: text) != nil else { return nil }
        return text
    }

    static func stamped(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var p = payload
        p["version"] = version
        if validScannedAt(p) == nil { p["scannedAt"] = ISO8601DateFormatter().string(from: now) }
        return p
    }

    static func save(_ payload: [String: Any], to url: URL) {
        let p = stamped(payload)
        guard JSONSerialization.isValidJSONObject(p), let data = try? JSONSerialization.data(withJSONObject: p) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == version else { return nil }
        return object
    }
}
