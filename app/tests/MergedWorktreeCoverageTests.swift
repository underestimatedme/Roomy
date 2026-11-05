// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct MergedWorktreeCoverageTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-merged-" + UUID().uuidString
        let repo = root + "/code/repo", tasks = root + "/tasks"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        let runner = ProcessRunner(), tools = ToolLocator(), later = Date().addingTimeInterval(30 * 86_400)
        @discardableResult func git(_ args: [String], _ at: String? = nil) -> String {
            let r = runner.run("/usr/bin/git", ["-C", at ?? repo, "-c", "user.name=Test", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args, timeout: 20)
            precondition(r.ok, "git failed: \(args): \(r.stderr)")
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ path: String, _ text: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        git(["init", "-q", "-b", "main"])
        try write(repo + "/a", "initial")
        git(["add", "."]); git(["commit", "-qm", "initial"])
        let initial = git(["rev-parse", "HEAD"])
        git(["update-ref", "refs/remotes/origin/main", initial])
        git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let squash = tasks + "/squashed"
        git(["worktree", "add", "-qb", "task/squashed", squash])
        try write(squash + "/shipped", "one"); git(["add", "."], squash); git(["commit", "-qm", "first"], squash)
        try write(squash + "/shipped", "two"); git(["add", "."], squash); git(["commit", "-qm", "second"], squash)
        git(["merge", "--squash", "task/squashed"]); git(["commit", "-qm", "squash delivery"])
        let delivered = git(["rev-parse", "HEAD"])
        try write(repo + "/later", "later main work"); git(["add", "."]); git(["commit", "-qm", "later"])
        let detached = tasks + "/detached\nwith space"
        git(["worktree", "add", "-q", "--detach", detached, delivered])
        let dirty = tasks + "/dirty-merged"
        git(["worktree", "add", "-qb", "task/dirty", dirty, delivered])
        try write(dirty + "/uncommitted", "keep this")
        let ahead = tasks + "/ahead"
        git(["worktree", "add", "-qb", "task/ahead", ahead])
        try write(ahead + "/not-shipped", "private task"); git(["add", "."], ahead); git(["commit", "-qm", "not shipped"], ahead)
        let strandedHead = git(["rev-parse", "task/ahead"])
        let stranded = tasks + "/stranded"
        git(["worktree", "add", "-q", "--detach", stranded, strandedHead])
        func scan(_ roots: [String], now: Date? = nil) -> [CleanupCandidate] {
            WorktreeProbe.probe(roots: roots, runner: runner, tools: tools, now: now ?? later, sizeOf: { _ in 1000 })
        }
        // A locked candidate carries no action, so its path lives on the entry.
        func location(_ c: CleanupCandidate) -> String? { c.targetPath ?? c.entry.path }
        let found = scan([root + "/code", tasks])
        precondition(scan([detached]).allSatisfy { location($0) != detached || !$0.entry.selectable },
            "a selected working tree root itself stays protected; its independently verified children may still be scanned")
        guard let squashItem = found.first(where: { location($0) == squash }) else {
            preconditionFailure("squash merge retained in local main history must be recognized despite stale remote ref")
        }
        precondition(squashItem.entry.selectable && squashItem.entry.defaultChecked == (squashItem.entry.tier == .obsolete))
        precondition(squashItem.entry.evidence.contains("文件树"))
        guard let detachedItem = found.first(where: { location($0) == detached }) else { preconditionFailure("merged detached worktree must be recognized, including newline paths") }
        precondition(detachedItem.entry.selectable && detachedItem.entry.defaultChecked == (detachedItem.entry.tier == .obsolete))
        precondition(found.contains { location($0) == dirty && $0.entry.tier == .locked && !$0.entry.selectable
            && $0.action == nil && $0.entry.lockReason?.contains("未提交") == true && $0.entry.evidence.contains("未提交") },
            "a worktree with uncommitted edits is locked, not hidden")
        guard let aheadItem = found.first(where: { location($0) == ahead }) else { preconditionFailure("unmerged commits must be listed as locked") }
        precondition(aheadItem.entry.tier == .locked && !aheadItem.entry.selectable && aheadItem.action == nil
            && aheadItem.entry.lockReason?.contains("task/ahead") == true, "\(aheadItem.entry.lockReason ?? "nil")")
        guard let strandedItem = found.first(where: { location($0) == stranded }) else { preconditionFailure("detached HEAD outside main must be listed as locked") }
        precondition(strandedItem.entry.tier == .locked && strandedItem.action == nil && strandedItem.entry.lockReason?.contains("detached") == true,
            "\(strandedItem.entry.lockReason ?? "nil")")
        precondition(Set(found.compactMap(location)).count == found.count, "main and linked discovery must not duplicate candidates")
        // Merged and clean but touched within a week: still removable, just not pre-checked (B).
        let recent = scan([tasks], now: Date()).first { location($0) == squash }
        precondition(recent?.entry.tier == .rebuildable && recent?.entry.selectable == true && recent?.entry.defaultChecked == false,
            "\(String(describing: recent?.entry.tier))")
        if case .worktreeRemove? = recent?.action {} else { preconditionFailure("recent merged worktree keeps its remove action") }
        precondition(found.first { location($0) == squash }?.entry.tier == .obsolete, "idle merged clean worktree stays A")
        precondition(scan([tasks]).contains { $0.targetPath == squash }, "linked roots alone must discover their Git repository")
        git(["worktree", "lock", squash])
        precondition(!scan([tasks]).contains { $0.targetPath == squash && $0.entry.selectable })
        git(["worktree", "unlock", squash])
        let exclude = git(["rev-parse", "--git-common-dir"])
        let common = exclude.hasPrefix("/") ? exclude : repo + "/" + exclude
        try write(common + "/info/exclude", ".local-data/\n")
        try fm.createDirectory(atPath: squash + "/.local-data", withIntermediateDirectories: true)
        try write(squash + "/.local-data/private.env", "unique config")
        let ignored = scan([tasks]).first { $0.targetPath == squash }!
        precondition(!ignored.entry.selectable && ignored.entry.evidence.contains(".local-data") && ignored.entry.evidence.contains("1 个"))
        // A local default branch may itself be named origin/release; it must
        // never be confused with the remote-tracking ref of the same short name.
        git(["branch", "origin/release", "main"])
        git(["update-ref", "refs/remotes/origin/origin/release", initial])
        git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/origin/release"])
        let nestedDefault = scan([tasks])
        guard let nested = nestedDefault.first(where: { $0.targetPath == detached }),
              case .worktreeRemove(_, _, _, let reference) = nested.action else { preconditionFailure("local default ref with origin prefix must still be recognized") }
        precondition(reference == "refs/heads/origin/release", "execution must retain the exact local ref namespace")
        print("MergedWorktreeCoverageTests passed: squash history, stale remote, detached/newline paths, linked discovery, local edits and ignored diagnostics")
    }
}
