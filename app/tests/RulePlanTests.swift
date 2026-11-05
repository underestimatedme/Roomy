// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct RulePlanTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-plan-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tmp) }
        for d in ["a", "b"] { try fm.createDirectory(atPath: tmp + "/" + d, withIntermediateDirectories: true) }
        let npm = RULES.firstIndex { $0.name == "包管理器缓存" }!
        let targets = [RuleTarget(ruleIndex: npm, path: tmp + "/a"), RuleTarget(ruleIndex: npm, path: tmp + "/b")]
        let items = buildRuleItems(targets) { $0.hasSuffix("/a") ? 4_000 : 0 }
        precondition(items.count == 1 && items[0].path == tmp + "/a" && items[0].size == 4_000, "\(items.map(\.path))")
        precondition(items[0].rule == "包管理器缓存" && items[0].identity != nil)
        precondition(items[0].risk == riskOf(RULES[npm], mtimeDays: items[0].mtimeDays, usedDays: nil))

        // 多个目标并发组装（触发并发写）
        let many = (0..<64).map { RuleTarget(ruleIndex: npm, path: tmp + "/m\($0)") }
        for t in many { try fm.createDirectory(atPath: t.path, withIntermediateDirectories: true) }
        precondition(buildRuleItems(many) { _ in 1 }.count == 64)

        // 受隐私保护的文件夹（下载、文稿、桌面）：读它们会弹授权、卡住扫描，所以单独规划、放到清单之后
        precondition(ruleTouchesProtectedFolder("<downloads:.dmg,.pkg>"))
        precondition(ruleTouchesProtectedFolder(HOME + "/Documents/ComfyUI/models"))
        precondition(ruleTouchesProtectedFolder(HOME + "/Desktop/x"))
        precondition(!ruleTouchesProtectedFolder(HOME + "/Library/Caches/pip") && !ruleTouchesProtectedFolder("<codescan:node_modules>"))
        let main = planRuleTargets(protected: false), later = planRuleTargets(protected: true)
        let protectedRoots = ["/Downloads/", "/Documents/", "/Desktop/"].map { HOME + $0 }
        precondition(!main.contains { t in protectedRoots.contains { t.path.hasPrefix($0) } }, "main plan never touches protected folders")
        precondition(later.allSatisfy { t in protectedRoots.contains { t.path.hasPrefix($0) } })

        // 规划阶段只列目录、不统计大小：同一份规划在真实机器上非空
        let plan = planRuleTargets()
        precondition(!plan.isEmpty && plan.allSatisfy { RULES.indices.contains($0.ruleIndex) })
        // 旧入口仍然能用（CLI）
        precondition(!runLegacyRuleScan().layers.flatMap(\.items).isEmpty)
        print("RulePlanTests passed")
    }
}
