// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

enum GoBuildCacheEvidence {
    static func inspect(_ item: ScanItem, runner: CommandRunning) -> CleanupEvidenceDecision {
        guard let before = CacheActivitySnapshot.capture(runner: runner) else {
            return .init(reason: "无法完整检查 Go 构建与缓存文件占用，保留此项", snapshot: nil)
        }
        let decision = verify(item, activity: before, deadline: Date().addingTimeInterval(20))
        guard decision.allowed else { return decision }
        guard let after = CacheActivitySnapshot.capture(runner: runner), !after.blocks(path: item.path, family: .go) else {
            return .init(reason: "Go 构建已开始或缓存被实际打开，请稍后重新扫描", snapshot: nil)
        }
        guard unchanged(path: item.path, proof: decision.snapshot) else {
            return .init(reason: "最终占用检查期间 Go 缓存或标识发生变化，请重新扫描", snapshot: nil)
        }
        return decision
    }

    private static func verify(_ item: ScanItem, activity: CacheActivitySnapshot, deadline: Date) -> CleanupEvidenceDecision {
        func review(_ text: String) -> CleanupEvidenceDecision { .init(reason: text, snapshot: nil) }
        guard !activity.blocks(path: item.path, family: .go) else { return review("Go 正在构建或此缓存被实际打开，保留此项") }
        guard item.path.range(of: #"/Library/Caches/go-build/[0-9a-f]{2}$"#, options: .regularExpression) != nil else {
            return review("Go 构建缓存父目录保留；仅单独核实内容地址分区，不处理源码模块缓存")
        }
        let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        guard let marker = CacheContent.smallData(parent + "/README"),
              String(decoding: marker, as: UTF8.self).hasPrefix("This directory holds cached build artifacts from the Go build system."),
              let tree = CleanupEvidence.inventory(item.path), tree.bytes <= CacheContent.byteLimit else {
            return review("缺少 Go 缓存标识，或目录检查不完整、含链接、超过校验限额，保留此项")
        }
        let prefix = URL(fileURLWithPath: item.path).lastPathComponent
        let readDeadline = min(deadline, Date().addingTimeInterval(12))
        var files = 0
        for entry in tree.entries {
            let name = entry.relative
            guard !entry.directory, name.utf8.count == 66, !name.contains("/"),
                  CacheContent.isHex(String(name.prefix(64)), count: 64), name.hasPrefix(prefix) else {
                return review("Go 缓存分区包含未识别内容，保留整个分区")
            }
            let path = item.path + "/" + name
            if name.hasSuffix("-d") {
                guard CacheContent.digest(SHA256.self, path: path, deadline: readDeadline) == String(name.prefix(64)) else {
                    return review("Go 生成内容摘要不匹配或读取超时，保留整个分区")
                }
            } else if name.hasSuffix("-a") {
                guard let data = CacheContent.smallData(path, limit: 175), validAction(data, id: String(name.prefix(64))) else {
                    return review("Go v1 构建索引格式不匹配，保留整个分区")
                }
            } else { return review("Go 缓存出现未知文件类型，保留整个分区") }
            files += 1
        }
        guard files > 0, Date() < deadline, CleanupEvidence.inventory(item.path)?.fingerprint == tree.fingerprint,
              CacheContent.smallData(parent + "/README") == marker else {
            return review("Go 缓存或标识在检查期间发生变化，请重新扫描")
        }
        let fingerprint = SHA256.hash(data: Data(tree.fingerprint.utf8) + marker).map { String(format: "%02x", $0) }.joined()
        return .init(reason: "已核验 Go 缓存标识、v1 构建索引与生成内容 SHA-256；未发现正在构建或实际文件占用。清理后再次编译会变慢",
            snapshot: .init(version: 1, fingerprint: fingerprint, kind: "goBuildCache", newestModifiedAt: tree.newestModifiedAt),
            inspectedBytes: tree.bytes)
    }

    private static func validAction(_ data: Data, id: String) -> Bool {
        let bytes = Array(data)
        guard bytes.count == 175, bytes.allSatisfy({ $0 < 128 }), Array(bytes[0..<3]) == Array("v1 ".utf8),
              bytes[67] == 32, bytes[132] == 32, bytes[153] == 32, bytes[174] == 10 else { return false }
        let action = String(decoding: bytes[3..<67], as: UTF8.self)
        let output = String(decoding: bytes[68..<132], as: UTF8.self)
        let size = String(decoding: bytes[133..<153].drop(while: { $0 == 32 }), as: UTF8.self)
        let time = String(decoding: bytes[154..<174].drop(while: { $0 == 32 }), as: UTF8.self)
        guard !size.isEmpty, !time.isEmpty, size.utf8.allSatisfy({ (48...57).contains($0) }),
              time.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return action == id && CacheContent.isHex(output, count: 64) && (Int64(size).map { $0 >= 0 } ?? false) &&
            (Int64(time).map { $0 >= 0 } ?? false)
    }

    /// 只看布局（不读内容）：README 是 Go 的缓存标识，其余顶层条目只有两位十六进制分区和 Go 自己的记录文件
    static func hasCacheLayout(_ path: String) -> Bool {
        guard let marker = CacheContent.smallData(path + "/README"),
              String(decoding: marker, as: UTF8.self).hasPrefix("This directory holds cached build artifacts from the Go build system."),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.allSatisfy { name in
            var st = stat()
            guard lstat(path + "/" + name, &st) == 0 else { return false }
            let kind = st.st_mode & S_IFMT
            if ["README", "trim.txt", "testexpire.txt"].contains(name) { return kind == S_IFREG }
            return kind == S_IFDIR && CacheContent.isHex(name, count: 2)
        }
    }

    static func children(of item: ScanItem, runner: CommandRunning) -> [ScanItem] {
        guard item.path.hasSuffix("/Library/Caches/go-build") else { return [] }
        return ContentCacheBatch.children(root: item.path, rule: "Go 生成缓存", title: "Go 构建内容", family: .go,
            runner: runner, verify: { unit, activity, deadline in verify(unit, activity: activity, deadline: deadline) },
            recheck: { unchanged(path: $0.path, proof: $0.cleanupEvidence) })
    }

    private static func unchanged(path: String, proof: CleanupEvidenceSnapshot?) -> Bool {
        guard let proof, proof.kind == "goBuildCache", let tree = CleanupEvidence.inventory(path),
              let marker = CacheContent.smallData(URL(fileURLWithPath: path).deletingLastPathComponent().path + "/README") else { return false }
        let fingerprint = SHA256.hash(data: Data(tree.fingerprint.utf8) + marker).map { String(format: "%02x", $0) }.joined()
        return fingerprint == proof.fingerprint
    }
}
