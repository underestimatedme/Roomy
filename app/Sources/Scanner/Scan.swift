// SPDX-License-Identifier: MPL-2.0
// 跑规则库，产出与 scanner/roomy-scan.py 相同结构的报告。
// 实测结论（16GB / maxvnodes 250k / 600k 条目）：整套规则 10.5s，同机 du 单个 ~/Library/Developer 要 17.5s，
// find 同批根 32s+。vnode 缓存装不下这棵树，每次都在读盘，这是内核下限不是代码问题。
// "秒开"靠渐进上屏 + 缓存上次结果，不靠再优化遍历。

import Foundation

enum Risk: String, Codable { case green, amber, lock }

struct ScanItem: Codable {
    let name: String
    let path: String
    let size: UInt64
    let atimeDays: Int?
    let mtimeDays: Int?
    var usedDays: Int? = nil
    let rule: String
    let evidence: String
    let risk: Risk
    let gentle: String?
    let hard: String
    let undo: Bool
    let note: String
    let rebuild: Rebuild
    var identity: CleanupIdentity? = nil
    var reclaimEstimate: ReclaimEstimate? = nil
    var cleanupEvidence: CleanupEvidenceSnapshot? = nil
}

struct ScanLayer: Codable {
    let key: Layer
    let name: String
    let moat: Bool
    var items: [ScanItem]
    var size: UInt64
}

struct DiskTreeNode: Codable, Equatable {
    let entryID: EntryID?
    let name: String
    let path: String
    let allocatedBytes: UInt64
    let tags: [ContentTag]
    let children: [DiskTreeNode]
    let synthetic: Bool

    static let empty = DiskTreeNode(entryID: nil, name: "", path: "",
        allocatedBytes: 0, tags: [], children: [], synthetic: true)
}

struct SpaceLedger: Codable, Equatable {
    let visible: UInt64
    let inaccessible: UInt64
    let systemAndShared: UInt64
    let unexplained: UInt64

    static let zero = SpaceLedger(visible: 0, inaccessible: 0,
        systemAndShared: 0, unexplained: 0)
}

enum ScanTrust: String, Codable { case trusted, partial, needsAttention }

struct ScanReport: Codable {
    struct Machine: Codable { let diskTotal: UInt64; let diskFree: UInt64; let diskUsed: UInt64 }
    struct Timing: Codable { let rulesSec: Double }
    struct Stats: Codable { let files: Int; let dirs: Int; let denied: Int }
    struct Summary: Codable {
        let total: UInt64, green: UInt64, amber: UInt64, locked: UInt64, reclaimable: UInt64
        let verdict: Bool
    }
    var version = 1
    var generation: ScanGeneration = 0
    var sequence: UInt64 = 0
    var complete: Bool = true
    var diskTree: DiskTreeNode = .empty
    var ledger: SpaceLedger = .zero
    var trust: ScanTrust = .partial
    let scannedAt: String
    let machine: Machine
    let timing: Timing
    let stats: Stats
    let summary: Summary
    let layers: [ScanLayer]

    init(
        version: Int = 1,
        generation: ScanGeneration = 0,
        sequence: UInt64 = 0,
        complete: Bool = true,
        diskTree: DiskTreeNode = .empty,
        ledger: SpaceLedger = .zero,
        trust: ScanTrust = .partial,
        scannedAt: String,
        machine: Machine,
        timing: Timing,
        stats: Stats,
        summary: Summary,
        layers: [ScanLayer]
    ) {
        self.version = version
        self.generation = generation
        self.sequence = sequence
        self.complete = complete
        self.diskTree = diskTree
        self.ledger = ledger
        self.trust = trust
        self.scannedAt = scannedAt
        self.machine = machine
        self.timing = timing
        self.stats = stats
        self.summary = summary
        self.layers = layers
    }

