// SPDX-License-Identifier: MPL-2.0
// 按"谁管这块缓存"定档：包管理器自己管的整块缓存交给官方命令清空（A 档），
// Xcode / Gradle 的标准缓存进废纸篓（A 档，所有者在运行就进"不能删"）。
// 工具找不到或说不清缓存在哪，就降到 C、只给废纸篓。

import Darwin
import Foundation

struct OwnerContext {
    /// 扫描时各工具报告的缓存位置；工具缺失或查询失败的命令不在里面
    var scopes: [ToolCleanCommand: String]
    /// 正在运行的进程；nil = 读不到进程列表
    var running: RunningOwners?
    var now: Date

    /// 并发问每个工具"缓存在哪"（各自 10 秒超时，见 ToolCleanScope.resolve）。
    /// 工具不存在的直接跳过；running 不在这里取，由调用方用它已有的 RunningOwners.capture 结果填上，避免再跑一次 ps
    static func capture(runner: CommandRunning, tools: ToolLocator) -> OwnerContext {
        let commands = ToolCleanCommand.allCases.filter { $0.scopeQuery != nil && tools.path(for: $0.tool) != nil }
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var scopes: [ToolCleanCommand: String] = [:]
            func set(_ c: ToolCleanCommand, _ s: String) { lock.lock(); scopes[c] = s; lock.unlock() }
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: commands.count) { i in
            if let scope = ToolCleanScope.resolve(commands[i], runner: runner, tools: tools) { box.set(commands[i], scope) }
        }
        return OwnerContext(scopes: box.scopes, running: nil, now: Date())
    }
}

enum OwnerCachePolicy {
    /// 归属定档产出的废纸篓项带这个证据类型；执行前由 executionBlocker 按归属复核，而不是逐条目内容校验
    static let evidenceKind = "ownerPolicy"
    private static let goBuildMarker = "This directory holds cached build artifacts from the Go build system."
    private static let goBuildFiles: Set<String> = ["README", "trim.txt", "testexpire.txt"]
    private static let installerMinimumDays = 7

    /// 规则条目由哪个官方命令整体清理；nil = 不是命令类
    static func command(for item: ScanItem) -> ToolCleanCommand? {
        switch item.rule {
        case "Go 构建缓存": return .goBuildCache
        case "Go 模块缓存": return .goModCache
        case "uv 缓存": return .uvCache
        case "包管理器缓存":
            if item.path.hasSuffix("/.npm/_cacache") { return .npmCache }
            if item.path.hasSuffix("/Library/Caches/pip") { return .pipCache }
            if item.path.hasSuffix("/Library/pnpm/store") { return .pnpmStorePrune }
            if item.path.hasSuffix("/Library/Caches/Homebrew") { return .brewCleanup }
            return nil
        default: return nil
        }
    }

    /// nil = 不归它管，沿用原逻辑
    static func candidates(for item: ScanItem, context: OwnerContext) -> [CleanupCandidate]? {
        guard item.risk != .lock, let rule = RULES.first(where: { $0.name == item.rule }), rule.undo, !rule.protect else { return nil }
        if let c = command(for: item) { return [ownedByTool(item, c, context)] }
        switch item.rule {
        case "Xcode DerivedData", "XcodeBuildMCP 工作区":
            return [whileOwnerIdle(item, context, reason: "Xcode 构建产物，下次构建会重新生成；可从废纸篓找回")]
        case "Gradle 缓存":
            return [whileOwnerIdle(item, context, reason: "Gradle 缓存，下次构建会重新下载或生成；可从废纸篓找回")]
        case "安装临时目录":
            return [installerTemp(item, context)]
        case "项目缓存目录":
            return projectCache(item)
        case "pnpm 元数据缓存":
            let candidate = trash(item).retiered(.obsolete, reason: "pnpm 的包元数据缓存，下次安装时自动重新获取；可从废纸篓找回")
            guard let running = context.running else { return [candidate.requiringReview(RunningOwners.unverifiedReason)] }
            return [running.blocker(forTool: .pnpmStorePrune).map(candidate.locked) ?? candidate]
        case "Python 字节码缓存":
            return [trash(item).retiered(.obsolete, reason: "系统自带 Python 生成的字节码，下次运行时重新生成；可从废纸篓找回")]
        case "Maven 仓库":
            return [trash(item).retiered(.review, reason: "私服或本地安装的依赖不一定能重新下载；请核实后再清")]
        case "Playwright 旧版本浏览器":
            return [trash(item).retiered(.rebuildable, reason: "已有更新的版本；老项目需要时 playwright install 会重新下载")]
        default:
            return nil
        }
    }

