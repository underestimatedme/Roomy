// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct CleanupAuthorization: Sendable {
    private let items: [String: ScanItem]

    init(report: ScanReport?) {
        guard let report, report.complete else {
            items = [:]
            return
        }
        items = Dictionary(uniqueKeysWithValues: report.layers.flatMap(\.items).map { ($0.path, $0) })
    }

    func item(for path: String) -> ScanItem? {
        guard let item = items[path], item.undo, item.risk != .lock else { return nil }
        return item
    }
}
