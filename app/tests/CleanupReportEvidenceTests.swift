// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct CleanupReportEvidenceTests {
    static func main() {
        // Synthetic nonexistent child; never creates or cleans anything in the user's Xcode folder.
        var index = ScanIndex(rootPath: HOME)
        _ = index.append(parentID: 0, fileID: 1, deviceID: 1, name: "", kind: .directory,
            logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        var parent: EntryID = 0
        for name in ["Library", "Developer", "Xcode", "DerivedData"] {
            parent = index.append(parentID: parent, fileID: UInt64(index.entries.count + 1), deviceID: 1, name: name,
                kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        }
        let child = index.append(parentID: parent, fileID: 9, deviceID: 1, name: "RoomySynthetic-" + UUID().uuidString,
            kind: .directory, logicalSize: 0, allocatedSize: 4096, modifiedAt: 1, flags: [])
        index.finalizeAggregates()
        let report = ScanReportBuilder().build(index: index, classifications: classifyScanIndex(index), diagnostics: [],
            volume: VolumeUsage(total: 8192, free: 4096, knownSystemAndShared: 0), generation: 1, sequence: 1, complete: true)
        let items = report.layers.flatMap(\.items)
        precondition(items.count == 1 && items[0].path == index.path(for: child),
            "unified reporting must emit per-project DerivedData units, not drop them under the literal root")
        precondition(!items[0].undo && report.summary.reclaimable == 0, "nonexistent/uninspected child is review-only")
        print("CleanupReportEvidenceTests passed")
    }
}