    // MARK: - 各类

    private static func ownedByTool(_ item: ScanItem, _ c: ToolCleanCommand, _ context: OwnerContext) -> CleanupCandidate {
        let tool = c.tool.rawValue
        // 工具在运行：整块缓存（无论整体清理还是回退到废纸篓）都进"不能删"；读不到进程列表：保持 C 并安全锁定
        func fallback(_ reason: String) -> CleanupCandidate {
            let row = trash(item).retiered(.review, reason: reason)
            guard let running = context.running else { return row.holdingForSafety() }
            return running.blocker(forTool: c).map(row.locked) ?? row
        }
        guard let scope = context.scopes[c] else {
            return fallback("找不到 \(tool) 或无法确认其缓存位置；可移到废纸篓")
        }
        let want = ToolCleanScope.canonical(item.path), got = ToolCleanScope.canonical(scope)
        // pnpm 报告的 store 位置带版本子目录：在这个目录之内就算一致（与执行前复核同一口径）
        let matches = c == .pnpmStorePrune ? (got == want || got.hasPrefix(want + "/")) : got == want
        guard matches else {
            return fallback("\(tool) 报告的缓存位置是 \(scope)，与此目录不一致；可移到废纸篓")
        }
        let base = CleanupListBuilder.fromRule(ownerItem(item, role: "tool"))
        // brew cleanup 除了下载缓存还会删除已安装软件包的旧版本：标题、依据和档位说明都要讲清楚
        let brew = c == .brewCleanup
        var candidate = CleanupCandidate(source: "rule", key: item.path,
            title: brew ? item.rule + " · Homebrew 旧版本软件包与下载缓存" : base.entry.title, size: item.size,
            evidence: brew ? "由 brew 管理，下载缓存扫描时 \(bytes(item.size))；brew cleanup 还会删除已安装软件包的旧版本"
                           : "由 \(tool) 管理，扫描时 \(bytes(item.size))",
            risk: base.entry.risk, action: .toolClean(c, scope: item.path), estimateIsApprox: !c.exactSize,
            tier: .obsolete, tierReason: brew ? "brew cleanup 会删除旧版本软件包和下载缓存，大小以工具实际回收为准"
                                              : "整块由 \(c.label) 清空，工具会按需重新下载")
        candidate.entry.category = base.entry.category
        candidate.entry.group = base.entry.group
        // The tool-managed row is keyed by the tool command (not by the trash-style rule key of its fallback)
        candidate.entry.preferenceKey = CleanupPreferenceKeys.forCandidate(candidate)
        guard let running = context.running else { return candidate.requiringReview(RunningOwners.unverifiedReason) }
        if let blocker = running.blocker(forTool: c) { return candidate.locked(blocker) }
        return candidate
    }

    private static func whileOwnerIdle(_ item: ScanItem, _ context: OwnerContext, reason: String) -> CleanupCandidate {
        let candidate = trash(item).retiered(.obsolete, reason: reason)
        guard let running = context.running else { return candidate.requiringReview(RunningOwners.unverifiedReason) }
        if let blocker = running.blocker(forRule: item.rule) { return candidate.locked(blocker) }
        return candidate
    }

