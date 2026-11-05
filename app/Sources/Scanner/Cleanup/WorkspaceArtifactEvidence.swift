// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

/// Narrow units only: a Flutter kernel output file or one rustc incremental
/// crate cache. Never grants a Trash action for build/, target/ or .dart_tool/.
enum WorkspaceArtifactEvidence {
    static let rules: Set<String> = ["工作空间构建目录", "Rust 构建产物", "Flutter 编译快照", "Rust 增量缓存"]

    private struct State {
        let project: String
        let kind: String
        let fingerprint: String
        let bytes: UInt64
        let modified: Int64
        let records: [Data]
        let tree: CleanupEvidence.Inventory?
    }

    static func inspect(_ item: ScanItem, runner: CommandRunning) -> CleanupEvidenceDecision {
        guard let before = CacheActivitySnapshot.capture(runner: runner) else { return review("无法完整检查构建任务与文件占用，保留此项") }
        let decision = verify(item, activity: before, runner: runner, deadline: Date().addingTimeInterval(20))
        guard decision.allowed else { return decision }
        guard let after = CacheActivitySnapshot.capture(runner: runner), !after.blocks(path: item.path, family: family(item)),
              unchanged(item, proof: decision.snapshot, runner: runner) else {
            return review("检查期间产物、项目记录或占用发生变化，请结束构建后重新扫描")
        }
        return decision
    }

