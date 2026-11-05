// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Exact local Git evidence only. Tree equality proves the full source snapshot
/// is retained in default-branch history; it does not assert a PR's remote state.
enum GitWorktreeMerge {
    struct Base {
        let name: String
        let ref: String
        let head: String
        let trees: Set<String>
    }
    struct Match {
        let base: String
        let reference: String
        let ancestor: Bool
    }

    static func oid(_ value: String) -> Bool {
        CacheContent.isHex(value, count: 40) || CacheContent.isHex(value, count: 64)
    }

    static func resolve(_ revision: String, repo: String, git: String, runner: CommandRunning) -> String? {
        let r = runner.run(git, ["--no-replace-objects", "-C", repo, "rev-parse", "--verify", "--end-of-options", revision], timeout: 10)
        let value = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && r.stderr.isEmpty && oid(value) ? value : nil
    }

    static func bases(repo: String, git: String, runner: CommandRunning) -> [Base] {
        let remote = runner.run(git, ["-C", repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], timeout: 10)
        let ref = remote.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var names: [String] = []
        if remote.ok, ref.hasPrefix("refs/remotes/origin/"), ref != "refs/remotes/origin/HEAD" {
            let branch = String(ref.dropFirst("refs/remotes/origin/".count))
            names = [ref, "refs/heads/" + branch]
        } else {
            for name in ["main", "master"] {
                if resolve("refs/heads/" + name + "^{commit}", repo: repo, git: git, runner: runner) != nil {
                    names = ["refs/heads/" + name]; break
                }
            }
        }
        return names.compactMap { base(name: $0, repo: repo, git: git, runner: runner) }
    }

    static func base(name: String, repo: String, git: String, runner: CommandRunning) -> Base? {
        // New actions retain fully qualified refs. Short names remain supported
        // only for existing callers; never shorten a newly discovered local ref.
        let ref = name.hasPrefix("refs/heads/") || name.hasPrefix("refs/remotes/") ? name :
            (name.hasPrefix("origin/") ? "refs/remotes/" + name : "refs/heads/" + name)
        let label = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref.dropFirst("refs/remotes/".count))
        guard let head = resolve(ref + "^{commit}", repo: repo, git: git, runner: runner) else { return nil }
        let history = runner.run(git, ["--no-replace-objects", "-C", repo, "log", "--first-parent", "--max-count=256", "--format=%T", head, "--"], timeout: 10)
        let lines = history.stdout.split(separator: "\n").map(String.init)
        let trees = history.ok && history.stderr.isEmpty && lines.allSatisfy(oid) ? Set(lines) : []
        return Base(name: label, ref: ref, head: head, trees: trees)
    }

    static func match(head: String, bases: [Base], repo: String, git: String, runner: CommandRunning) -> Match? {
        guard oid(head) else { return nil }
        // Prefer ancestry over equal contents, even if the remote is stale.
        for base in bases {
            let r = runner.run(git, ["--no-replace-objects", "-C", repo, "merge-base", "--is-ancestor", head, base.head], timeout: 10)
            if r.ok && r.stderr.isEmpty { return Match(base: base.name, reference: base.ref, ancestor: true) }
        }
        guard let tree = resolve(head + "^{tree}", repo: repo, git: git, runner: runner) else { return nil }
        return bases.first(where: { $0.trees.contains(tree) }).map { Match(base: $0.name, reference: $0.ref, ancestor: false) }
    }
}
