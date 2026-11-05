// SPDX-License-Identifier: MPL-2.0
import Foundation

private func evidence(_ tag: ContentTag, cleanup: CleanupCapability = .reviewRequired) -> ClassificationEvidence {
    ClassificationEvidence(tag: tag, confidence: .strong, source: .path,
        explanation: "fixture", cleanup: cleanup)
}

@main
struct ScanReportBuilderTests {
    static func main() {
        var index = ScanIndex(rootPath: HOME)
        _ = index.append(parentID: 0, fileID: 1, deviceID: 1, name: "", kind: .directory,
            logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let shared = index.append(parentID: 0, fileID: 2, deviceID: 1, name: "shared.gguf",
            kind: .file, logicalSize: 1000, allocatedSize: 1000, modifiedAt: 1, flags: [])
        let claude = index.append(parentID: 0, fileID: 3, deviceID: 1, name: ".claude",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let credentials = index.append(parentID: claude, fileID: 4, deviceID: 1,
            name: ".credentials.json", kind: .file, logicalSize: 500, allocatedSize: 500,
            modifiedAt: 1, flags: [])
        let archives = index.append(parentID: 0, fileID: 5, deviceID: 1, name: "Archives",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        _ = index.append(parentID: archives, fileID: 6, deviceID: 1, name: "Release.xcarchive",
            kind: .directory, logicalSize: 0, allocatedSize: 1500, modifiedAt: 1, flags: [])
        index.finalizeAggregates()

        let classifications = [
            ClassifiedEntry(entryID: shared, evidence: [evidence(.aiModel), evidence(.developerCache)]),
            ClassifiedEntry(entryID: credentials, evidence: [evidence(.systemManaged, cleanup: .none)]),
            ClassifiedEntry(entryID: archives, evidence: [evidence(.systemManaged, cleanup: .none)])
        ]
        let visible = index.totalAllocated(of: 0)
        let report = ScanReportBuilder().build(index: index, classifications: classifications,
            diagnostics: [], volume: VolumeUsage(total: 10_000, free: 6_000,
                knownSystemAndShared: 0), generation: 4, sequence: 2, complete: true)

        precondition(report.version == 2)
        precondition(report.generation == 4 && report.sequence == 2 && report.complete)
        precondition(report.diskTree.allocatedBytes == visible,
            "multi-tag node must contribute to the disk tree once")
        precondition(report.ledger.visible == visible)
        precondition(report.ledger.visible + report.ledger.inaccessible +
            report.ledger.systemAndShared + report.ledger.unexplained == report.machine.diskUsed)
        precondition(report.ledger.unexplained == 1000)
        precondition(report.trust == .needsAttention)

        let lockedPaths = Set(report.layers.flatMap(\.items).filter { $0.risk == .lock }.map(\.path))
        precondition(lockedPaths.contains("\(HOME)/.claude/.credentials.json"))
        precondition(lockedPaths.contains("\(HOME)/Archives"))
        let referencedShared = report.layers.flatMap(\.items).filter { $0.path == "\(HOME)/shared.gguf" }
        precondition(referencedShared.count == 1, "tags are metadata, not additive storage")

        var nested = ScanIndex(rootPath: HOME)
        _ = nested.append(parentID: 0, fileID: 10, deviceID: 1, name: "", kind: .directory,
            logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let modules = nested.append(parentID: 0, fileID: 11, deviceID: 1, name: "node_modules",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let package = nested.append(parentID: modules, fileID: 12, deviceID: 1, name: "pkg",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let file = nested.append(parentID: package, fileID: 13, deviceID: 1, name: "index.js",
            kind: .file, logicalSize: 100, allocatedSize: 100, modifiedAt: 1, flags: [])
        nested.finalizeAggregates()
        let nestedEvidence = evidence(.developerCache, cleanup: .rebuildable)
        let nestedReport = ScanReportBuilder().build(index: nested, classifications: [
            ClassifiedEntry(entryID: modules, evidence: [nestedEvidence]),
            ClassifiedEntry(entryID: package, evidence: [nestedEvidence]),
            ClassifiedEntry(entryID: file, evidence: [nestedEvidence])
        ], diagnostics: [], volume: VolumeUsage(total: 1000, free: 900,
            knownSystemAndShared: 0), generation: 1, sequence: 1, complete: true)
        precondition(nestedReport.summary.total == 100, "nested classifications must not multiply bytes")
        precondition(nestedReport.layers.flatMap(\.items).count == 1,
            "node_modules must be one cleanup unit")

        precondition(nestedReport.summary.reclaimable == 0 && !nestedReport.summary.verdict,
            "review-only dependencies must not be advertised as reclaimable")
        precondition(CleanupAuthorization(report: nestedReport).item(for: HOME + "/node_modules") == nil)

        var worktreeIndex = ScanIndex(rootPath: HOME + "/.codex/worktrees/task/repo")
        _ = worktreeIndex.append(parentID: 0, fileID: 30, deviceID: 1, name: "", kind: .directory,
            logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        for (offset, name) in ["node_modules", ".venv"].enumerated() {
            _ = worktreeIndex.append(parentID: 0, fileID: UInt64(31 + offset), deviceID: 1, name: name,
                kind: .directory, logicalSize: 0, allocatedSize: 100, modifiedAt: 1, flags: [])
        }
        worktreeIndex.finalizeAggregates()
        let worktreeReport = ScanReportBuilder().build(index: worktreeIndex,
            classifications: classifyScanIndex(worktreeIndex), diagnostics: [],
            volume: VolumeUsage(total: 1000, free: 800, knownSystemAndShared: 0),
            generation: 1, sequence: 1, complete: true)
        precondition(worktreeReport.layers.first { $0.key == .cache }?.items.count == 2,
            "project dependencies under .codex belong to development caches")
        precondition(worktreeReport.layers.first { $0.key == .sess }?.items.isEmpty == true,
            "the agent parent directory must not turn project content into AI sessions")
        precondition(worktreeReport.summary.total == 200 && worktreeReport.summary.reclaimable == 0,
            "reporting dependencies must not bypass content validation")

        var policyIndex = ScanIndex(rootPath: HOME)
        _ = policyIndex.append(parentID: 0, fileID: 20, deviceID: 1, name: "", kind: .directory,
            logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let ollamaRoot = policyIndex.append(parentID: 0, fileID: 21, deviceID: 1,
            name: ".ollama", kind: .directory, logicalSize: 0, allocatedSize: 0,
            modifiedAt: 1, flags: [])
        let models = policyIndex.append(parentID: ollamaRoot, fileID: 22, deviceID: 1,
            name: "models", kind: .directory, logicalSize: 0, allocatedSize: 200,
            modifiedAt: 1, flags: [])
        policyIndex.finalizeAggregates()
        let policyClassifications = [ClassifiedEntry(entryID: models,
            evidence: PathClassifier().classify(entry: policyIndex.entries[Int(models)],
                context: ClassificationContext(path: policyIndex.path(for: models), rootPath: HOME)))]
        let policyReport = ScanReportBuilder().build(index: policyIndex,
            classifications: policyClassifications, diagnostics: [],
            volume: VolumeUsage(total: 1000, free: 800, knownSystemAndShared: 0),
            generation: 1, sequence: 1, complete: true)
        let ollamaItem = policyReport.layers.flatMap(\.items).first { $0.path == "\(HOME)/.ollama/models" }
        precondition(ollamaItem?.undo == false && ollamaItem?.risk == .lock,
            "report-only rules must remain non-deletable")
        precondition(CleanupAuthorization(report: policyReport)
            .item(for: "\(HOME)/.ollama/models") == nil,
            "native authorization must reject report-only items")
        var incomplete = policyReport
        incomplete.complete = false
        precondition(CleanupAuthorization(report: incomplete).item(for: "anything") == nil,
            "partial reports must never authorize cleanup")
        print("scan report builder ok")
    }
}
