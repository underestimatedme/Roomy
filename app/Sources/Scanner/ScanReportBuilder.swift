// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct VolumeUsage: Equatable, Sendable {
    let total: UInt64
    let free: UInt64
    let knownSystemAndShared: UInt64

    var used: UInt64 { total >= free ? total - free : 0 }
}

struct ScanReportBuilder {
    func build(
        index: ScanIndex,
        classifications: [ClassifiedEntry],
        diagnostics: [ScanDiagnostic],
        volume: VolumeUsage,
        generation: ScanGeneration,
        sequence: UInt64,
        complete: Bool
    ) -> ScanReport {
        let byID = Dictionary(uniqueKeysWithValues: classifications.map { ($0.entryID, $0) })
        let visible = index.entries.isEmpty ? 0 : index.totalAllocated(of: 0)
        let accountedVisible = min(visible, volume.used)
        let remaining = volume.used - accountedVisible
        let systemAndShared = min(volume.knownSystemAndShared, remaining)
        let unexplained = remaining - systemAndShared
        let ledger = SpaceLedger(visible: accountedVisible, inaccessible: 0,
            systemAndShared: systemAndShared, unexplained: unexplained)
        let trust = scanTrust(unexplained: unexplained, diskUsed: volume.used)
        let tree = index.entries.isEmpty ? .empty : buildTree(index: index, id: 0,
            path: index.rootPath,
            classifications: byID, displayThreshold: max(1_048_576, visible / 500))
        let layers = buildLayers(index: index, classifications: classifications)
        let all = layers.flatMap(\.items)
        let riskTotal: (Risk) -> UInt64 = { risk in
            all.filter { $0.risk == risk }.reduce(0) { $0 &+ $1.size }
        }
        let total = all.reduce(UInt64(0)) { $0 &+ $1.size }
        let locked = riskTotal(.lock)
        let actionable = all.filter { $0.undo && $0.risk != .lock }.reduce(UInt64(0)) { $0 &+ $1.size }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var report = ScanReport(
            scannedAt: formatter.string(from: Date()),
            machine: .init(diskTotal: volume.total, diskFree: volume.free, diskUsed: volume.used),
            timing: .init(rulesSec: 0),
            stats: .init(files: index.entries.filter { $0.kind == .file }.count,
                dirs: index.entries.filter { $0.kind == .directory }.count,
                denied: diagnostics.filter { $0.kind == .permissionDenied }.count),
            summary: .init(total: total, green: riskTotal(.green), amber: riskTotal(.amber),
                locked: locked, reclaimable: actionable,
                verdict: actionable >= 30 * 1024 * 1024 * 1024),
            layers: layers
        )
        report.version = 2
        report.generation = generation
        report.sequence = sequence
        report.complete = complete
        report.diskTree = tree
        report.ledger = ledger
        report.trust = trust
        return report
    }

    private func scanTrust(unexplained: UInt64, diskUsed: UInt64) -> ScanTrust {
        guard diskUsed > 0 else { return .trusted }
        let ratio = Double(unexplained) / Double(diskUsed)
        if ratio < 0.01 { return .trusted }
        if ratio <= 0.05 { return .partial }
        return .needsAttention
    }

    private func buildTree(
        index: ScanIndex,
        id: EntryID,
        path: String,
        classifications: [EntryID: ClassifiedEntry],
        displayThreshold: UInt64
    ) -> DiskTreeNode {
        var children: [DiskTreeNode] = []
        var groupedBytes: UInt64 = 0
        for childID in index.children(of: id) {
            let childPath = path + (path == "/" ? "" : "/") + index.name(for: childID)
            let important = classifications[childID] != nil
            let size = index.totalAllocated(of: childID)
            if !important && size < displayThreshold {
                groupedBytes &+= size
            } else {
                children.append(buildTree(index: index, id: childID, path: childPath,
                    classifications: classifications, displayThreshold: displayThreshold))
            }
        }
        if groupedBytes > 0 {
            children.append(DiskTreeNode(entryID: nil, name: "其他文件",
                path: path + (path == "/" ? "" : "/") + "#other",
                allocatedBytes: groupedBytes, tags: [], children: [], synthetic: true))
        }
        children.sort { $0.allocatedBytes > $1.allocatedBytes }
        return DiskTreeNode(entryID: id,
            name: id == 0 ? URL(fileURLWithPath: index.rootPath).lastPathComponent : index.name(for: id),
            path: path, allocatedBytes: index.totalAllocated(of: id),
            tags: classifications[id]?.tags ?? [], children: children, synthetic: false)
    }

