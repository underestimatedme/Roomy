// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `clean --apply` 的确认序列。读取输入和判断终端都由调用方注入，方便测试。
enum CLIConfirmation {
    static let reviewHeading = "以下为确认后清的项目："
    static let moveHeading = "准备移入废纸篓（可找回）："
    static let deleteHeading = "准备永久删除（找不回）："

    /// 预览文字：C 档（需确认，.review）项单列在标题下；其余在前
    static func preview(_ entries: [CleanupEntry]) -> String {
        let review = entries.filter { $0.selectable && $0.tier == .review }
        let rest = entries.filter { !($0.selectable && $0.tier == .review) }
        return [rest.isEmpty ? nil : cliEntries(rest),
                review.isEmpty ? nil : reviewHeading + "\n" + cliEntries(review)].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// 单步确认：显示预览；--yes 直接通过；非交互终端拒绝；否则要求原样输入 verb
    static func confirm(preview: String, verb: String, yes: Bool, interactive: Bool,
                        emit: (String) -> Void, prompt: (String) -> String?) throws {
        emit(preview + "\n")
        if yes { return }
        guard interactive else { throw cliError("非交互终端未执行；明确选择后使用 --apply --yes") }
        guard prompt("输入 \(verb) 确认，其他输入取消：") == verb else { throw cliError("已取消，未处理任何文件") }
    }

    /// 先确认可找回项（MOVE），再确认不可撤回项（DELETE）；任一步失败都抛错，调用方在此之后才可执行
    static func confirmClean(_ selected: [CleanupEntry], yes: Bool, interactive: Bool,
                             emit: (String) -> Void, prompt: (String) -> String?) throws {
        let movable = selected.filter(\.reversible), permanent = selected.filter { !$0.reversible }
        if !movable.isEmpty {
            try confirm(preview: moveHeading + "\n" + cliEntries(movable), verb: "MOVE",
                        yes: yes, interactive: interactive, emit: emit, prompt: prompt)
        }
        if !permanent.isEmpty {
            try confirm(preview: deleteHeading + "\n" + cliEntries(permanent) + "\n这些项目由工具直接删除，不进废纸篓，无法找回。",
                        verb: "DELETE", yes: yes, interactive: interactive, emit: emit, prompt: prompt)
        }
    }
}
