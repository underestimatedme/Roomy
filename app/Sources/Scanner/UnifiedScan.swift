// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

func classifyScanIndex(_ index: ScanIndex) -> [ClassifiedEntry] {
    var values: [ClassifiedEntry] = []
    values.reserveCapacity(index.entries.count / 8)
    let pathClassifier = PathClassifier()
    let fileClassifier = FileKindClassifier()
    let ruleLeafNames = Set(RULES.flatMap(\.literalPaths).map {
        URL(fileURLWithPath: $0).lastPathComponent
    })
    let structuralNames = ruleLeafNames.union(["node_modules", ".venv"])
    let structuralNameIDs = Set(structuralNames.compactMap { index.stringPool.id(for: $0) })
    let derivedRoots = Set(RULES.filter { $0.name == "Xcode DerivedData" }.flatMap(\.literalPaths))
    let derivedParentIDs = Set(index.entries.filter { entry in
        (entry.id == 0 || index.name(for: entry.id) == "DerivedData") &&
            derivedRoots.contains(index.path(for: entry.id))
    }.map(\.id))
    let modelExtensions: Set<String> = ["gguf", "safetensors", "ckpt", "onnx"]
    let ordinaryExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "heic", "heif",
        "jpg", "jpeg", "png", "tiff", "raw", "dng", "pdf", "doc", "docx",
        "pages", "xls", "xlsx", "ppt", "pptx", "txt", "md", "dmg", "pkg", "xip", "iso"
    ]
    for entry in index.entries {
        let structural = structuralNameIDs.contains(entry.nameID) || derivedParentIDs.contains(entry.parentID)
        var classifiedFile = false
        if entry.kind == .file && entry.logicalSize >= 100 * 1024 * 1024 {
            let name = index.name(for: entry.id)
            let lower = name.lowercased()
            let ext = lower.split(separator: ".").last.map(String.init) ?? ""
            classifiedFile = modelExtensions.contains(ext) || lower.hasSuffix(".safetensors.index.json") ||
                ordinaryExtensions.contains(ext)
        }
        guard entry.id == 0 || structural || classifiedFile else { continue }
        let context = ClassificationContext(path: index.path(for: entry.id), rootPath: index.rootPath)
        let evidence = pathClassifier.classify(entry: entry, context: context) +
            fileClassifier.classify(entry: entry, context: context)
        if !evidence.isEmpty {
            values.append(ClassifiedEntry(entryID: entry.id, evidence: evidence))
        }
    }
    return AIManifestClassifier().enrich(values, index: index)
}

func volumeUsage(for root: URL) -> VolumeUsage {
    var value = statfs()
    guard statfs(root.path, &value) == 0 else {
        return VolumeUsage(total: 0, free: 0, knownSystemAndShared: 0)
    }
    let blockSize = UInt64(value.f_bsize)
    return VolumeUsage(total: UInt64(value.f_blocks) * blockSize,
        free: UInt64(value.f_bavail) * blockSize, knownSystemAndShared: 0)
}

func buildUnifiedReport(
    index: ScanIndex,
    diagnostics: [ScanDiagnostic],
    generation: ScanGeneration,
    sequence: UInt64,
    complete: Bool
) -> ScanReport {
    ScanReportBuilder().build(index: index, classifications: classifyScanIndex(index),
        diagnostics: diagnostics, volume: volumeUsage(for: URL(fileURLWithPath: index.rootPath)),
        generation: generation, sequence: sequence, complete: complete)
}

func buildPartialReport(_ partial: PartialScanSnapshot, sequence: UInt64) -> ScanReport {
    let usage = volumeUsage(for: URL(fileURLWithPath: partial.rootPath))
    let visible = min(partial.allocatedBytes, usage.used)
    let child = DiskTreeNode(entryID: nil, name: "已扫描空间",
        path: partial.rootPath + "/#scanned", allocatedBytes: partial.allocatedBytes,
        tags: [], children: [], synthetic: true)
    let tree = DiskTreeNode(entryID: 0,
        name: URL(fileURLWithPath: partial.rootPath).lastPathComponent,
        path: partial.rootPath, allocatedBytes: partial.allocatedBytes,
        tags: [], children: partial.allocatedBytes > 0 ? [child] : [], synthetic: false)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return ScanReport(version: 2, generation: partial.generation, sequence: sequence,
        complete: false, diskTree: tree,
        ledger: SpaceLedger(visible: visible, inaccessible: 0,
            systemAndShared: 0, unexplained: usage.used - visible),
        trust: .partial, scannedAt: formatter.string(from: Date()),
        machine: .init(diskTotal: usage.total, diskFree: usage.free, diskUsed: usage.used),
        timing: .init(rulesSec: 0),
        stats: .init(files: partial.files, dirs: partial.directories, denied: 0),
        summary: .init(total: 0, green: 0, amber: 0, locked: 0,
            reclaimable: 0, verdict: false), layers: [])
}

func runUnifiedScan(
    root: URL,
    priorityRoots: [URL] = [],
    reader: any DirectoryReading = DirectoryReader(),
    workerCount: Int = 8,
    onEvent: ScanCoordinator.EventHandler? = nil
) async throws -> ScanReport {
    let completion = try await runIndexScan(root: root, priorityRoots: priorityRoots,
        reader: reader, workerCount: workerCount, onEvent: onEvent)
    return buildUnifiedReport(index: completion.index, diagnostics: completion.diagnostics,
        generation: completion.generation, sequence: 1, complete: true)
}
