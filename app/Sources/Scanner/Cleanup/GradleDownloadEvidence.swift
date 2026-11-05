// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

/// Gradle's downloaded artifact store: group/module/version/SHA-1/artifact.
/// Each module is an independent unit; metadata, transforms and the mixed cache
/// parent remain untouched. SHA-1 identifies cached bytes, not publisher trust.
enum GradleDownloadEvidence {
    private static let marker = "/.gradle/caches/modules-2/files-2.1/"

    static func inspect(_ item: ScanItem, runner: CommandRunning) -> CleanupEvidenceDecision {
        guard let before = CacheActivitySnapshot.capture(runner: runner) else {
            return review("无法完整检查 Gradle 与文件占用，保留此项")
        }
        let result = verify(item, activity: before, deadline: Date().addingTimeInterval(20))
        guard result.allowed else { return result }
        guard let after = CacheActivitySnapshot.capture(runner: runner),
              !after.blocks(path: item.path, family: .gradle), unchanged(path: item.path, proof: result.snapshot) else {
            return review("检查期间 Gradle 状态或缓存内容发生变化，请结束任务后重新扫描")
        }
        return result
    }

    static func children(of parent: ScanItem, runner: CommandRunning) -> [ScanItem] {
        guard parent.path.hasSuffix("/.gradle/caches") else { return [] }
        let root = parent.path + "/modules-2/files-2.1"
        let fm = FileManager.default
        guard let groups = try? fm.contentsOfDirectory(atPath: root), groups.count <= 5_000 else { return [] }
        var units: [String] = []
        for group in groups.sorted() where coordinate(group) {
            guard let modules = try? fm.contentsOfDirectory(atPath: root + "/" + group),
                  modules.count <= 10_000, units.count + modules.count <= 10_000 else { return [] }
            units += modules.filter(coordinate).map { group + "/" + $0 }
        }
        return ContentCacheBatch.children(root: root, rule: "Gradle 下载缓存", title: "Gradle 依赖下载",
            family: .gradle, runner: runner, relativePaths: units,
            verify: { verify($0, activity: $1, deadline: $2) },
            recheck: { unchanged(path: $0.path, proof: $0.cleanupEvidence) })
    }

    private static func verify(_ item: ScanItem, activity: CacheActivitySnapshot, deadline: Date) -> CleanupEvidenceDecision {
        guard Date() < deadline, !activity.blocks(path: item.path, family: .gradle) else {
            return review("Gradle 或其后台进程仍在运行，或此依赖文件被打开；结束任务后可重新扫描")
        }
        guard let boundary = item.path.range(of: marker, options: .backwards) else { return review("不是受支持的 Gradle 下载内容路径") }
        let components = String(item.path[boundary.upperBound...]).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2, components.allSatisfy(coordinate),
              let tree = CleanupEvidence.inventory(item.path), tree.bytes <= CacheContent.byteLimit else {
            return review("Gradle 下载清单不完整、含链接或超过校验限额；保留此项")
        }
        var artifacts = Set<String>(), count = 0
        for entry in tree.entries {
            guard Date() < deadline else { return review("Gradle 内容校验超过时限，请重新扫描") }
            let parts = entry.relative.split(separator: "/").map(String.init)
            if entry.directory {
                guard (parts.count == 1 && coordinate(parts[0])) ||
                    (parts.count == 2 && coordinate(parts[0]) && checksum(parts[1])) else {
                    return review("Gradle 下载目录包含未知子项，保留整个模块")
                }
                continue
            }
            guard parts.count == 3, coordinate(parts[0]), checksum(parts[1]),
                  artifacts.insert(parts[0] + "/" + parts[1]).inserted,
                  let digest = CacheContent.digest(Insecure.SHA1.self, path: item.path + "/" + entry.relative,
                      deadline: min(deadline, Date().addingTimeInterval(12))),
                  digest == String(repeating: "0", count: 40 - parts[1].count) + parts[1] else {
                return review("Gradle 下载内容与 SHA-1 不符或包含未知文件，可能有本地改动；保留整个模块")
            }
            count += 1
        }
        guard count > 0, Date() < deadline, CleanupEvidence.inventory(item.path)?.fingerprint == tree.fingerprint else {
            return review("没有可核实的 Gradle 下载内容，或校验期间内容发生变化")
        }
        return .init(reason: "Gradle 下载内容逐文件 SHA-1 与完整清单已核实，未发现 Gradle 进程或实际文件占用；执行前再次核验。下次构建需重新下载，离线或原仓库不可用时会失败",
            snapshot: .init(version: 1, fingerprint: tree.fingerprint, kind: "gradleDownload", newestModifiedAt: tree.newestModifiedAt),
            inspectedBytes: tree.bytes)
    }

    private static func coordinate(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.+\-]*$"#, options: .regularExpression) != nil
    }
    private static func checksum(_ text: String) -> Bool {
        // Gradle uses compact hexadecimal SHA-1 names, omitting leading zeroes.
        !text.isEmpty && text.count <= 40 && CacheContent.isHex(text, count: text.count)
    }
    private static func unchanged(path: String, proof: CleanupEvidenceSnapshot?) -> Bool {
        guard let proof, proof.kind == "gradleDownload", let tree = CleanupEvidence.inventory(path) else { return false }
        return proof.fingerprint == tree.fingerprint
    }
    private static func review(_ reason: String) -> CleanupEvidenceDecision { .init(reason: reason, snapshot: nil) }
}
