// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct LedgerReadIsolationTests {
    static func main() throws {
        let root = "/private/tmp/roomy-ledger-read-" + UUID().uuidString
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/trash", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let path = root + "/trash/item"
        try Data("sample".utf8).write(to: URL(fileURLWithPath: path))
        let url = URL(fileURLWithPath: root + "/ledger.json")
        let ledger = TrashLedger(url: url, trashRoots: [root + "/trash"])
        ledger.record([TrashedItem(path: path, bytes: 6, title: "sample")])
        let before = try Data(contentsOf: url)
        try fm.removeItem(atPath: path)
        precondition(ledger.pending().isEmpty)
        let after = try Data(contentsOf: url)
        precondition(after == before, "read-only polling must not rewrite shared mutation records")
        print("ledger read isolation ok")
    }
}
