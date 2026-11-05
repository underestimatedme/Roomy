// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct TrashLedgerTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-ledger-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tmp) }
        let trash = tmp + "/.Trash", outside = tmp + "/Documents"
        try fm.createDirectory(atPath: trash + "/node_modules 3", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: trash + "/done", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: trash + "/cache", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside + "/keep", withIntermediateDirectories: true)
        let ledgerURL = URL(fileURLWithPath: tmp + "/pending-trash.json")

        let ledger = TrashLedger(url: ledgerURL, trashRoots: [trash])
        ledger.record([
            TrashedItem(path: trash + "/node_modules 3", bytes: 100, title: "node_modules · A"),
            TrashedItem(path: trash + "/done", bytes: 50, title: "Worktree · done"),
            TrashedItem(path: trash + "/cache", bytes: 30, title: "pip"),
            TrashedItem(path: outside + "/keep", bytes: 7, title: "不在废纸篓里"),       // 绝不能删
            TrashedItem(path: trash, bytes: 1, title: "废纸篓本身"),                       // 绝不能删
            TrashedItem(path: trash + "/../Documents/keep", bytes: 1, title: "绕出废纸篓"),  // 绝不能删
        ])
        precondition(ledger.pending().map(\.title) == ["node_modules · A", "Worktree · done", "pip"], "\(ledger.pending().map(\.title))")

        // 账本跨重启保留
        let reopened = TrashLedger(url: ledgerURL, trashRoots: [trash])
        precondition(reopened.pending().count == 3)

        // 用户自己把一项放回去了 → 不再算待删
        try fm.moveItem(atPath: trash + "/done", toPath: tmp + "/done-restored")
        precondition(reopened.pending().map(\.title) == ["node_modules · A", "pip"])

        // 同一位置被换成了别的东西（符号链接、或重新建的同名目录）→ 不是 Roomy 移进去的那个，不删
        try fm.removeItem(atPath: trash + "/node_modules 3")
        try fm.createDirectory(atPath: trash + "/node_modules 3", withIntermediateDirectories: true)
        precondition(reopened.pending().map(\.title) == ["pip"], "a different item at the same path is not ours to delete")
        try fm.removeItem(atPath: trash + "/node_modules 3")
        try fm.createSymbolicLink(atPath: trash + "/node_modules 3", withDestinationPath: outside + "/keep")
        precondition(reopened.pending().map(\.title) == ["pip"])

        var removed: [String] = []
        let result = reopened.purge { path in removed.append(path); try fm.removeItem(atPath: path) }
        precondition(removed == [trash + "/cache"], "\(removed)")
        precondition(result.removed.map(\.bytes) == [30] && result.failed.isEmpty)
        precondition(fm.fileExists(atPath: trash + "/node_modules 3"), "the swapped-in item is left alone")
        precondition(fm.fileExists(atPath: outside + "/keep"), "never touches anything outside the Trash")
        precondition(reopened.pending().isEmpty && TrashLedger(url: ledgerURL, trashRoots: [trash]).pending().isEmpty)

        // 删除失败的项留在账本里，下次还能再试
        try fm.createDirectory(atPath: trash + "/stuck", withIntermediateDirectories: true)
        reopened.record([TrashedItem(path: trash + "/stuck", bytes: 9, title: "stuck")])
        let failing = reopened.purge { _ in throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "busy"]) }
        precondition(failing.removed.isEmpty && failing.failed.map(\.1) == ["busy"])
        precondition(reopened.pending().map(\.title) == ["stuck"])
        // Go 模块缓存这类只读目录树：普通 removeItem 删不掉，forceRemove 补上写权限后能删
        try fm.removeItem(atPath: trash + "/stuck")   // 上一步留下的项，别让它干扰这里的断言
        try fm.createDirectory(atPath: trash + "/gomod/pkg/v1", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: trash + "/gomod/pkg/v1/a.go"))
        for p in [trash + "/gomod/pkg/v1/a.go", trash + "/gomod/pkg/v1", trash + "/gomod/pkg"] {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: p)
        }
        reopened.record([TrashedItem(path: trash + "/gomod", bytes: 1, title: "Go 模块缓存")])
        let plain = reopened.purge { try fm.removeItem(atPath: $0) }
        precondition(plain.removed.isEmpty && plain.failed.map(\.0.title) == ["Go 模块缓存"], "\(plain.removed.map(\.title))")
        let forced = reopened.purge { try TrashLedger.forceRemove($0) }
        precondition(forced.removed.map(\.title) == ["Go 模块缓存"] && !fm.fileExists(atPath: trash + "/gomod"),
                     "\(forced.failed.map(\.1))")
        print("TrashLedgerTests passed")
    }
}
