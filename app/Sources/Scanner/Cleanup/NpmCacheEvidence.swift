// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Darwin
import Foundation

/// npm's cacache content-v2 stores blobs under their SHA-512 digest. Only
/// independently verified buckets qualify; the mixed index/tmp parent does not.
enum NpmCacheEvidence {
    static func inspect(_ item: ScanItem, runner: CommandRunning) -> CleanupEvidenceDecision {
        guard let before = CacheActivitySnapshot.capture(runner: runner) else {
            return .init(reason: "无法完整检查包管理器与文件占用，保留此项", snapshot: nil)
        }
        let decision = verify(item, activity: before, deadline: Date().addingTimeInterval(20))
        guard decision.allowed else { return decision }
        guard let after = CacheActivitySnapshot.capture(runner: runner), !after.blocks(path: item.path, family: .npm) else {
            return .init(reason: "检查期间出现安装任务或缓存被打开，请稍后重新扫描", snapshot: nil)
        }
        guard unchanged(path: item.path, proof: decision.snapshot) else {
            return .init(reason: "最终占用检查期间缓存内容发生变化，请重新扫描", snapshot: nil)
        }
        return decision
    }

    private static func verify(_ item: ScanItem, activity: CacheActivitySnapshot, deadline: Date) -> CleanupEvidenceDecision {
        func review(_ reason: String) -> CleanupEvidenceDecision { .init(reason: reason, snapshot: nil) }
        guard !activity.blocks(path: item.path, family: .npm) else {
            return review("正在安装依赖或此缓存被实际打开；结束任务后可重新扫描")
        }
        guard item.path.range(of: #"/\.npm/_cacache/content-v2/sha512/[0-9a-f]{2}$"#,
            options: .regularExpression) != nil else {
            return review("npm 索引与临时目录尚未逐项核实；仅单独检查 SHA-512 下载内容子项")
        }
        guard let tree = CleanupEvidence.inventory(item.path), tree.bytes <= CacheContent.byteLimit else {
            return review("npm 内容检查不完整、含链接或超过校验限额；保留此项")
        }
        let prefix = URL(fileURLWithPath: item.path).lastPathComponent
        let readDeadline = min(deadline, Date().addingTimeInterval(12))
        var files = 0
        for entry in tree.entries {
            let parts = entry.relative.split(separator: "/").map(String.init)
            if entry.directory {
                guard parts.count == 1, CacheContent.isHex(parts[0], count: 2) else { return review("npm 内容目录有未识别的子项，保留整个分区") }
                continue
            }
            guard parts.count == 2, CacheContent.isHex(parts[0], count: 2), CacheContent.isHex(parts[1], count: 124),
                  let digest = CacheContent.digest(SHA512.self, path: item.path + "/" + entry.relative, deadline: readDeadline),
                  digest == prefix + parts[0] + parts[1] else {
                return review("npm 内容哈希不匹配或包含未知文件，可能有本地改动；保留整个分区")
            }
            files += 1
        }
        guard files > 0, Date() < deadline, CleanupEvidence.inventory(item.path)?.fingerprint == tree.fingerprint else {
            return review("没有可核验的内容，或检查期间内容/运行状态发生变化，请重新扫描")
        }
        return .init(reason: "npm 下载内容 SHA-512 与完整清单已核验，未发现安装任务或实际文件占用；执行前再次核验。下次安装需重新下载，依赖源不可用时可能失败",
            snapshot: .init(version: 1, fingerprint: tree.fingerprint, kind: "npmCache", newestModifiedAt: tree.newestModifiedAt),
            inspectedBytes: tree.bytes)
    }

    static func children(of item: ScanItem, runner: CommandRunning) -> [ScanItem] {
        ContentCacheBatch.children(root: item.path + "/content-v2/sha512", rule: "npm 下载缓存", title: "npm 下载内容",
            family: .npm, runner: runner, verify: { unit, activity, deadline in
                verify(unit, activity: activity, deadline: deadline)
            }, recheck: { unchanged(path: $0.path, proof: $0.cleanupEvidence) })
    }

    private static func unchanged(path: String, proof: CleanupEvidenceSnapshot?) -> Bool {
        guard let proof, proof.kind == "npmCache", let tree = CleanupEvidence.inventory(path) else { return false }
        return tree.fingerprint == proof.fingerprint
    }
}