    private enum CodingKeys: String, CodingKey {
        case version, generation, sequence, complete, diskTree, ledger, trust
        case scannedAt, machine, timing, stats, summary, layers
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        generation = try values.decodeIfPresent(ScanGeneration.self, forKey: .generation) ?? 0
        sequence = try values.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        complete = try values.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        diskTree = try values.decodeIfPresent(DiskTreeNode.self, forKey: .diskTree) ?? .empty
        ledger = try values.decodeIfPresent(SpaceLedger.self, forKey: .ledger) ?? .zero
        trust = try values.decodeIfPresent(ScanTrust.self, forKey: .trust) ?? .partial
        scannedAt = try values.decode(String.self, forKey: .scannedAt)
        machine = try values.decode(Machine.self, forKey: .machine)
        timing = try values.decode(Timing.self, forKey: .timing)
        stats = try values.decode(Stats.self, forKey: .stats)
        summary = try values.decode(Summary.self, forKey: .summary)
        layers = try values.decode([ScanLayer].self, forKey: .layers)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(generation, forKey: .generation)
        try values.encode(sequence, forKey: .sequence)
        try values.encode(complete, forKey: .complete)
        try values.encode(diskTree, forKey: .diskTree)
        try values.encode(ledger, forKey: .ledger)
        try values.encode(trust, forKey: .trust)
        try values.encode(scannedAt, forKey: .scannedAt)
        try values.encode(machine, forKey: .machine)
        try values.encode(timing, forKey: .timing)
        try values.encode(stats, forKey: .stats)
        try values.encode(summary, forKey: .summary)
        try values.encode(layers, forKey: .layers)
    }
}

/// 规划原则 1：翻译成人话，不展示目录。UUID、哈希后缀、编码过的路径都不该给人看。
func prettyName(rule: Rule, path: String, leaf: String) -> String {
    switch rule.name {
    case "iOS 模拟器设备", "XCTest 设备克隆":
        // Devices/<UUID>/device.plist 里有设备名和运行时
        if let d = NSDictionary(contentsOfFile: path + "/device.plist") {
            let name = d["name"] as? String ?? leaf
            var rt = ""
            if let r = d["runtime"] as? String, let tail = r.split(separator: ".").last {
                // com.apple.CoreSimulator.SimRuntime.iOS-17-2 → iOS 17.2
                let parts = tail.split(separator: "-")
                if parts.count >= 2 { rt = " · " + parts[0] + " " + parts.dropFirst().joined(separator: ".") }
            }
            return name + rt
        }
    case "Xcode DerivedData":
        // Roomy-fkjshdqabcdefghijklmnopqrstu → Roomy
        if let dash = leaf.lastIndex(of: "-"), leaf.distance(from: dash, to: leaf.endIndex) == 29 {
            return String(leaf[..<dash])
        }
    case "Claude Code 会话":
        // -Users-joey-code-roomy → ~/code/roomy
        if leaf.hasPrefix("-") {
            let p = leaf.replacingOccurrences(of: "-", with: "/")
            return p.hasPrefix(HOME) ? "~" + p.dropFirst(HOME.count) : p
        }
    case "Cursor 工作区", "VS Code 工作区":
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path + "/workspace.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let f = j["folder"] as? String, let u = URL(string: f) {
            let p = u.path
            return p.hasPrefix(HOME) ? "~" + p.dropFirst(HOME.count) : p
        }
    default: break
    }
    return leaf
}

/// 风险 = 可撤销性 × 重建代价 × 时间
func riskOf(_ rule: Rule, mtimeDays: Int?, usedDays: Int?) -> Risk {
    if rule.protect { return .lock }
    if !rule.precheck { return .amber }
    if !rule.undo { return .amber }
    if rule.rebuild == .free { return .green }
    let signals = [mtimeDays, usedDays].compactMap { $0 }
    guard let maxSig = signals.max() else { return .amber }      // 一个有效信号都没有 → 不敢默认勾
    if rule.rebuild == .cheap && maxSig >= 14 { return .green }
    if maxSig >= 90 { return .green }
    return .amber
}

func diskUsage() -> (UInt64, UInt64) {
    var s = statfs()
    guard statfs("/", &s) == 0 else { return (0, 0) }
    let bs = UInt64(s.f_bsize)
    return (UInt64(s.f_blocks) * bs, UInt64(s.f_bavail) * bs)
}

