// SPDX-License-Identifier: MPL-2.0
import Foundation

enum CLISelection {
    static func identityKey(_ identity: CleanupIdentity?) -> String {
        guard let identity else { return "unknown" }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(identity)).map { String(decoding: $0, as: UTF8.self) } ?? "unknown"
    }

    /// IDs shown by the CLI bind the previewed object, not merely its pathname.
    static func scoped(_ list: CleanupList, context: String = "") -> CleanupList {
        var result = list
        result.candidates = list.candidates.map { candidate in
            let identity: CleanupIdentity?
            let evidenceKey: String
            switch candidate.action {
            case .trash(let item)?, .worktreeRemove(let item, _, _, _)?, .launchAgentRemove(_, let item)?:
                identity = item.identity
                evidenceKey = item.cleanupEvidence.map { "\($0.version):\($0.fingerprint)" } ?? "no evidence"
            default:
                identity = candidate.entry.path.flatMap { CleanupIdentity.capture(path: $0) }
                evidenceKey = "no evidence"
            }
            let ancestors = candidate.entry.path.flatMap { path in
                ApplicationAssociations.directoryIdentities(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            }
            let parentKey = ancestors?.sorted { $0.0 < $1.0 }.map {
                "\($0.0):\($0.1.deviceID):\($0.1.fileID)"
            }.joined(separator: "\n") ?? "unknown parents"
            let e = candidate.entry
            let id = CleanupCandidate.stableID("cli-preview", e.id + "\u{0}" + context + "\u{0}" + identityKey(identity) + "\u{0}" + parentKey + "\u{0}" + evidenceKey)
            // 不可撤回项（工具清理、docker rm 等）也可选，由 CLI 另行要求 DELETE 确认；锁定项永远不可选。
            // 带路径的项仍须能核实对象身份；没有路径的不可撤回项（如 docker 对象）靠执行前的对象核对
            let bound = e.path == nil ? !e.reversible : (identity != nil && ancestors != nil)
            let eligible = e.selectable && e.tier != .locked && bound
            // 整份复制再改 ID 和可选状态：safetyHold、lockReason 等字段不能在 CLI 里丢掉
            var entry = e
            entry.id = id
            entry.selectable = eligible
            entry.defaultChecked = eligible && e.defaultChecked
            return CleanupCandidate(entry: entry, action: candidate.action)
        }
        return result
    }
}