    private static func installerTemp(_ item: ScanItem, _ context: OwnerContext) -> CleanupCandidate {
        let candidate = trash(item)
        guard let running = context.running else {
            return candidate.retiered(.review, reason: RunningOwners.unverifiedReason).holdingForSafety()
        }
        if running.commands.contains(where: { $0.contains(item.path) }) {
            return candidate.retiered(.review, reason: "有进程正在使用这个目录，可能仍在安装").holdingForSafety()
        }
        guard let age = newestFileAge(in: item.path, now: context.now) else {
            return candidate.retiered(.review, reason: "目录内容太多或无法完整读取，不能确认最近的修改时间")
        }
        guard age >= installerMinimumDays else {
            return candidate.retiered(.review, reason: "目录里最新的文件 \(age) 天前修改过，可能仍在安装")
        }
        guard hasInstalledSibling(item.path) else {
            return candidate.retiered(.review, reason: "旁边没有找到正式安装的目录，这个临时目录可能是唯一的副本；请核实后再清")
        }
        return candidate.retiered(.obsolete, reason: "安装中途留下的临时目录，最新文件已 \(age) 天未修改，没有进程在使用，旁边有正式安装的目录；可从废纸篓找回")
    }

    /// 同一父目录里有名字不含 "-install-" 的子目录：正式安装的版本就在旁边
    static func hasInstalledSibling(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent, me = (path as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return false }
        return names.contains { $0 != me && !$0.hasPrefix(".") && !$0.contains("-install-") && isDirectory(parent + "/" + $0) }
    }

    /// ~/.npm/_npx：npx 临时下载的工具，与 _cacache 的官方清理命令是两回事。目录存在才有
    static func npxCandidate(home: String = HOME, sizeOf: ((String) -> UInt64?)? = nil) -> CleanupCandidate? {
        let path = home + "/.npm/_npx"
        guard isDirectory(path) else { return nil }
        let size = sizeOf?(path) ?? BulkWalker().measureTargets([path])[path] ?? 0
        let reason = "npx 临时下载的工具，需要时会重新下载"
        let item = ScanItem.trashTarget(path: path, name: "_npx", size: size, rule: npxRule, evidence: reason, risk: .amber)
        let shown = path.hasPrefix(HOME + "/") ? "~" + path.dropFirst(HOME.count) : path
        return ownedCandidate(item, title: npxRule + " · " + shown, role: "npx").retiered(.obsolete, reason: reason)
    }

    static let npxRule = "npm 临时工具缓存"