/// Fill scan results concurrently without force-unwrapping an empty buffer.
/// Each worker group gets its own attribute buffer so filesystem metadata storage is reused safely.
func parallelSizes(count: Int, threads: Int,
                   work: (Int, AttrBuffer) -> UInt64?) -> [UInt64?] {
    guard count > 0 else { return [] }
    let workers = max(1, threads)
    var values = [UInt64?](repeating: nil, count: count)
    values.withUnsafeMutableBufferPointer { output in
        guard let base = output.baseAddress else { return }
        DispatchQueue.concurrentPerform(iterations: workers) { group in
            let buffer = AttrBuffer()
            var index = group
            while index < count {
                base[index] = work(index, buffer)
                index += workers
            }
        }
    }
    return values
}

struct RuleTarget { let ruleIndex: Int; let path: String }

/// 下载、文稿、桌面受隐私保护：App 第一次读会弹授权框，读取会一直卡到有人点按钮
func ruleTouchesProtectedFolder(_ path: String) -> Bool {
    path.hasPrefix("<downloads:") || ["Downloads", "Documents", "Desktop"].contains { path.hasPrefix(HOME + "/" + $0 + "/") }
}

/// 发现阶段：把规则展开成一张扁平的目标清单。只列目录，不统计大小。
/// protected = nil 全部；false 只要不碰受保护文件夹的（清单先出）；true 只要碰的（放到后台）
func planRuleTargets(codeRoots: [String] = ALL_CODE_ROOTS, protected: Bool? = nil) -> [RuleTarget] {
    var targets: [RuleTarget] = []
    let rulePaths = RULES.map { rule in protected.map { want in rule.paths.filter { ruleTouchesProtectedFolder($0) == want } } ?? rule.paths }
    // 代码目录里的几种标记合成一次并行遍历，和工作空间构建目录的发现同时做；以前是每种标记各走一遍
    let pseudo = Set(rulePaths.joined())
    let specs = pseudo.filter { $0.hasPrefix("<codescan:") }.map { String($0.dropFirst("<codescan:".count).dropLast()) }.sorted()
    final class Precomputed: @unchecked Sendable { var codescan: [String: [String]] = [:]; var workspace: [String]? }
    let pre = Precomputed()
    DispatchQueue.concurrentPerform(iterations: 2) { job in
        if job == 0 { if !specs.isEmpty { pre.codescan = findAllInCodeRoots(specs, roots: codeRoots) } }
        else if pseudo.contains("<workspace:generated>") { pre.workspace = WorkspaceArtifacts.discover(roots: codeRoots) }
    }
    var precomputed = Dictionary(uniqueKeysWithValues: pre.codescan.map { ("<codescan:" + $0.key + ">", $0.value) })
    if let workspace = pre.workspace { precomputed["<workspace:generated>"] = workspace }
    for (i, rule) in RULES.enumerated() {
        let paths = rulePaths[i]
        if paths.isEmpty { continue }
        let real = expandPaths(paths, codeRoots: codeRoots, precomputed: precomputed)
        if real.isEmpty { continue }
        if rule.group == .perChild {
            for p in real { let k = children(of: p); for t in (k.isEmpty ? [p] : k) { targets.append(RuleTarget(ruleIndex: i, path: t)) } }
        } else {
            for p in real { targets.append(RuleTarget(ruleIndex: i, path: p)) }
        }
    }
    return targets
}

