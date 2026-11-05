// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private final class ProtectionCommandSpy: CommandRunning {
    var calls = 0
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls += 1
        return CommandResult(status: 1, stdout: "", stderr: "test spy", timedOut: false)
    }
}

@main struct CleanupProtectionTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-protection-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("protected.json")
        func candidate(_ path: String) -> CleanupCandidate {
            let item = ScanItem.trashTarget(path: path, name: "cache", size: 100, rule: "test", evidence: "sample", risk: .green)
            return CleanupCandidate(source: "rule", key: path, title: "sample", size: 100, evidence: "sample", risk: .green, action: .trash(item: item))
        }
        let store = CleanupProtectionStore(url: url)
        let child = candidate("/projects/App/cache")
        try store.set(child, protected: true)
        let reopened = CleanupProtectionStore(url: url)
        let records = try reopened.all()
        precondition(records.count == 1)
        let parentBlocked = try reopened.blocks(path: "/projects/App")
        let childBlocked = try reopened.blocks(path: "/projects/App/cache/part")
        let neighborBlocked = try reopened.blocks(path: "/projects/Application/cache")
        precondition(parentBlocked && childBlocked && !neighborBlocked)
        let tool = CleanupCandidate(source: "ollama", key: "Qwen:7b", title: "Qwen", size: 100, evidence: "sample", risk: .amber, action: .ollamaRemove(model: "Qwen:7b"))
        try reopened.set(tool, protected: true)
        let list = try reopened.apply(to: CleanupList(candidates: [child, candidate("/projects/App"), tool]))
        precondition(list.entries.allSatisfy { !$0.selectable && !$0.defaultChecked && $0.userProtected == true })
        precondition(list.entries.allSatisfy { $0.tier == .locked && $0.lockReason == "你加了保护" },
            "user-protected items are listed as locked with the protection reason")
        precondition(list.candidates.allSatisfy { $0.action == nil }, "locked candidates carry no action")
        var executed = false
        var env = CleanupEnvironment()
        let commands = ProtectionCommandSpy(); env.runner = commands
        env.trash = { _ in executed = true; return nil }
        env.diskFree = { 0 }
        let result = CleanupRunner.run(ids: [child.entry.id, tool.entry.id], list: list, env: env, progress: { _ in })
        precondition(!executed && commands.calls == 0 && result.outcomes.allSatisfy { !$0.ok })
        // Cached entries have a path but no action/targetPath. Overlap protections still apply.
        let cachedEntry = candidate("/projects/App").entry
        let cached = CleanupCandidate(entry: cachedEntry, action: nil)
        let protectedCache = try reopened.apply(to: CleanupList(candidates: [cached]))
        precondition(protectedCache.entries[0].userProtected == true)
        // Atomic write failure cannot erase existing protections or silently enable cleanup.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        do { try reopened.remove(id: tool.entry.id); preconditionFailure("write must fail") } catch { }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let afterFailedWrite = try reopened.apply(to: CleanupList(candidates: [tool]))
        precondition(afterFailedWrite.entries[0].userProtected == true)
        try reopened.remove(id: child.entry.id)
        let unblocked = try reopened.blocks(path: "/projects/App")
        precondition(!unblocked)
        try Data("corrupted".utf8).write(to: url)
        do { _ = try reopened.apply(to: CleanupList(candidates: [child])); preconditionFailure("corrupt protections must block execution") }
        catch { }
        print("CleanupProtectionTests passed")
    }
}