    /// 项目里被 gitignore 的 .cache：认得出的 Go 构建 / 模块缓存单独进 A，其余内容留在 C。
    /// 一条废纸篓动作只能移一个路径，所以"其余内容"按直接子项各一条（同组显示）；没有 Go 子项时整个 .cache 一条 C
    private static func projectCache(_ item: ScanItem) -> [CleanupCandidate] {
        let other = "项目缓存目录中的内容尚未确认归属；请核实后再清"
        let project = ((item.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: item.path) else {
            return [trash(item).retiered(.review, reason: other)]
        }
        var owned: [(path: String, role: String)] = [], rest: [String] = []
        for name in names.sorted() {
            let path = item.path + "/" + name
            if let role = goRole(path) { owned.append((path, role)) } else { rest.append(path) }
        }
        guard !owned.isEmpty else { return [trash(item).retiered(.review, reason: other)] }
        let sizes = BulkWalker().measureTargets(owned.map(\.path) + rest)
        func child(_ path: String, role: String) -> CleanupCandidate {
            let leaf = (path as NSString).lastPathComponent
            return trash(item, path: path, name: project + " · " + leaf, size: sizes[path] ?? 0, role: role)
        }
        return owned.map { o in
            child(o.path, role: o.role).retiered(.obsolete, reason: o.role == "go-build"
                ? "项目里的 Go 构建缓存，下次构建会重新生成；可从废纸篓找回"
                : "项目里的 Go 模块缓存，需要时 go 会重新下载；可从废纸篓找回")
        } + rest.map { child($0, role: "plain").retiered(.review, reason: other) }
    }

    // MARK: - 执行前复核

    /// 归属定档的废纸篓项在执行前再查一次：所有者是否在运行、安装目录是否又有改动、Go 缓存布局是否还在。nil = 可以执行
    static func executionBlocker(_ item: ScanItem, runner: CommandRunning = ProcessRunner(),
                                 tools: ToolLocator = ToolLocator(),
                                 codeRoots: [String] = CodeRoots.splitProtected(ALL_CODE_ROOTS).fast,
                                 home: String = HOME,
                                 androidHome: String? = SdkCopyProbe.currentAndroidHome()) -> String? {
        guard let proof = item.cleanupEvidence, proof.version == 1, proof.kind == evidenceKind,
              let separator = proof.fingerprint.firstIndex(of: ":"),
              proof.fingerprint[proof.fingerprint.index(after: separator)...] == item.path else {
            return "缺少已核验的清理证据，请重新扫描并核实"
        }
        let role = String(proof.fingerprint[..<separator])
        // 包管理器管理的整块缓存回退成废纸篓项时，执行前同样复核工具是否在运行
        if let c = command(for: item), let blocker = RunningOwners.executionBlocker(forTool: c, runner: runner, tools: tools) {
            return blocker
        }
        if RunningOwners.watchedRules.contains(item.rule) {
            guard let running = RunningOwners.capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
            return running.blocker(forRule: item.rule)
        }
        switch (item.rule, role) {
        case ("安装临时目录", _):
            guard let running = RunningOwners.capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
            if running.commands.contains(where: { $0.contains(item.path) }) { return "有进程正在使用这个目录，请稍后重新扫描" }
            guard let age = newestFileAge(in: item.path), age >= installerMinimumDays else {
                return "安装目录在扫描后有新的改动，请重新扫描"
            }
            return hasInstalledSibling(item.path) ? nil : "旁边正式安装的目录已不存在，请重新扫描"
        case (npxRule, _):
            guard let running = RunningOwners.capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
            return running.usesDirectory(item.path) ? RunningOwners.npxInUse : nil
        case (SdkCopyProbe.group, _):
            guard let running = RunningOwners.capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
            if running.usesDirectory(item.path) { return SdkCopyProbe.inUse }
            return SdkCopyProbe.executionBlocker(path: item.path, evidence: proof.detail,
                codeRoots: codeRoots, home: home, androidHome: androidHome)
        case (ReleaseHistoryProbe.rule, _):
            guard let running = RunningOwners.capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
            if running.usesDirectory(item.path) { return ReleaseHistoryProbe.inUse }
            return ReleaseHistoryProbe.executionBlocker(path: item.path)
        case ("pnpm 元数据缓存", _):
            return RunningOwners.executionBlocker(forTool: .pnpmStorePrune, runner: runner, tools: tools)
        case _ where ProjectArtifactPolicy.rules.contains(item.rule):
            return ProjectArtifactPolicy.executionBlocker(item, runner: runner, tools: tools)
        case ("项目缓存目录", "go-build"), ("项目缓存目录", "go-mod"):
            return goRole(item.path) == role ? nil : "目录已不再是 Go 缓存的布局，请重新扫描"
        default:
            return nil
        }
    }

    // MARK: - 工具函数

    /// 条目上限与时间预算：本机的安装临时目录有近 3 万个文件，上限要留足；预算让大目录的遍历仍有界
    static let newestFileAgeLimit = 200_000
    static let newestFileAgeBudget: TimeInterval = 5

    /// 目录里最新文件距今多少天（不跟随符号链接）；条目超过 limit、超过时间预算、读不到或不是目录时返回 nil（按"不确定"处理）
    static func newestFileAge(in path: String, limit: Int = newestFileAgeLimit, budget: TimeInterval = newestFileAgeBudget,
                              now: Date = Date(), clock: () -> Date = Date.init) -> Int? {
        var root = stat()
        guard lstat(path, &root) == 0, (root.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let deadline = clock().addingTimeInterval(budget)
        var newest: Int? = nil, count = 0, stack = [path]
        while let dir = stack.popLast() {
            guard clock() < deadline, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
            for name in names {
                count += 1
                // 每 256 个条目看一次时钟，单个大目录也不会越过预算太久
                guard count <= limit, count % 256 != 0 || clock() < deadline else { return nil }
                let child = dir + "/" + name
                var st = stat()
                guard lstat(child, &st) == 0 else { return nil }
                if (st.st_mode & S_IFMT) == S_IFDIR { stack.append(child); continue }
                newest = max(newest ?? Int.min, Int(st.st_mtimespec.tv_sec))
            }
        }
        let reference = newest ?? Int(root.st_mtimespec.tv_sec)
        return max(0, Int((now.timeIntervalSince1970 - Double(reference)) / 86_400))
    }

    /// "go-build" = 名为 go-build 且是 Go 构建缓存布局；"go-mod" = 名为 go-mod/gomod 且含 cache/download；否则 nil
    private static func goRole(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        if name == "go-build", isDirectory(path), GoBuildCacheEvidence.hasCacheLayout(path) { return "go-build" }
        if name == "go-mod" || name == "gomod", isDirectory(path), isDirectory(path + "/cache"),
           isDirectory(path + "/cache/download") { return "go-mod" }
        return nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// 动作里的 ScanItem：可撤回、带归属证据（执行前按归属复核），身份沿用扫描时记录的
    private static func ownerItem(_ item: ScanItem, path: String? = nil, name: String? = nil,
                                  size: UInt64? = nil, role: String, evidence: String? = nil,
                                  detail: String? = nil) -> ScanItem {
        let target = path ?? item.path
        let rule = RULES.first { $0.name == item.rule }
        let same = target == item.path
        return ScanItem(name: name ?? item.name, path: target, size: size ?? item.size,
            atimeDays: same ? item.atimeDays : nil, mtimeDays: same ? item.mtimeDays : nil, usedDays: same ? item.usedDays : nil,
            rule: item.rule, evidence: evidence ?? rule?.evidence ?? item.evidence, risk: item.risk, gentle: item.gentle,
            hard: "移到废纸篓", undo: true, note: rule?.note ?? item.note, rebuild: rule?.rebuild ?? item.rebuild,
            identity: same ? (item.identity ?? CleanupIdentity.capture(path: target)) : CleanupIdentity.capture(path: target),
            reclaimEstimate: same ? item.reclaimEstimate : nil,
            cleanupEvidence: CleanupEvidenceSnapshot(version: 1, fingerprint: role + ":" + target,
                kind: evidenceKind, detail: detail))
    }

    /// 探测器自己发现的目录（Gradle wrapper、SDK 副本、npx）：同样带归属证据，执行前走同一道复核
    static func ownedCandidate(_ item: ScanItem, title: String, role: String, detail: String? = nil) -> CleanupCandidate {
        let owned = ownerItem(item, role: role, detail: detail)
        var candidate = CleanupCandidate(source: "rule", key: item.path, title: title, size: owned.size,
            evidence: owned.evidence, risk: owned.risk, action: .trash(item: owned))
        candidate.entry.path = item.path
        candidate.entry.group = item.rule
        candidate.entry.category = CleanupCategories.category(forRule: item.rule)
        return candidate
    }

    /// evidence：给了就替换规则自带的依据（例如项目构建产物用策略自己的判断说明）
    static func trash(_ item: ScanItem, path: String? = nil, name: String? = nil,
                              size: UInt64? = nil, role: String = "plain", evidence: String? = nil) -> CleanupCandidate {
        CleanupListBuilder.fromRule(ownerItem(item, path: path, name: name, size: size, role: role, evidence: evidence))
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
