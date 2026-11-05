// SPDX-License-Identifier: MPL-2.0
import Foundation

/// `roomy clean` 预览的六段报告：结论、空间去向、读不到的空间、分档清单、健康提醒、清理顺序。
/// 与图形界面同序同口径；健康提醒里的命令只是给用户看的文字，Roomy 不会运行。
enum CLIReport {
    static let titles = ["结论", "空间去向", "读不到的空间", "分档清单", "健康提醒", "清理顺序"]
    static let fullDiskAccessHint = "在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中勾选腾地儿后重新扫描"
    static let orderSteps = ["先处理可找回的部分，用一两天确认没问题", "再在 Finder 清空废纸篓", "不可撤回的放最后"]

    struct Inputs {
        var overview: SpaceOverview?
        var overviewError: String?
        var health: [HealthFinding]
        var free: UInt64?
    }

    /// 报告要的数据。数据卷可用空间和健康提醒很快，总是取；空间去向要走一遍磁盘（可能几分钟），
    /// 只在 wantOverview 时做，并先在进度里说一声。健康检查与遍历并行。遍历、取用量、健康检查都由调用方注入，方便测试
    static func gather(wantOverview: Bool, home: String, usage: () -> (used: UInt64, free: UInt64)?,
                       walk: () -> (rootTotals: [String: UInt64], unreadable: [String]),
                       health: @escaping () -> [HealthFinding], progress: (String) -> Void) -> Inputs {
        final class Box: @unchecked Sendable { var findings: [HealthFinding] = [] }
        let box = Box(), group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) { box.findings = health() }
        var walked: (rootTotals: [String: UInt64], unreadable: [String])?
        if wantOverview {
            progress("正在统计空间去向，可能需要几分钟…（加 --no-overview 跳过）")
            walked = walk()
        }
        group.wait()
        let volume = usage()
        var inputs = Inputs(overview: nil, overviewError: nil, health: box.findings, free: volume?.free)
        guard let walked else { return inputs }
        guard let volume else { inputs.overviewError = "无法读取数据卷的用量"; return inputs }
        inputs.overview = SpaceOverview.compute(dataUsed: volume.used, free: volume.free, areaSizes: walked.rootTotals,
            unreadable: SpaceOverview.unreadableHints(home: home, walkUnreadable: walked.unreadable), home: home)
        return inputs
    }

    /// entries：整份清单（算结论用）；shown：本次要列出的项（`--id` 过滤后）。
    /// overview 为 nil 表示量不出来（overviewError 说明原因）；free 为 nil 表示数据卷可用空间读不到
    static func preview(entries: [CleanupEntry], shown: [CleanupEntry], overview: SpaceOverview?, overviewError: String?, overviewSkipped: String? = nil,
                        health: [HealthFinding], pendingTrash: (count: Int, bytes: UInt64), free: UInt64?,
                        home: String) throws -> (data: [String: Any], text: String) {
        // 现在可用：数据卷可用空间；没单独给就用空间去向里量到的
        let currentFree = free ?? overview?.free
        let summary = ReportSummary.compute(entries: entries, free: currentFree)
        var data: [String: Any] = ["entries": try cliObject(shown), "health": try cliObject(health), "summary": try cliObject(summary),
                                   "overview": try overview.map { try cliObject($0) } ?? NSNull()]
        if overview == nil {
            if overviewSkipped != nil { data["overviewSkipped"] = true } else { data["overviewError"] = overviewError ?? "无法测量" }
        }

        func section(_ title: String, _ lines: [String]) -> String { "== \(title) ==\n" + lines.joined(separator: "\n") }
        let tierLabels: [(CleanupTier, String)] = [(.obsolete, "A 放心清"), (.rebuildable, "B 可选清"), (.review, "C 确认后清")]
        var conclusion = [currentFree.map { "现在可用 \(cliBytes($0))" } ?? "现在可用：无法测量"]
        conclusion += tierLabels.map { tier, label -> String in
            guard let t = summary.tiers.first(where: { $0.key == tier.rawValue }) else { return label }
            let split = t.reversibleBytes + t.permanentBytes > 0
                ? "（可找回 \(cliBytes(t.reversibleBytes)) · 找不回 \(cliBytes(t.permanentBytes))）" : ""
            return "\(label)  \(t.approx ? "约 " : "")\(cliBytes(t.bytes))\(split)"
        }
        if let a = summary.freeAfterA, let ab = summary.freeAfterAB {
            conclusion.append("只清 A 后约 \(cliBytes(a))" + (summary.trashNote.isEmpty ? "" : "，" + summary.trashNote))
            conclusion.append("清 A+B 后约 \(cliBytes(ab))" + (summary.trashNoteAB.isEmpty ? "" : "，" + summary.trashNoteAB))
            conclusion.append("移入废纸篓的空间不会马上变成可用空间，要清空废纸篓后才释放。")
        } else {
            conclusion.append("清理后的可用空间：无法测量（读不到数据卷的可用空间）")
        }

        func shownPath(_ path: String) -> String {
            cliSafeText(path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        }
        var space: [String], unreadable: [String]
        if let overview {
            space = ["数据卷已用 \(cliBytes(overview.dataUsed))，可用 \(cliBytes(overview.free))"]
                + overview.areas.map { "\(cliBytes($0.bytes))  \(shownPath($0.path))" }
            unreadable = ["未归到任何区域：约 \(cliBytes(overview.unattributed))（读不到的、系统管理的、或区域外的）"]
                + overview.unreadableHints.map { "无权读取：\(shownPath($0))" }
            if overview.unreadableSystemCount > 0 { unreadable.append("另有 \(overview.unreadableSystemCount) 个系统目录无权读取") }
            unreadable.append(fullDiskAccessHint)
        } else if let skipped = overviewSkipped {
            space = ["未统计（\(cliSafeText(skipped))）"]
            unreadable = ["未统计（\(cliSafeText(skipped))）"]
        } else {
            let why = cliSafeText(overviewError ?? "")
            space = ["无法测量" + (why.isEmpty ? "" : "：" + why)]
            unreadable = ["无法测量"]
        }

        var tiers = tierLabels.map { tier, label in "\(label)：\(shown.filter { ($0.tier ?? .review) == tier }.count) 项" }
        tiers.append("不能删：\(shown.filter { $0.tier == .locked }.count) 项")
        let list = CLIConfirmation.preview(shown)
        let healthLines: [String] = health.isEmpty ? ["没有发现需要留意的问题"] : health.flatMap { f -> [String] in
            var lines = ["\(cliSafeText(f.title))：\(cliSafeText(f.detail))", "  \(cliSafeText(f.advice))"]
            if let command = f.command { lines.append("  命令（仅供参考，Roomy 不会运行）：\(cliSafeText(command))") }
            return lines
        }
        let order = orderSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }
            + [pendingTrash.count > 0 ? "Roomy 已移入废纸篓、待清空：\(pendingTrash.count) 项 · \(cliBytes(pendingTrash.bytes))"
                                      : "Roomy 目前没有移入废纸篓、待清空的项目"]

        let text = [section(titles[0], conclusion), section(titles[1], space), section(titles[2], unreadable),
                    section(titles[3], tiers + (list.isEmpty ? [] : ["", list])), section(titles[4], healthLines),
                    section(titles[5], order)].joined(separator: "\n\n")
        return (data, text)
    }
}
