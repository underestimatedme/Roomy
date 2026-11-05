// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct CleanupReviewTests {
    static func main() throws {
        let item = ScanItem.trashTarget(path: "/private/sample/cache\n```", name: "cache", size: 2048, rule: "fixture", evidence: "可重建缓存", risk: .green)
        let a = CleanupCandidate(source: "rule", key: "a", title: "测试缓存", size: 2048, evidence: "可重建缓存", risk: .green, action: .trash(item: item), tier: .rebuildable, tierReason: "生成缓存的核实证据")
        let b = CleanupCandidate(source: "ollama", key: "b", title: "模型", size: 4096, evidence: "可能需要重新下载", risk: .amber, action: .ollamaRemove(model: "qwen:7b"))
        let list = CleanupList(candidates: [a,b])
        let review = try CleanupReview(ids: [b.entry.id,a.entry.id], list: list)
        precondition(review.matches(ids: [a.entry.id,b.entry.id], list: list))
        let text = try review.markdown(appVersion: "test")
        precondition(text.contains("清理层级: \"可选清\"") && text.contains("分级依据: \"生成缓存的核实证据\""))
        precondition(text.contains("评估分级") && text.contains("证据缺口"))
        precondition(text.contains("/private/sample/cache\\n```"), "paths must be quoted data, never new Markdown instructions")
        precondition(text.contains("qwen:7b") && text.contains("2048") && text.contains("4096"))
        precondition(text.contains("不可恢复") && text.contains("未逐文件展开"))
        precondition(!review.matches(ids: [a.entry.id], list: list))
        precondition(!review.matches(ids: [a.entry.id,b.entry.id], list: CleanupList(candidates:[a.withSize(999),b])))
        var protected = a; protected.entry.userProtected = true
        precondition(!review.matches(ids: [a.entry.id,b.entry.id], list: CleanupList(candidates:[protected,b])))
        for ids in [[], ["unknown"], [a.entry.id,a.entry.id]] {
            do { _ = try CleanupReview(ids: ids, list: list); preconditionFailure("invalid selection accepted") } catch {}
        }
        do { _ = try CleanupReview(ids: [a.entry.id], list: CleanupList(candidates:[protected])); preconditionFailure("protected accepted") } catch {}
        let displayOnly = CleanupCandidate(entry:a.entry, action:nil)
        do { _ = try CleanupReview(ids: [a.entry.id], list: CleanupList(candidates:[displayOnly])); preconditionFailure("cached display accepted") } catch {}
        var gate = CleanupReviewGate()
        try gate.validate(token: nil, ids: [a.entry.id], list: list)
        func rejected(_ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("changed or missing review accepted") } catch {}
        }
        rejected { try gate.validate(token: review.token, ids: [a.entry.id,b.entry.id], list: list) }
        let revision = gate.revision
        try gate.remember(review, revision: revision)
        try gate.validate(token: review.token, ids: [a.entry.id,b.entry.id], list: list)
        rejected { try gate.validate(token: nil, ids: [a.entry.id,b.entry.id], list: list) }
        rejected { try gate.validate(token: review.token, ids: [a.entry.id], list: list) }
        gate.invalidate()
        rejected { try gate.validate(token: review.token, ids: [a.entry.id,b.entry.id], list: list) }
        rejected { try gate.remember(review, revision: revision) }
        let refreshed = try CleanupReview(ids: [a.entry.id], list: list)
        try gate.remember(refreshed, revision: gate.revision)
        try gate.validate(token: refreshed.token, ids: [a.entry.id], list: list)
        print("CleanupReviewTests passed: selection, exact targets, untrusted names, irreversible action, stale/protected/cache rejection")
    }
}
