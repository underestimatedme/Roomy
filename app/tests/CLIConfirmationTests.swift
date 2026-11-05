// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct CLIConfirmationTests {
    static func entry(_ key: String, reversible: Bool, tier: CleanupTier, selectable: Bool = true) -> CleanupEntry {
        var e = CleanupEntry(id: "id-" + key, title: "title-" + key, size: 10, estimateIsApprox: false, evidence: "fixture",
            actionLabel: "", reversible: reversible, risk: .green, selectable: selectable, defaultChecked: false, source: "fixture")
        e.tier = tier
        return e
    }

    /// 记录输出和提示，按预设的答案依次回答
    final class Console {
        var output = "", prompts: [String] = [], answers: [String?]
        init(_ answers: [String?]) { self.answers = answers }
        func emit(_ text: String) { output += text }
        func prompt(_ text: String) -> String? { prompts.append(text); return answers.isEmpty ? nil : answers.removeFirst() }
    }

    static func run(_ entries: [CleanupEntry], yes: Bool = false, interactive: Bool = true, answers: [String?]) -> (Console, String?) {
        let console = Console(answers)
        do {
            try CLIConfirmation.confirmClean(entries, yes: yes, interactive: interactive, emit: console.emit, prompt: console.prompt)
            return (console, nil)
        } catch { return (console, "\(error)") }
    }

    static func main() throws {
        let move = entry("move", reversible: true, tier: .rebuildable)
        let del = entry("del", reversible: false, tier: .review)
        let toolA = entry("npm", reversible: false, tier: .rebuildable)   // A/B 档的不可撤回项，例如 npm 缓存

        // 顺序：先 MOVE 后 DELETE，两次都通过才返回
        var (c, err) = run([del, move], answers: ["MOVE", "DELETE"])
        precondition(err == nil, "\(err ?? "")")
        precondition(c.prompts.count == 2 && c.prompts[0].contains("MOVE") && c.prompts[1].contains("DELETE"), "\(c.prompts)")
        let moveAt = c.output.range(of: CLIConfirmation.moveHeading)!.lowerBound, delAt = c.output.range(of: CLIConfirmation.deleteHeading)!.lowerBound
        precondition(moveAt < delAt, "MOVE preview must come before DELETE preview")
        precondition(!c.output.contains("id-del") || c.output.range(of: "id-del")!.lowerBound > delAt, "irreversible row only under the DELETE heading")
        precondition(c.output.range(of: "id-move")!.lowerBound < delAt, "reversible row only under the MOVE heading")

        // MOVE 通过但 DELETE 被取消：抛错（调用方因此不执行任何东西）
        (c, err) = run([move, del], answers: ["MOVE", "no"])
        precondition(err?.contains("已取消") == true && c.prompts.count == 2, "\(err ?? "none")")
        // MOVE 就取消：不会再问 DELETE
        (c, err) = run([move, del], answers: ["move"])
        precondition(err?.contains("已取消") == true && c.prompts.count == 1, "\(c.prompts)")
        // 输入流结束（读不到）也算取消
        (c, err) = run([del], answers: [nil])
        precondition(err?.contains("已取消") == true)

        // 非交互且没有 --yes：拒绝，且根本没有提示
        (c, err) = run([move, del], interactive: false, answers: ["MOVE", "DELETE"])
        precondition(err?.contains("非交互终端未执行") == true && c.prompts.isEmpty, "\(err ?? "none") \(c.prompts)")

        // --yes：不提示，预览仍显示
        (c, err) = run([move, del], yes: true, interactive: false, answers: [])
        precondition(err == nil && c.prompts.isEmpty && c.output.contains("id-move") && c.output.contains("id-del"), "\(err ?? "")")

        // 只有一类时只问一次
        (c, err) = run([del], answers: ["DELETE"])
        precondition(err == nil && c.prompts.count == 1 && c.prompts[0].contains("DELETE"))
        (c, err) = run([move], answers: ["MOVE"])
        precondition(err == nil && c.prompts.count == 1 && c.prompts[0].contains("MOVE"))

        // 预览：只有 C 档（review）行放在“以下为确认后清的项目：”下；A 档不可撤回的 npm 行不在其下
        let text = CLIConfirmation.preview([move, toolA, del])
        let heading = text.range(of: CLIConfirmation.reviewHeading)!
        precondition(text.range(of: "id-del")!.lowerBound > heading.upperBound, "review row listed under the heading")
        precondition(text.range(of: "id-move")!.lowerBound < heading.lowerBound && text.range(of: "id-npm")!.lowerBound < heading.lowerBound,
                     "non-review rows (including an irreversible A-tier row) stay above the heading")
        precondition(!CLIConfirmation.preview([move, toolA]).contains(CLIConfirmation.reviewHeading), "no heading without review rows")
        precondition(!CLIConfirmation.preview([entry("lockedReview", reversible: false, tier: .review, selectable: false)]).contains(CLIConfirmation.reviewHeading),
                     "non-selectable rows are never offered under the confirm heading")
        // 确认提示里 A 档不可撤回项不使用“确认后清”标题
        (c, _) = run([toolA], yes: true, answers: [])
        precondition(!c.output.contains(CLIConfirmation.reviewHeading) && c.output.contains(CLIConfirmation.deleteHeading))
        print("CLI confirmation sequence ok")
    }
}
