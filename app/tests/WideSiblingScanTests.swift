// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct WideSiblingScanTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-wide-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for index in 0..<2_000 {
            try fm.createDirectory(at: root.appendingPathComponent("d-\(index)"),
                withIntermediateDirectories: false)
        }

        let completion = try await runIndexScan(root: root, workerCount: 6)
        precondition(completion.index.entries.filter { $0.kind == .directory }.count == 2_001)
        precondition(completion.diagnostics.isEmpty)
        print("wide sibling scan ok")
    }
}