/// 组装阶段：用统计好的大小生成规则条目；大小为 0 或拿不到的跳过。活动时间要读目录，按目标并发
func buildRuleItems(_ targets: [RuleTarget], sizes: (String) -> UInt64?) -> [ScanItem] {
    let known = targets.map { sizes($0.path) }
    var items = [ScanItem?](repeating: nil, count: targets.count)
    items.withUnsafeMutableBufferPointer { out in
        guard let base = out.baseAddress else { return }
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in   // 各线程只写自己的下标
            guard let sz = known[i], sz > 0 else { return }
            let t = targets[i], rule = RULES[t.ruleIndex]
            let (a, topM) = statDays(t.path)
            let m = newestActivityDays(t.path) ?? topM
            let leaf = (t.path as NSString).lastPathComponent
            let shown = prettyName(rule: rule, path: t.path, leaf: leaf.isEmpty ? t.path : leaf)
            base[i] = CleanupEvidence.applying(to: ScanItem(
                name: shown, path: t.path, size: sz, atimeDays: a, mtimeDays: m,
                rule: rule.name, evidence: rule.evidence,
                risk: riskOf(rule, mtimeDays: m, usedDays: nil),
                gentle: rule.gentle, hard: rule.hard, undo: rule.undo, note: rule.note, rebuild: rule.rebuild,
                identity: CleanupIdentity.capture(path: t.path)))
        }
    }
    return items.compactMap { $0 }
}

/// CLI 用的旧入口：规划 + 逐个统计 + 组装 + 报告
func runLegacyRuleScan(progress: ((String, Int, Int) -> Void)? = nil) -> ScanReport {
    let t0 = Date()
    let walker = BulkWalker()
    let (diskTotal, diskFree) = diskUsage()
    let targets = planRuleTargets()

    // 把目标分成 N 组，组间并发、组内串行，每组复用一个属性缓冲。
    // N 太大会在 APFS 内核锁上打架（实测 10 线程 sys 时间翻倍、墙钟更慢），所以可调。
    let threads = max(1, Int(ProcessInfo.processInfo.environment["ROOMY_THREADS"] ?? "") ?? 4)   // 实测 2/4/8 线程墙钟都 ~10.5s，4 最稳；再高只增加 sys 时间
    var done = 0
    let doneLock = NSLock()
    let sizes = parallelSizes(count: targets.count, threads: threads) { i, buffer in
        let size = walker.size(of: targets[i].path, buf: buffer)
        doneLock.lock(); done += 1; let d = done; doneLock.unlock()
        if d % 20 == 0 || d == targets.count {
            progress?(RULES[targets[i].ruleIndex].name, d, targets.count)
        }
        return size
    }
    var byPath: [String: UInt64] = [:]
    for (i, t) in targets.enumerated() { if let s = sizes[i] { byPath[t.path] = s } }
    let items = buildRuleItems(targets) { byPath[$0] }
    var buckets = [[ScanItem]](repeating: [], count: RULES.count)
    let ruleIndex = Dictionary(RULES.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
    for item in items { buckets[ruleIndex[item.rule]!].append(item) }

    var layers = Layer.allCases.map { ScanLayer(key: $0, name: $0.title, moat: $0.moat, items: [], size: 0) }
    for (i, rule) in RULES.enumerated() {
        let li = Layer.allCases.firstIndex(of: rule.layer)!
        layers[li].items += buckets[i]
    }
    for i in layers.indices {
        layers[i].items.sort { $0.size > $1.size }
        layers[i].size = layers[i].items.reduce(0) { $0 + $1.size }
    }

    let all = layers.flatMap { $0.items }
    let sum = { (r: Risk) in all.filter { $0.risk == r }.reduce(UInt64(0)) { $0 + $1.size } }
    let total = all.reduce(UInt64(0)) { $0 + $1.size }
    let locked = sum(.lock)
    let reclaimable = all.filter { $0.undo && $0.risk != .lock }.reduce(UInt64(0)) { $0 + $1.size }

    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return ScanReport(
        scannedAt: f.string(from: Date()),
        machine: .init(diskTotal: diskTotal, diskFree: diskFree, diskUsed: diskTotal - diskFree),
        timing: .init(rulesSec: Date().timeIntervalSince(t0)),
        stats: .init(files: walker.files, dirs: walker.dirs, denied: walker.denied),
        summary: .init(total: total, green: sum(.green), amber: sum(.amber), locked: locked,
                       reclaimable: reclaimable, verdict: reclaimable >= 30 * 1024 * 1024 * 1024),
        layers: layers)
}
