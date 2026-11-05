// SPDX-License-Identifier: MPL-2.0
import Foundation

private func expect(_ condition: Bool) { precondition(condition) }

@main struct RecoveryTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.path
        let base = temp.hasPrefix("/var/") ? "/private" + temp : temp
        let root = URL(fileURLWithPath: base).appendingPathComponent("roomy-recovery-\(UUID())")
        let trash = root.appendingPathComponent("Trash")
        let original = root.appendingPathComponent("project/cache")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let ledger = TrashLedger(url: root.appendingPathComponent("ledger.json"), trashRoots: [trash.path])
        let inTrash = trash.appendingPathComponent("cache")
        try Data("my original sample".utf8).write(to: inTrash)
        ledger.record([TrashedItem(path: inTrash.path, bytes: 18, title: "sample", originalPath: original.path)])
        let first = ledger.pending()[0]
        _ = try ledger.restore(id: first.recoveryID)
        expect(try Data(contentsOf: original) == Data("my original sample".utf8))
        expect(ledger.pending().isEmpty && !fm.fileExists(atPath: inTrash.path))

        try Data("second".utf8).write(to: inTrash)
        ledger.record([TrashedItem(path: inTrash.path, bytes: 6, title: "conflict", originalPath: original.path)])
        let conflict = ledger.pending()[0]
        expectBlocked { _ = try ledger.restore(id: conflict.recoveryID) }
        expect(try Data(contentsOf: original) == Data("my original sample".utf8))
        expect(fm.fileExists(atPath: inTrash.path) && ledger.pending().count == 1)

        // Replace parent by a symlink; restoration must not write into its target.
        try fm.removeItem(at: original)
        try fm.removeItem(at: original.deletingLastPathComponent())
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: original.deletingLastPathComponent(), withDestinationURL: elsewhere)
        expectBlocked { _ = try ledger.restore(id: conflict.recoveryID) }
        expect(!fm.fileExists(atPath: elsewhere.appendingPathComponent("cache").path))
        try fm.removeItem(at: original.deletingLastPathComponent())
        expectBlocked { _ = try ledger.restore(id: conflict.recoveryID) }

        // A replacement object at the same Trash location is not ours.
        try fm.moveItem(at: inTrash, to: trash.appendingPathComponent("held-original"))
        try Data("replacement".utf8).write(to: inTrash)
        expectBlocked { _ = try ledger.restore(id: conflict.recoveryID) }
        expect(try Data(contentsOf: inTrash) == Data("replacement".utf8))

        let legacy = trash.appendingPathComponent("legacy")
        try Data("old".utf8).write(to: legacy)
        ledger.record([TrashedItem(path: legacy.path, bytes: 3, title: "legacy")])
        let old = ledger.pending().first { $0.title == "legacy" }!
        expectBlocked { _ = try ledger.restore(id: old.recoveryID) }
        expect(fm.fileExists(atPath: legacy.path))
        // Authentic old JSON has neither identity nor original path. Keep it visible, never act on it.
        let legacyURL = root.appendingPathComponent("legacy-ledger.json")
        try JSONSerialization.data(withJSONObject: [["path": legacy.path, "bytes": 3, "title": "old-format"]]).write(to: legacyURL)
        let oldLedger = TrashLedger(url: legacyURL, trashRoots: [trash.path])
        expect(oldLedger.recoveryItems().count == 1)
        expect(oldLedger.pending().isEmpty)
        expectBlocked { _ = try oldLedger.restore(id: oldLedger.recoveryItems()[0].recoveryID) }
        print("RecoveryTests passed")
    }
    static func expectBlocked(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("unsafe restore must fail") } catch { }
    }
}
