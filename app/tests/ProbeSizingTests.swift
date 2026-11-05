// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct ProbeSizingTests {
    static func main() {
        let P = ToolProbes.placeholder
        let wtItem = ScanItem.trashTarget(path: "/code/.worktrees/a", name: "a", size: P, rule: "Git worktree", evidence: "e", risk: .green)
        let wt = CleanupCandidate(source: "worktree", key: wtItem.path, title: "Worktree · a", size: P, evidence: "e", risk: .green,
                                  action: .worktreeRemove(item: wtItem, repo: "/code", branch: "b", base: "main"))
        let goneItem = ScanItem.trashTarget(path: "/code/.worktrees/gone", name: "g", size: P, rule: "Git worktree", evidence: "e", risk: .green)
        let gone = CleanupCandidate(source: "worktree", key: goneItem.path, title: "Worktree · gone", size: P, evidence: "e", risk: .green,
                                    action: .worktreeRemove(item: goneItem, repo: "/code", branch: "g", base: "main"))
        let smallItem = ScanItem.trashTarget(path: "/L/Caches/tiny", name: "t", size: P, rule: "应用残留", evidence: "e", risk: .amber)
        let small = CleanupCandidate(source: "leftover", key: smallItem.path, title: "应用残留 · tiny", size: P, evidence: "e",
                                     risk: .amber, action: .trash(item: smallItem))
        let plistItem = ScanItem.trashTarget(path: "/L/LaunchAgents/x.plist", name: "x", size: 600, rule: "后台服务残留",
                                             evidence: "e", risk: .amber)
        let agent = CleanupCandidate(source: "launchagent", key: plistItem.path, title: "后台服务残留 · x", size: 600, evidence: "e",
                                     risk: .amber, action: .launchAgentRemove(label: "x", item: plistItem))
        let hint = CleanupCandidate(source: "docker", key: "down", title: "Docker 未运行", size: 0, evidence: "e", risk: .amber, action: nil)

        var index = SizeIndex()
        index.targets = ["/code/.worktrees/a": 7_000_000, "/L/Caches/tiny": 500_000]
        let out = ToolProbes.sized([wt, gone, small, agent, hint],
                                   sizePaths: ["/code/.worktrees/a", "/code/.worktrees/gone", "/L/Caches/tiny"], index: index)
        precondition(out.map(\.entry.title) == ["Worktree · a", "后台服务残留 · x", "Docker 未运行"], "\(out.map(\.entry.title))")
        precondition(out[0].entry.size == 7_000_000 && out[0].entry.id == wt.entry.id)
        guard case .worktreeRemove(let item, _, _, _) = out[0].action else { preconditionFailure("action") }
        precondition(item.size == 7_000_000 && item.identity == wtItem.identity, "the ScanItem inside the action follows")
        precondition(out[1].entry.size == 600, "plist not in sizePaths keeps its own size")
        precondition(!out.contains { $0.entry.size == P }, "no placeholder leaks out")
        print("ProbeSizingTests passed")
    }
}
