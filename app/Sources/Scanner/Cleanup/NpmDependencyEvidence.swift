// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Darwin
import Foundation

/// Each installed registry package must match its locked local download byte
/// for byte. The mixed node_modules parent and .bin links are never authorized.
enum NpmDependencyEvidence {
    static let rule = "已安装 npm 依赖"
    private struct Context {
        let project: String
        let activityRoot: String
        let records: [String: [String: Any]]
        let fingerprint: String
        let tracked: [String]
        let manifestState: String
        let lockState: String
    }
    private struct Unit {
        let path: String
        let tree: CleanupEvidence.Inventory
        let blob: String
        let digest: String
        let fingerprint: String
    }
    private struct ArchiveProof { let state: String; let contents: NpmPackageArchive.Contents }
    private struct Memo { var values: [String: ArchiveProof] = [:]; var bytes = 0 }

    static func children(of parents: [ScanItem], runner: CommandRunning, cacheRoot: String = HOME + "/.npm/_cacache", scanSeconds: TimeInterval = 40) -> [ScanItem] {
        let inputs = parents.filter { $0.rule == "node_modules" && !$0.undo }.sorted { $0.size > $1.size }
        guard !inputs.isEmpty, scanSeconds > 0,
              let before = CacheActivitySnapshot.capture(runner: runner, dependencies: true) else { return [] }
        let deadline = Date().addingTimeInterval(min(40, scanSeconds))
        var archives = Memo(), checked: [(ScanItem, Context)] = []
        var processed = Set<String>()
        for parent in inputs {
            guard Date() < deadline else { break }
            let project = (parent.path as NSString).deletingLastPathComponent
            guard processed.insert(project).inserted, let context = context(project: project, runner: runner, deadline: deadline),
                  !before.blocksDependencies(project: context.activityRoot) else { continue }
            for relative in context.records.keys.sorted() {
                guard Date() < deadline else { break }
                let path = context.project + "/" + relative
                guard let unit = unit(path: path, context: context, cacheRoot: cacheRoot),
                      verify(unit, archives: &archives, deadline: deadline) else { continue }
                let item = ScanItem.trashTarget(path: path,
                    name: (context.project as NSString).lastPathComponent + " · " + String(relative.dropFirst(13)),
                    size: unit.tree.bytes, rule: rule, evidence: "", risk: .amber)
                checked.append((CleanupEvidence.applying(to: item, decision: decision(unit)), context))
            }
        }
        guard let after = CacheActivitySnapshot.capture(runner: runner, dependencies: true) else { return [] }
        let finalDeadline = Date().addingTimeInterval(min(10, scanSeconds))
        var final: [String: Context] = [:], attempted = Set<String>()
        let liveItems = checked.compactMap { item, initial -> ScanItem? in
            guard Date() < finalDeadline else { return nil }
            if attempted.insert(initial.project).inserted,
               !after.blocksDependencies(project: initial.activityRoot),
               let current = context(project: initial.project, runner: runner, deadline: finalDeadline),
               current.fingerprint == initial.fingerprint { final[initial.project] = current }
            guard let current = final[initial.project], Date() < finalDeadline,
                  let live = unit(path: item.path, context: current, cacheRoot: cacheRoot),
                  live.fingerprint == item.cleanupEvidence?.fingerprint else { return nil }
            return item
        }
        let paths = Set(liveItems.map(\.path))
        return liveItems.filter { item in
            var parent = (item.path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    static func inspect(_ item: ScanItem, runner: CommandRunning, cacheRoot: String = HOME + "/.npm/_cacache") -> CleanupEvidenceDecision {
        guard item.rule == rule, let marker = item.path.range(of: "/node_modules/"),
              let before = CacheActivitySnapshot.capture(runner: runner, dependencies: true) else { return review("无法完整检查依赖及实际占用，保留此项") }
        let project = String(item.path[..<marker.lowerBound])
        guard let initial = context(project: project, runner: runner, deadline: Date().addingTimeInterval(10)),
              !before.blocksDependencies(project: initial.activityRoot),
              let unit = unit(path: item.path, context: initial, cacheRoot: cacheRoot) else { return review("锁文件、项目状态或依赖清单不完整，或项目仍被使用；保留此包") }
        var archives = Memo()
        guard verify(unit, archives: &archives, deadline: Date().addingTimeInterval(20)) else { return review("安装内容与原始下载包不一致、含额外内容或格式不支持；保留此包") }
        guard let after = CacheActivitySnapshot.capture(runner: runner, dependencies: true), !after.blocksDependencies(project: initial.activityRoot),
              let final = context(project: project, runner: runner, deadline: Date().addingTimeInterval(10)), final.fingerprint == initial.fingerprint,
              let live = self.unit(path: item.path, context: final, cacheRoot: cacheRoot), live.fingerprint == unit.fingerprint else {
            return review("最终检查期间项目、锁文件、下载包或安装内容发生变化，请重新扫描")
        }
        return decision(unit)
    }

    private static func context(project: String, runner: CommandRunning, deadline: Date) -> Context? {
        guard Date() < deadline, ApplicationAssociations.directoryIdentities(project) != nil,
              CleanupIdentity.capture(path: project + "/npm-shrinkwrap.json") == nil,
              let manifest = document(project + "/package.json"), let lock = document(project + "/package-lock.json"),
              [2, 3].contains(lock.object["lockfileVersion"] as? Int ?? 0),
              let packages = lock.object["packages"] as? [String: [String: Any]], packages.count <= 50_000,
              let root = packages[""] else { return nil }
        for key in ["dependencies", "devDependencies", "optionalDependencies"] {
            guard manifest.object[key] == nil || manifest.object[key] is [String: String],
                  root[key] == nil || root[key] is [String: String],
                  (manifest.object[key] as? [String: String] ?? [:]) == (root[key] as? [String: String] ?? [:]) else { return nil }
        }
        let base = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", project]
        func git(_ arguments: [String]) -> CommandResult? {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let result = runner.run("/usr/bin/git", base + arguments, timeout: min(3, remaining))
            return Date() < deadline ? result : nil
        }
        guard let tracked = git(["ls-files", "-z", "--cached", "--", "node_modules"]), tracked.ok, tracked.stderr.isEmpty,
              let ignored = git(["check-ignore", "--quiet", "--", "node_modules"]), ignored.ok, ignored.stderr.isEmpty, ignored.stdout.isEmpty,
              let repository = git(["rev-parse", "--show-toplevel"]), repository.ok, repository.stderr.isEmpty,
              repository.stdout.hasSuffix("\n"),
              metadata(project + "/package.json") == manifest.state, metadata(project + "/package-lock.json") == lock.state else { return nil }
        let activityRoot = String(repository.stdout.dropLast())
        guard activityRoot.hasPrefix("/"), !activityRoot.contains("\n"),
              project == activityRoot || project.hasPrefix(activityRoot + "/") else { return nil }
        let records = packages.filter { validRelative($0.key) }
        return Context(project: project, activityRoot: activityRoot, records: records, fingerprint: hash(manifest.state + lock.state + hash(manifest.data) + hash(lock.data) + activityRoot),
            tracked: tracked.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init),
            manifestState: manifest.state, lockState: lock.state)
    }

    private static func unit(path: String, context: Context, cacheRoot: String) -> Unit? {
        guard path.hasPrefix(context.project + "/") else { return nil }
        let relative = String(path.dropFirst(context.project.count + 1))
        guard validRelative(relative), let record = context.records[relative], record["link"] as? Bool != true,
              !context.tracked.contains(where: { $0 == relative || $0.hasPrefix(relative + "/") }),
              let version = record["version"] as? String, !version.isEmpty,
              let resolved = record["resolved"] as? String, let url = URLComponents(string: resolved),
              url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let integrity = record["integrity"] as? String, integrity.hasPrefix("sha512-"),
              let bytes = Data(base64Encoded: String(integrity.dropFirst(7))), bytes.count == 64,
              let tree = CleanupEvidence.inventory(path), tree.bytes > 0, tree.bytes <= CacheContent.byteLimit,
              let installed = document(path + "/package.json"), installed.object["version"] as? String == version,
              let name = installed.object["name"] as? String else { return nil }
        let parts = relative.split(separator: "/").map(String.init)
        let expectedName = parts[parts.count - 2].hasPrefix("@") ? parts.suffix(2).joined(separator: "/") : parts.last!
        guard name == (record["name"] as? String ?? expectedName) else { return nil }
        let digest = bytes.map { String(format: "%02x", $0) }.joined()
        let blob = cacheRoot + "/content-v2/sha512/" + digest.prefix(2) + "/" + digest.dropFirst(2).prefix(2) + "/" + digest.dropFirst(4)
        guard let blobParents = ApplicationAssociations.directoryIdentities((blob as NSString).deletingLastPathComponent),
              let blobState = metadata(blob), CleanupIdentity.capture(path: blob)?.kind == .file,
              let parents = ApplicationAssociations.directoryIdentities(path),
              metadata(context.project + "/package.json") == context.manifestState,
              metadata(context.project + "/package-lock.json") == context.lockState else { return nil }
        let ancestry = (parents + blobParents).map { "\($0.0):\($0.1.deviceID):\($0.1.fileID)" }.joined(separator: "\n")
        return Unit(path: path, tree: tree, blob: blob, digest: digest,
            fingerprint: hash(context.fingerprint + tree.fingerprint + blobState + ancestry + digest))
    }

    private static func verify(_ unit: Unit, archives: inout Memo, deadline: Date) -> Bool {
        guard Date() < deadline, let state = metadata(unit.blob) else { return false }
        let contents: NpmPackageArchive.Contents
        if let cached = archives.values[unit.blob], cached.state == state { contents = cached.contents }
        else {
            guard CacheContent.digest(SHA512.self, path: unit.blob, deadline: deadline) == unit.digest,
                  let parsed = NpmPackageArchive.contents(path: unit.blob, deadline: deadline), metadata(unit.blob) == state else { return false }
            contents = parsed
            let oldCost = archives.values[unit.blob]?.contents.storageBytes ?? 0
            if archives.bytes - oldCost + parsed.storageBytes <= 8 * 1024 * 1024 {
                archives.values[unit.blob] = ArchiveProof(state: state, contents: parsed)
                archives.bytes += parsed.storageBytes - oldCost
            }
        }
        let files = unit.tree.entries.filter { !$0.directory }, directories = Set(unit.tree.entries.filter(\.directory).map(\.relative))
        guard files.count == contents.files.count, directories == contents.directories else { return false }
        for file in files {
            guard Date() < deadline, let expected = contents.files[file.relative],
                  CacheContent.digest(SHA256.self, path: unit.path + "/" + file.relative, deadline: deadline) == expected else { return false }
        }
        return CleanupEvidence.inventory(unit.path)?.fingerprint == unit.tree.fingerprint
    }

    private static func decision(_ unit: Unit) -> CleanupEvidenceDecision {
        .init(reason: "锁定的 HTTPS npm 下载包 SHA-512 与安装目录全部文件内容一致，未发现跟踪文件、额外内容或活动项目；仅此包可处理。使用项目之前须重新安装依赖，可能需要联网、运行安装脚本；离线或原源不可用时可能失败",
            snapshot: .init(version: 1, fingerprint: unit.fingerprint, kind: "npmDependency", newestModifiedAt: unit.tree.newestModifiedAt), inspectedBytes: unit.tree.bytes)
    }
    private static func validRelative(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        func name(_ value: String) -> Bool { ![".", ".."].contains(value) && value.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil }
        while index < parts.count {
            guard parts[index] == "node_modules", index + 1 < parts.count else { return false }; index += 1
            if parts[index].hasPrefix("@") { guard name(String(parts[index].dropFirst())), index + 1 < parts.count else { return false }; index += 1 }
            guard name(parts[index]) else { return false }; index += 1
        }
        return index > 0
    }
    private static func document(_ path: String) -> (object: [String: Any], data: Data, state: String)? {
        guard let state = metadata(path), let data = CacheContent.smallData(path, limit: 16 * 1024 * 1024),
              metadata(path) == state, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (object, data, state)
    }
    private static func metadata(_ path: String) -> String? {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_size):\(value.st_blocks):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    private static func review(_ why: String) -> CleanupEvidenceDecision { .init(reason: why, snapshot: nil) }
}
