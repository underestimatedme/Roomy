// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct CleanupCategoryTests {
    static func main() throws {
        // 每条会进清单的规则都要有类别（保护区、工具接管的不进清单）
        for rule in RULES where !rule.protect && !rule.toolOwned {
            let c = CleanupCategories.category(forRule: rule.name)
            precondition(c != "other", "rule \(rule.name) has no category")
        }
        for source in ["worktree", "simulator", "runtime", "ollama", "docker", "leftover", "launchagent", "agenthealth"] {
            precondition(CleanupCategories.category(forSource: source) != "other", "source \(source) has no category")
        }
        precondition(CleanupCategories.all.map(\.key).contains("other"))
        precondition(Set(CleanupCategories.all.map(\.key)).count == CleanupCategories.all.count)

        // 清单里每一项带上类别和规则组
        func ruleItem(_ path: String, _ rule: String, _ size: UInt64) -> ScanItem {
            ScanItem(name: (path as NSString).lastPathComponent, path: path, size: size, atimeDays: nil, mtimeDays: 30,
                     rule: rule, evidence: "e", risk: .green, gentle: nil, hard: "移到废纸篓", undo: true, note: "", rebuild: .cheap)
        }
        let wt = ScanItem.trashTarget(path: "/opt/coding/Valley/.worktrees/a", name: "a", size: 5, rule: "Git worktree",
                                      evidence: "e", risk: .green)
        let worktree = CleanupCandidate(source: "worktree", key: wt.path, title: "Worktree · a（Valley）", size: 5,
            evidence: "e", risk: .green, action: .worktreeRemove(item: wt, repo: "/opt/coding/Valley", branch: "b", base: "main"))
        let sim = CleanupCandidate(source: "simulator", key: "u", title: "iPhone", size: 3, evidence: "e", risk: .amber,
                                   action: .simctlDeleteDevice(udid: "u"))
        let list = CleanupListBuilder.build(items: [
            ruleItem("/Users/me/Library/Developer/Xcode/DerivedData/A-x", "Xcode DerivedData", 2),
            ruleItem("/Users/me/Library/Developer/Xcode/DerivedData/B-y", "Xcode DerivedData", 1),
            ruleItem("/Users/me/.npm/_cacache", "包管理器缓存", 9),
        ], probes: [worktree, sim])
        let byTitle = Dictionary(uniqueKeysWithValues: list.entries.map { ($0.title, $0) })
        precondition(byTitle["Worktree · a（Valley）"]?.category == "worktree")
        precondition(byTitle["Worktree · a（Valley）"]?.group == "Valley 的 worktree", "\(String(describing: byTitle["Worktree · a（Valley）"]?.group))")
        precondition(byTitle["iPhone"]?.category == "xcode" && byTitle["iPhone"]?.group == "iOS 模拟器")
        let derived = list.entries.filter { $0.group == "Xcode DerivedData" }
        precondition(derived.count == 2 && derived.allSatisfy { $0.category == "xcode" })
        precondition(list.entries.first { $0.group == "包管理器缓存" }?.category == "devcache")

        // 包管理器自己清空的那一行（source 还是 rule）保留规则的类别和组，不能把 "rule" 当组名露给用户
        var tool = CleanupCandidate(source: "rule", key: "/Users/me/Library/Caches/go-build", title: "Go 构建缓存 · ~/Library/Caches/go-build",
            size: 7, evidence: "e", risk: .green, action: .toolClean(.goBuildCache, scope: "/Users/me/Library/Caches/go-build"))
        tool.entry.category = "devcache"; tool.entry.group = "Go 构建缓存"
        let assigned = CleanupCategories.assign(tool).entry
        precondition(assigned.category == "devcache" && assigned.group == "Go 构建缓存", "\(assigned.category) / \(assigned.group)")

        // 类别说明随清单一起给界面
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CleanupCategories.all)) as! [[String: Any]]
        precondition(json.first?["title"] is String && json.first?["blurb"] is String)
        print("CleanupCategoryTests passed")
    }
}