    private func buildLayers(
        index: ScanIndex,
        classifications: [ClassifiedEntry]
    ) -> [ScanLayer] {
        var result = Layer.allCases.map {
            ScanLayer(key: $0, name: $0.title, moat: $0.moat, items: [], size: 0)
        }
        for classification in classifications where Int(classification.entryID) < index.entries.count {
            let path = index.path(for: classification.entryID)
            guard let policy = cleanupPolicy(path: path, classification: classification) else {
                continue
            }
            let evidence = classification.evidence.max { $0.confidence < $1.confidence }
            let layer = policy.rule?.layer ?? primaryLayer(classification, path: path)
            let risk = policy.risk
            let entry = index.entries[Int(classification.entryID)]
            let item = CleanupEvidence.applying(to: ScanItem(name: index.name(for: classification.entryID), path: path,
                size: index.totalAllocated(of: classification.entryID), atimeDays: nil,
                mtimeDays: ageInDays(entry.modifiedAt),
                rule: policy.rule?.name ?? ruleName(for: classification),
                evidence: policy.rule?.evidence ?? evidence?.explanation ?? "路径和文件类型",
                risk: risk, gentle: policy.rule?.gentle,
                hard: policy.rule?.hard ?? (policy.undo ? "移到废纸篓" : "仅报告"),
                undo: policy.undo,
                note: policy.rule?.note ?? (risk == .lock ? "仅展示，不会清理" : ""),
                rebuild: policy.rule?.rebuild ?? rebuild(for: classification),
                identity: CleanupIdentity.capture(path: path, fallback: entry),
                reclaimEstimate: ReclaimEstimator().estimate(index: index,
                    entryID: classification.entryID,
                    cleanupAllowed: policy.undo && risk != .lock)))
            let position = Layer.allCases.firstIndex(of: layer)!
            result[position].items.append(item)
        }
        for index in result.indices {
            result[index].items.sort { $0.size > $1.size }
            result[index].size = result[index].items.reduce(0) { $0 &+ $1.size }
        }
        return result
    }

    private struct CleanupPolicy {
        let rule: Rule?
        let risk: Risk
        let undo: Bool
    }

    /// Classification applies to descendants for search and display. Cleanup permission applies
    /// only to a rule root (or one dynamic unit), so subtree bytes are never added repeatedly.
    private func cleanupPolicy(path: String, classification: ClassifiedEntry) -> CleanupPolicy? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let literalMatches = RULES.flatMap { rule in
            rule.literalPaths.map { (rule, URL(fileURLWithPath: $0).standardizedFileURL.path) }
        }.filter { normalized == $0.1 || normalized.hasPrefix($0.1 + "/") }
        if let match = literalMatches.max(by: { $0.1.count < $1.1.count }) {
            if match.0.name == "Xcode DerivedData" {
                // Match the legacy per-child planning unit; never recommend the parent root.
                guard URL(fileURLWithPath: normalized).deletingLastPathComponent().path == match.1 else { return nil }
            } else {
                guard normalized == match.1 else { return nil }
            }
            return CleanupPolicy(rule: match.0,
                risk: match.0.cleanupCapability == .none ? .lock : risk(for: classification),
                undo: match.0.cleanupCapability != .none && match.0.undo)
        }

        let name = URL(fileURLWithPath: normalized).lastPathComponent
        if name == "node_modules" || name == ".venv" {
            let rule = RULES.first { $0.paths.contains("<codescan:\(name)>") }
            return CleanupPolicy(rule: rule, risk: .green, undo: true)
        }
        let components = URL(fileURLWithPath: normalized).pathComponents
        if components.contains("node_modules") || components.contains(".venv") { return nil }
        let pathURL = URL(fileURLWithPath: normalized)
        if !pathURL.pathExtension.isEmpty,
           pathURL.deletingLastPathComponent().lastPathComponent == "Downloads",
           ["dmg", "pkg", "xip", "iso"].contains(pathURL.pathExtension.lowercased()) {
            let rule = RULES.first { $0.paths.contains { $0.hasPrefix("<downloads:") } }
            return CleanupPolicy(rule: rule, risk: risk(for: classification), undo: rule?.undo ?? true)
        }

        // Pure file-type guesses remain visible but can never authorize deletion.
        if classification.evidence.contains(where: { $0.cleanup == .none }) {
            return CleanupPolicy(rule: nil, risk: .lock, undo: false)
        }
        // Synthetic/unit tests and future exact classifiers may provide a standalone unit.
        guard !classification.evidence.contains(where: { $0.source == .legacyRule }) else { return nil }
        return CleanupPolicy(rule: nil, risk: risk(for: classification),
            undo: !classification.evidence.contains(where: { $0.cleanup == .none }))
    }

    private func primaryLayer(_ value: ClassifiedEntry, path: String) -> Layer {
        if value.tags.contains(.aiModel) { return .models }
        if value.tags.contains(.aiSession) { return .sess }
        if path.contains("/Xcode/") || path.contains("/CoreSimulator/") ||
            path.contains("/Android/") || path.contains("/.android/") { return .mobile }
        if value.tags.contains(.developerCache) { return .cache }
        if path.contains("/.claude/") || path.contains("/.codex/") { return .sess }
        return .cache
    }

    private func risk(for value: ClassifiedEntry) -> Risk {
        if value.evidence.contains(where: { $0.cleanup == .none }) {
            return .lock
        }
        if value.evidence.contains(where: { $0.cleanup == .rebuildable }) { return .green }
        return .amber
    }

    private func rebuild(for value: ClassifiedEntry) -> Rebuild {
        value.evidence.contains(where: { $0.cleanup == .rebuildable }) ? .cheap : .costly
    }

    private func ruleName(for value: ClassifiedEntry) -> String {
        if value.tags.contains(.systemManaged) { return "保护区" }
        if value.tags.contains(.aiModel) { return "AI 模型" }
        if value.tags.contains(.aiSession) { return "AI 会话" }
        if value.tags.contains(.developerCache) { return "开发缓存" }
        return "个人文件"
    }

    private func ageInDays(_ timestamp: Int64) -> Int? {
        guard timestamp > 0 else { return nil }
        return max(0, Int((Date().timeIntervalSince1970 - Double(timestamp)) / 86_400))
    }
}
