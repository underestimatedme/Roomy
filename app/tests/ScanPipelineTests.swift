// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct ScanPipelineTests {
    static func main() throws {
        // ── 缓存：只存展示数据，读回一致；损坏或版本不对返回 nil
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let entry = CleanupCandidate(source: "rule", key: "/x", title: "t", size: 5, evidence: "e", risk: .green,
            action: .trash(item: ScanItem.trashTarget(path: "/x", name: "x", size: 5, rule: "r", evidence: "e", risk: .green))).entry
        let entryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        CleanupCache.save(["entries": [entryJSON], "disk": ["total": 1, "free": 2]], to: tmp)
        let loaded = CleanupCache.load(from: tmp)!
        precondition(loaded["scannedAt"] is String && loaded["version"] as? Int == CleanupCache.version)
        let back = (loaded["entries"] as! [[String: Any]])[0]
        precondition(Set(back.keys) == Set(entryJSON.keys), "cache holds display fields only: \(back.keys.sorted())")
        try Data("{not json".utf8).write(to: tmp)
        precondition(CleanupCache.load(from: tmp) == nil)
        try JSONSerialization.data(withJSONObject: ["version": 999, "entries": []]).write(to: tmp)
        precondition(CleanupCache.load(from: tmp) == nil)

        // ── 流水线：阶段顺序 discover → measure → assemble，每段都有 running 和 done（真实机器，只读）
        var log: [String] = []
        let result = ScanPipeline.run { stage, state, _ in log.append("\(stage):\(state)") }
        precondition(log == ["discover:running", "discover:done", "measure:running", "measure:done",
                             "assemble:running", "assemble:done"], "\(log)")
        precondition(!result.items.isEmpty)
        // 完整遍历（给"看不懂的大目录"）放在清单之后单独跑
        precondition(!ScanPipeline.folderSizes(roots: result.sizeRoots).isEmpty)
        precondition(!result.probes.contains { $0.entry.size == ToolProbes.placeholder }, "no placeholder leaks out")
        print("ScanPipelineTests passed")
    }
}