    static func children(of parent: ScanItem, runner: CommandRunning) -> [ScanItem] {
        var paths: [(String, String)] = []
        let fm = FileManager.default
        if parent.rule == "工作空间构建目录", (parent.path as NSString).lastPathComponent == ".dart_tool" {
            let root = parent.path + "/flutter_build"
            for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where CacheContent.isHex(name, count: 32) {
                paths.append((root + "/" + name + "/app.dill", "Flutter 编译快照"))
            }
        } else if parent.rule == "Rust 构建产物" {
            var profiles = [parent.path + "/debug", parent.path + "/release"]
            for name in ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
                where name.range(of: #"^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}$"#, options: .regularExpression) != nil {
                profiles += [parent.path + "/" + name + "/debug", parent.path + "/" + name + "/release"]
            }
            for profile in profiles {
                let root = profile + "/incremental"
                for name in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() {
                    paths.append((root + "/" + name, "Rust 增量缓存"))
                }
            }
        }
        guard !paths.isEmpty, let before = CacheActivitySnapshot.capture(runner: runner) else { return [] }
        let deadline = Date().addingTimeInterval(40)
        var results: [ScanItem] = []
        for (path, rule) in paths {
            guard Date() < deadline else { break }
            let projectName: String
            if rule == "Flutter 编译快照" {
                projectName = ((parent.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            } else { projectName = ((parent.path as NSString).deletingLastPathComponent as NSString).lastPathComponent }
            let context = rule == "Flutter 编译快照" ? String(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent.prefix(8)) : (path as NSString).lastPathComponent
            let item = ScanItem.trashTarget(path: path, name: projectName + " · " + context,
                size: 0, rule: rule, evidence: "", risk: .amber)
            let decision = verify(item, activity: before, runner: runner, deadline: deadline)
            if decision.allowed, let bytes = decision.inspectedBytes, bytes > 0 {
                results.append(CleanupEvidence.applying(to: item.withSize(bytes), decision: decision))
            }
        }
        guard let after = CacheActivitySnapshot.capture(runner: runner) else { return [] }
        return results.filter { !after.blocks(path: $0.path, family: family($0)) && unchanged($0, proof: $0.cleanupEvidence, runner: runner) }
    }

    private static func family(_ item: ScanItem) -> CacheFamily { item.rule == "Flutter 编译快照" ? .flutter : .rust }
    private static func review(_ why: String) -> CleanupEvidenceDecision { .init(reason: why, snapshot: nil) }

    private static func verify(_ item: ScanItem, activity: CacheActivitySnapshot, runner: CommandRunning,
                               deadline: Date) -> CleanupEvidenceDecision {
        guard Date() < deadline, !activity.blocks(path: item.path, family: family(item)) else { return review("正在构建、产物被实际打开或超过检查时限；保留此项") }
        guard let initial = state(item) else { return review("生成记录不完整、格式不支持或内容不可安全读取；保留此项") }
        guard untrackedAndIgnored(path: item.path, project: initial.project, runner: runner) else { return review("文件被 Git 跟踪、未被忽略或无法完成仓库核验；保留此项") }
        if initial.kind == "flutterKernel" {
            guard let cache = try? JSONSerialization.jsonObject(with: initial.records[1]) as? [String: Any],
                  cache["version"] as? Int == 2, let files = cache["files"] as? [[String: Any]],
                  let stamp = try? JSONSerialization.jsonObject(with: initial.records[2]) as? [String: Any],
                  let outputs = stamp["outputs"] as? [String], outputs.contains(item.path),
                  let inputs = stamp["inputs"] as? [String], !inputs.isEmpty,
                  files.filter({ $0["path"] as? String == item.path }).count == 1,
                  let expected = files.first(where: { $0["path"] as? String == item.path })?["hash"] as? String,
                  CacheContent.isHex(expected, count: 32), header(item.path, count: 4) == Data([0x90, 0xab, 0xcd, 0xef]),
                  CacheContent.digest(Insecure.MD5.self, path: item.path, deadline: deadline) == expected else {
                return review("Flutter 输出记录、Dart kernel 类型或内容哈希不符，可能有本地修改；保留此文件")
            }
        } else {
            guard let tree = initial.tree, !tree.entries.isEmpty else { return review("Rust 增量缓存清单不完整") }
            var produced = 0
            for entry in tree.entries {
                guard Date() < deadline else { return review("检查超过时限，保留缓存") }
                let parts = entry.relative.split(separator: "/").map(String.init)
                if entry.directory {
                    guard parts.count == 1, matches(parts[0], #"^s-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$"#) else { return review("Rust 缓存有未知目录，保留整个单元") }
                    continue
                }
                if parts.count == 1, matches(parts[0], #"^s-[a-z0-9]+-[a-z0-9]+\.lock$"#), entry.size == 0 { continue }
                guard parts.count == 2 else { return review("Rust 缓存有未知内容，保留整个单元") }
                let path = item.path + "/" + entry.relative, name = parts[1]
                let recognized: Bool
                if ["query-cache.bin", "dep-graph.bin", "work-products.bin"].contains(name) {
                    recognized = rustCacheHeader(path, size: entry.size)
                } else if name == "metadata.rmeta" {
                    recognized = header(path, count: 8) == Data([0x72,0x75,0x73,0x74,0,0,0,10])
                } else { recognized = matches(name, #"^[a-z0-9]+\.o$"#) && CleanupEvidence.isObjectFile(path) }
                guard recognized else { return review("Rust 缓存包含未识别的文件或二进制格式，保留整个单元") }
                produced += 1
            }
            guard produced > 0 else { return review("没有可核验的编译产物") }
        }
        guard Date() < deadline, state(item)?.fingerprint == initial.fingerprint else { return review("验证期间内容发生变化，请重新扫描") }
        return .init(reason: initial.kind == "flutterKernel" ?
            "Flutter stamp 明确记录的编译输出，Dart kernel 类型与 filecache MD5 一致，Git 未跟踪且已忽略；仅此文件可处理，下次构建重新编译" :
            "Cargo 管理的独立增量缓存，全部内容通过布局与二进制类型检查，Git 未跟踪且已忽略；下次构建可能明显变慢",
            snapshot: .init(version: 1, fingerprint: initial.fingerprint, kind: initial.kind, newestModifiedAt: initial.modified),
            inspectedBytes: initial.bytes)
    }

    /// Called after the potentially slow final process/handle query. Git checks
    /// precede the final filesystem snapshot, so their latency cannot hide writes.
    private static func unchanged(_ item: ScanItem, proof: CleanupEvidenceSnapshot?, runner: CommandRunning) -> Bool {
        guard let proof, let before = state(item), untrackedAndIgnored(path: item.path, project: before.project, runner: runner),
              let after = state(item) else { return false }
        return proof.fingerprint == before.fingerprint && proof.fingerprint == after.fingerprint && proof.kind == after.kind
    }

    private static func state(_ item: ScanItem) -> State? {
        let path = item.path
        guard let parents = ApplicationAssociations.directoryIdentities((path as NSString).deletingLastPathComponent),
              let identity = metadata(path) else { return nil }
        let project: String, kind: String, markerPaths: [String]
        var tree: CleanupEvidence.Inventory?
        if item.rule == "Flutter 编译快照", let range = path.range(of: "/.dart_tool/flutter_build/", options: .backwards) {
            let tail = String(path[range.upperBound...]).split(separator: "/").map(String.init)
            guard tail.count == 2, CacheContent.isHex(tail[0], count: 32), tail[1] == "app.dill",
                  CleanupIdentity.capture(path: path)?.kind == .file else { return nil }
            project = String(path[..<range.lowerBound]); kind = "flutterKernel"
            let dir = (path as NSString).deletingLastPathComponent
            markerPaths = [project + "/pubspec.yaml", dir + "/.filecache", dir + "/kernel_snapshot_program.stamp"]
        } else if item.rule == "Rust 增量缓存", let range = path.range(of: "/target/", options: .backwards) {
            let tail = String(path[range.upperBound...]).split(separator: "/").map(String.init)
            guard (tail.count == 3 || tail.count == 4), tail[tail.count - 2] == "incremental",
                  ["debug", "release"].contains(tail[tail.count - 3]),
                  matches(tail.last!, #"^[a-zA-Z0-9_]+-[a-z0-9]+$"#),
                  tail.count != 4 || matches(tail[0], #"^[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+){2,}$"#),
                  let inventory = CleanupEvidence.inventory(path) else { return nil }
            tree = inventory; project = String(path[..<range.lowerBound]); kind = "rustIncremental"
            markerPaths = [project + "/Cargo.toml", project + "/target/CACHEDIR.TAG"]
        } else { return nil }
        var records: [Data] = [], fingerprints = [identity]
        for marker in markerPaths {
            guard let before = metadata(marker), let data = CacheContent.smallData(marker, limit: 8 * 1024 * 1024),
                  metadata(marker) == before else { return nil }
            records.append(data); fingerprints += [before, hash(data)]
        }
        if kind == "flutterKernel" {
            guard let manifest = String(data: records[0], encoding: .utf8),
                  manifest.range(of: #"(?m)^\s+sdk:\s*flutter\s*(?:#.*)?$"#, options: .regularExpression) != nil else { return nil }
            guard let stamp = try? JSONSerialization.jsonObject(with: records[2]) as? [String: Any],
                  let inputs = stamp["inputs"] as? [String], !inputs.isEmpty, inputs.count <= 50_000 else { return nil }
            for input in Set(inputs).sorted() {
                guard input.hasPrefix("/"), !input.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                      CleanupIdentity.capture(path: input)?.kind == .file, let inputState = metadata(input) else { return nil }
                fingerprints += ["\(input.utf8.count):\(input)", inputState]
            }
        } else {
            guard let manifest = String(data: records[0], encoding: .utf8), manifest.contains("[package]") || manifest.contains("[workspace]"),
                  String(data: records[1], encoding: .utf8)?.hasPrefix("Signature: 8a477f597d28d172789f06886806bc55\n") == true else { return nil }
        }
        guard metadata(path) == identity, parents.allSatisfy({ CleanupIdentity.capture(path: $0.0) == $0.1 }),
              let target = CleanupIdentity.capture(path: path) else { return nil }
        fingerprints += [tree?.fingerprint ?? "", project, kind]
        return State(project: project, kind: kind, fingerprint: hash(Data(fingerprints.joined(separator: "\n").utf8)),
            bytes: tree?.bytes ?? target.allocatedSize, modified: tree?.newestModifiedAt ?? target.modifiedAt,
            records: records, tree: tree)
    }

    private static func untrackedAndIgnored(path: String, project: String, runner: CommandRunning) -> Bool {
        guard path.hasPrefix(project + "/") else { return false }
        let relative = String(path.dropFirst(project.count + 1))
        let base = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", project]
        let tracked = runner.run("/usr/bin/git", base + ["ls-files", "-z", "--cached", "--", relative], timeout: 3)
        guard tracked.ok, tracked.stderr.isEmpty, tracked.stdout.isEmpty else { return false }
        let ignored = runner.run("/usr/bin/git", base + ["check-ignore", "--quiet", "--", relative], timeout: 3)
        return ignored.ok && ignored.stderr.isEmpty && ignored.stdout.isEmpty
    }

    private static func metadata(_ path: String) -> String? {
        var s = stat()
        guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFREG || s.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "\(s.st_dev):\(s.st_ino):\(s.st_mode):\(s.st_size):\(s.st_blocks):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec)"
    }

    private static func header(_ path: String, count: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: count)
        guard read(fd, &bytes, count) == count else { return nil }
        return Data(bytes)
    }
    private static func rustCacheHeader(_ path: String, size: Int64) -> Bool {
        guard let prefix = header(path, count: 7), prefix.prefix(4) == Data("RSIC".utf8),
              prefix[4] == 0, prefix[5] == 0 else { return false } // rustc HEADER_FORMAT_VERSION = 0.
        let length = Int(prefix[6])
        guard length > 0, size > 7 + length, let bytes = header(path, count: 7 + length),
              let version = String(data: bytes.dropFirst(7), encoding: .utf8) else { return false }
        return matches(version, #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)? \([a-f0-9]{9,40} [0-9]{4}-[0-9]{2}-[0-9]{2}\)$"#)
    }
    private static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
