// SPDX-License-Identifier: MPL-2.0
import Foundation

private func expect(_ condition: Bool) { precondition(condition) }

@main struct OperationHistoryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-history-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("operations.jsonl")
        try Data("{\"title\":\"first\",\"ok\":true}\nmalformed\n{\"title\":\"failed\",\"ok\":false}\n{\"title\":\"last\",\"ok\":true}\n{incomplete".utf8).write(to: url)
        let rows = try OperationHistory.read(url: url, limit: 2)
        expect(rows.compactMap { $0["title"] as? String } == ["last", "failed"])
        expect(rows[1]["ok"] as? Bool == false)
        expect(try OperationHistory.read(url: root.appendingPathComponent("missing")).isEmpty)
        print("OperationHistoryTests passed")
    }
}
