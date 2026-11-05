// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct WorktreeExecutionBindingTests {
    static func main() throws {
        let fm = FileManager.default, root = "/private/tmp/roomy-wt-binding-" + UUID().uuidString
        let repo = root + "/repo", detached = root + "/detached", named = root + "/named"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let runner = ProcessRunner(), tools = ToolLocator()
        @discardableResult func git(_ args: [String], _ at: String? = nil) -> String {
            let r = runner.run("/usr/bin/git", ["-C", at ?? repo, "-c", "user.name=Test", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, timeout: 20)
            precondition(r.ok, "\(args): \(r.stderr)"); return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        git(["init", "-qb", "main"])
        try "initial".write(toFile: repo + "/source", atomically: true, encoding: .utf8)
        git(["add", "."]); git(["commit", "-qm", "initial"])
        let first = git(["rev-parse", "HEAD"])
        git(["worktree", "add", "-q", "--detach", detached])
        git(["worktree", "add", "-qb", "task", named])
        func scan() -> [CleanupCandidate] {
            WorktreeProbe.probe(roots: [root], runner: runner, tools: tools,
                now: Date().addingTimeInterval(30 * 86400), sizeOf: { _ in 1000 })
        }
        guard let candidate = scan().first(where: { $0.targetPath == detached }),
              case .worktreeRemove(let item, let repository, let branch, let base) = candidate.action else { preconditionFailure("detached action") }
        precondition(branch == nil && item.cleanupEvidence?.fingerprint == first)
        precondition(WorktreeProbe.blocker(path: detached, repo: repository, branch: branch, base: base,
            runner: runner, tools: tools, expectedHead: first) == nil)
        precondition(WorktreeProbe.blocker(path: detached, repo: repository, branch: branch, base: base,
            runner: runner, tools: tools) != nil, "legacy unbound detached action must not execute")
        // Identical file contents do not make a new detached commit reachable.
        git(["commit", "--allow-empty", "-qm", "unique detached metadata"], detached)
        precondition(WorktreeProbe.blocker(path: detached, repo: repository, branch: branch, base: base,
            runner: runner, tools: tools, expectedHead: first) != nil)
        precondition(!scan().contains { $0.targetPath == detached && $0.entry.selectable }, "unmerged detached commits must remain protected even when their tree equals main")
        git(["checkout", "-q", first], detached)
        git(["switch", "-qc", "new-branch"], detached)
        precondition(WorktreeProbe.blocker(path: detached, repo: repository, branch: nil, base: base,
            runner: runner, tools: tools, expectedHead: first) != nil, "checkout mode changed")
        git(["update-index", "--assume-unchanged", "source"], named)
        try "hidden local edit".write(toFile: named + "/source", atomically: true, encoding: .utf8)
        precondition(git(["status", "--porcelain"], named).isEmpty, "fixture should hide an edit from status")
        precondition(!scan().contains { $0.targetPath == named && $0.entry.selectable })
        precondition(WorktreeProbe.blocker(path: named, repo: repo, branch: "task", base: "main",
            runner: runner, tools: tools, expectedHead: first) != nil)
        print("WorktreeExecutionBindingTests passed: pinned HEAD, detached reachability, checkout transitions and hidden index changes")
    }
}
