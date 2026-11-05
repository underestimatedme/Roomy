// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct WorktreeDiscoveryDepthTests {
    static func main() throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("roomy-worktree-depth-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let temp = realpath(raw, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }!
        defer { try? fm.removeItem(atPath: temp) }
        let hidden = temp + "/team/github/.worktrees/task/repo"
        let deep = temp + "/team/company/group/apps/mobile/repo"
        let dependency = temp + "/node_modules/package"
        for p in [hidden, deep, dependency] { try fm.createDirectory(atPath: p, withIntermediateDirectories: true); try "gitdir: /nonexistent".write(toFile: p + "/.git", atomically: true, encoding: .utf8) }
        let found = WorktreeProbe.findRepositories(roots: [temp])
        precondition(found.contains(hidden), "hidden .worktrees registry entry was missed")
        precondition(found.contains(deep), "deep repository registry entry was missed")
        precondition(!found.contains(dependency), "installed dependencies must not be traversed as independent project roots")
        let restart = temp + "/restart", restartedRepo = restart + "/repo"
        try fm.createDirectory(atPath: restartedRepo, withIntermediateDirectories: true)
        try "gitdir: /nonexistent".write(toFile: restartedRepo + "/.git", atomically: true, encoding: .utf8)
        precondition(WorktreeProbe.findRepositories(roots: [temp, restart], maxDepth: 1).contains(restartedRepo),
            "explicit nested start must re-enter a subtree previously truncated by the ancestor depth limit")
        print("WorktreeDiscoveryDepthTests passed")
    }
}
