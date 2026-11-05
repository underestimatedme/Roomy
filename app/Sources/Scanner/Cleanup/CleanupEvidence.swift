// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

/// Persisted evidence is a snapshot, never permission without a live recheck.
struct CleanupEvidenceSnapshot: Codable, Equatable {
    let version: Int
    let fingerprint: String
    var kind: String? = nil
    var newestModifiedAt: Int64? = nil
    /// 扫描时向用户展示的检查范围与引用状态（目前 SDK 副本使用）；执行前按同一口径重算并比对
    var detail: String? = nil
}

struct CleanupEvidenceDecision {
    let reason: String
    let snapshot: CleanupEvidenceSnapshot?
    var inspectedBytes: UInt64? = nil
    var allowed: Bool { snapshot != nil }
}

/// Additional policy for the categories whose names/age do not establish disposability.
/// Unknown content, a partial walk or a failed backup check leaves the target review-only.
enum CleanupEvidence {
    private static let dependencyRules: Set<String> = ["node_modules", "Python 虚拟环境"]
    private static let generatedLeaves = ["Build/Intermediates.noindex", "Index.noindex", "ModuleCache.noindex",
                                         "SDKStatCaches.noindex", "CompilationCache.noindex"]

    static func requiresInspection(_ item: ScanItem) -> Bool {
        if item.rule == NpmDependencyEvidence.rule { return true }
        if WorkspaceArtifactEvidence.rules.contains(item.rule) { return true }
        let leaf = URL(fileURLWithPath: item.path).lastPathComponent
        return dependencyRules.contains(item.rule) || leaf == "node_modules" || leaf.hasPrefix(".venv") ||
            ["Xcode DerivedData", "Xcode 生成缓存", "XcodeBuildMCP 工作区", "uv 缓存", "项目缓存目录", "Gradle 缓存", "Gradle 下载缓存", "npm 下载缓存", "Go 构建缓存", "Go 生成缓存"].contains(item.rule) ||
            item.path.contains("/DerivedData/") || item.path.hasSuffix("/.cache/uv") || item.path.hasSuffix("/.npm/_cacache")
    }

    static func inspect(_ item: ScanItem, runner: CommandRunning = ProcessRunner()) -> CleanupEvidenceDecision {
        func review(_ reason: String) -> CleanupEvidenceDecision { .init(reason: reason, snapshot: nil) }
        if item.rule == NpmDependencyEvidence.rule { return NpmDependencyEvidence.inspect(item, runner: runner) }
        if item.rule == "Flutter 编译快照" || item.rule == "Rust 增量缓存" {
            return WorkspaceArtifactEvidence.inspect(item, runner: runner)
        }
        if item.rule == "工作空间构建目录" || item.rule == "Rust 构建产物" {
            return review("工作空间构建目录可能混有发布包、测试数据或本地文件；仅单独检查有工具记录的生成产物，不整体清理")
        }
        if item.rule == "npm 下载缓存" || item.path.hasSuffix("/.npm/_cacache") {
            return NpmCacheEvidence.inspect(item, runner: runner)
        }
        if item.rule == "Go 构建缓存" || item.rule == "Go 生成缓存" {
            return GoBuildCacheEvidence.inspect(item, runner: runner)
        }
        if item.rule == "Gradle 下载缓存" {
            return GradleDownloadEvidence.inspect(item, runner: runner)
        }
        if item.rule == "uv 缓存" || item.path.hasSuffix("/.cache/uv") {
            return review("由 uv 管理；请核实依赖与链接方式后使用 uv cache clean，不能把整个目录移到废纸篓")
        }
        let leaf = URL(fileURLWithPath: item.path).lastPathComponent
        if dependencyRules.contains(item.rule) || leaf == "node_modules" || leaf.hasPrefix(".venv") {
            let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
            let names = leaf == "node_modules" ? ["package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"] :
                ["pyproject.toml", "requirements.txt", "requirement.txt", "uv.lock", "poetry.lock", "Pipfile.lock"]
            let present = names.filter { CleanupIdentity.capture(path: parent + "/" + $0)?.kind == .file }
            return review("待核实依赖重建与本地修改；检测到文件：\(present.isEmpty ? "无依赖清单或锁文件" : present.joined(separator: "、"))。锁文件或安装包数量不能证明此目录可丢弃")
        }
        if item.rule == "项目缓存目录" || item.rule == "Gradle 缓存" || item.rule == "XcodeBuildMCP 工作区" {
            return review("尚未验证全部内容可重建及不存在独有数据；仅供查看，请按项目或所属工具核实")
        }
        guard let tree = inventory(item.path) else {
            return review("目录检查不完整、不可读取、包含链接或检查期间发生变化；请保留并重新扫描")
        }
        let symbols = tree.entries.filter { $0.directory && $0.relative.hasSuffix(".dSYM") }
        var backupEvidence = ""
        if !symbols.isEmpty {
            guard symbols.count <= 32, let backup = matchingBackups(target: item.path, symbols: symbols, runner: runner) else {
                return review("包含 dSYM；没有验证到 UUID 匹配且内容一致的独立 Archive 备份，保留整个目录")
            }
            backupEvidence = backup
        }
        for entry in tree.entries where !entry.directory {
            let rel = entry.relative
            // Symbol bytes are permitted only after the backup check above.
            if symbols.contains(where: { rel.hasPrefix($0.relative + "/") }) { continue }
            let components = rel.split(separator: "/").map(String.init)
            if components.contains("SourcePackages") || components.contains("checkouts") || components.contains(".git") {
                return review("包含源码检出或仓库数据，不能按构建缓存整体清理")
            }
            // A name/extension does not prove a file was generated. Only compiled Mach-O
            // objects inside a bounded Xcode intermediate directory qualify in this version.
            let objectArea = rel.hasPrefix("Build/Intermediates.noindex/") ||
                (item.path.contains("/DerivedData/") && item.path.hasSuffix("/Build/Intermediates.noindex"))
            guard objectArea, isObjectFile(item.path + "/" + rel) else {
                return review("包含未验证的内容，不能仅凭名称或扩展名清理；可单独核实生成缓存子目录")
            }
        }
        // Archive verification may take seconds; reject changes to any other nested file
        // during that work, even when the top directory's timestamp stayed unchanged.
        guard inventory(item.path)?.fingerprint == tree.fingerprint else {
            return review("检查期间目录内容发生变化，请重新扫描")
        }

        let fingerprint = hash(tree.fingerprint + backupEvidence)
        return .init(reason: symbols.isEmpty ? "已检查生成产物与目录完整性；执行前再次核验" :
            "已核对 dSYM 的 UUID 与独立备份内容；执行前再次核验", snapshot: .init(version: 1, fingerprint: fingerprint,
                kind: "xcodeGenerated", newestModifiedAt: tree.newestModifiedAt))
    }

    static func applying(to item: ScanItem, runner: CommandRunning = ProcessRunner()) -> ScanItem {
        guard requiresInspection(item) else { return item }
        return applying(to: item, decision: inspect(item, runner: runner))
    }

    static func applying(to item: ScanItem, decision: CleanupEvidenceDecision) -> ScanItem {
        return ScanItem(name: item.name, path: item.path, size: item.size, atimeDays: item.atimeDays,
            mtimeDays: item.mtimeDays, usedDays: item.usedDays, rule: item.rule, evidence: decision.reason,
            risk: item.risk == .lock ? .lock : .amber, gentle: item.gentle,
            hard: decision.allowed ? item.hard : "仅供查看，需进一步核实", undo: item.undo && decision.allowed,
            note: item.note, rebuild: item.rebuild, identity: item.identity,
            reclaimEstimate: decision.allowed ? item.reclaimEstimate : nil, cleanupEvidence: decision.snapshot)
    }

    static func executionBlocker(_ item: ScanItem, runner: CommandRunning = ProcessRunner(),
                                 tools: ToolLocator = ToolLocator(),
                                 codeRoots: [String] = CodeRoots.splitProtected(ALL_CODE_ROOTS).fast,
                                 home: String = HOME,
                                 androidHome: String? = SdkCopyProbe.currentAndroidHome()) -> String? {
        // 按归属定档的项：执行前按归属复核（所有者是否在运行等），不再要求逐条目内容校验
        if item.cleanupEvidence?.kind == OwnerCachePolicy.evidenceKind {
            return OwnerCachePolicy.executionBlocker(item, runner: runner, tools: tools,
                codeRoots: codeRoots, home: home, androidHome: androidHome)
        }
        guard requiresInspection(item) else { return nil }
        guard let old = item.cleanupEvidence, old.version == 1 else { return "缺少已核验的清理证据，请重新扫描并核实" }
        let live = inspect(item, runner: runner)
        guard let current = live.snapshot else { return live.reason }
        return old == current ? nil : "目录内容或备份在扫描后发生变化，请重新扫描"
    }

    /// Split only known generated subdirectories. Never descend into the protected parent wholesale.
    static func generatedChildren(of item: ScanItem, runner: CommandRunning = ProcessRunner()) -> [ScanItem] {
        if item.rule == "工作空间构建目录" || item.rule == "Rust 构建产物", !item.undo {
            return WorkspaceArtifactEvidence.children(of: item, runner: runner)
        }
        if item.rule == "包管理器缓存", item.path.hasSuffix("/.npm/_cacache"), !item.undo {
            return NpmCacheEvidence.children(of: item, runner: runner)
        }
        if item.rule == "Go 构建缓存", !item.undo {
            return GoBuildCacheEvidence.children(of: item, runner: runner)
        }
        if item.rule == "Gradle 缓存", !item.undo {
            return GradleDownloadEvidence.children(of: item, runner: runner)
        }
        guard item.rule == "Xcode DerivedData", !item.undo else { return [] }
        return generatedLeaves.compactMap { relative in
            let path = item.path + "/" + relative
            guard let tree = inventory(path), tree.bytes > 0 else { return nil }
            let child = ScanItem.trashTarget(path: path, name: item.name + " · " + relative,
                size: tree.bytes, rule: "Xcode 生成缓存", evidence: "", risk: .amber)
            let checked = applying(to: child, runner: runner)
            return checked.undo ? checked : nil
        }
    }

    struct Entry {
        let relative: String
        let directory: Bool
        let size: Int64
    }
    struct Inventory {
        let entries: [Entry]
        let fingerprint: String
        let bytes: UInt64
        let newestModifiedAt: Int64
    }

    /// Descriptor-relative walk: no symlink traversal, mount crossing or silent omissions.
    /// Limits are failure conditions rather than permission to remove an uninspected remainder.
    static func inventory(_ path: String, limit: Int = 50_000) -> Inventory? {
        guard let parents = ApplicationAssociations.directoryIdentities(path) else { return nil }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var root = stat()
        guard fstat(fd, &root) == 0 else { return nil }
        let deadline = Date().addingTimeInterval(3)
        var entries: [Entry] = [], records: [String] = [], bytes: UInt64 = 0
        var newestModifiedAt: Int64 = 0
        let buffer = AttrBuffer()
        func record(_ relative: String, _ st: stat) {
            newestModifiedAt = max(newestModifiedAt, Int64(st.st_mtimespec.tv_sec))
            // Length-delimited name plus metadata including ctime catches in-place writes with restored mtime.
            records.append("\(relative.utf8.count):\(relative):\(st.st_dev):\(st.st_ino):\(st.st_mode):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)")
        }
        func walk(_ dir: Int32, _ relative: String, _ depth: Int) -> Bool {
            guard depth <= 40, entries.count < limit, Date() < deadline else { return false }
            var before = stat(); guard fstat(dir, &before) == 0 else { return false }
            record(relative, before)
            var children: [DirEntry] = []
            do { try readEntries(fd: dir, into: &children, buf: buffer, shouldContinue: { Date() < deadline }) }
            catch { return false }
            for child in children.sorted(by: { $0.name < $1.name }) {
                guard entries.count < limit, Date() < deadline, child.name != ".", child.name != "..", !child.name.contains("/") else { return false }
                var st = stat()
                guard fstatat(dir, child.name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_dev == root.st_dev else { return false }
                let kind = st.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG else { return false }
                let name = relative.isEmpty ? child.name : relative + "/" + child.name
                entries.append(.init(relative: name, directory: kind == S_IFDIR, size: Int64(st.st_size)))
                record(name, st)
                let next = openat(dir, child.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0))
                guard next >= 0 else { return false }; defer { close(next) }
                var opened = stat()
                guard fstat(next, &opened) == 0, opened.st_ino == st.st_ino, opened.st_dev == st.st_dev else { return false }
                if kind == S_IFDIR {
                    guard walk(next, name, depth + 1) else { return false }
                } else {
                    bytes &+= UInt64(max(0, st.st_blocks)) * 512
                }
            }
            var after = stat()
            return fstat(dir, &after) == 0 && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
                before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
                before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        }
        guard walk(fd, "", 0), parents.allSatisfy({ CleanupIdentity.capture(path: $0.0) == $0.1 }) else { return nil }
        return Inventory(entries: entries, fingerprint: hash(records.joined(separator: "\n")), bytes: bytes,
            newestModifiedAt: newestModifiedAt)
    }

    static func isObjectFile(_ path: String) -> Bool {
        guard URL(fileURLWithPath: path).pathExtension == "o" else { return false }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 32)
        guard read(fd, &header, header.count) == header.count else { return false }
        let data = Data(header)
        let magic = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        let type = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) }
        // MH_MAGIC / MH_MAGIC_64 and MH_OBJECT. Textual .pch/.d files and archive
        // libraries are intentionally not accepted as disposable by extension.
        return (magic == 0xfeedface || magic == 0xfeedfacf) && type == 1
    }

    private static func matchingBackups(target: String, symbols: [Entry], runner: CommandRunning) -> String? {
        guard let boundary = target.range(of: "/DerivedData/") else { return nil }
        let archives = String(target[..<boundary.lowerBound]) + "/Archives"
        guard let tree = inventory(archives), !archives.hasPrefix(target + "/") else { return nil }
        let backupPaths = tree.entries.filter { !$0.directory && $0.relative.contains(".dSYM/Contents/Resources/DWARF/") }
        guard backupPaths.count <= 128 else { return nil }
        let deadline = Date().addingTimeInterval(10)
        var proof: [String] = []
        for symbol in symbols {
            guard Date() < deadline,
                  let bundle = bundleDigest(target + "/" + symbol.relative, deadline: deadline) else { return nil }
            let dwarf = target + "/" + symbol.relative + "/Contents/Resources/DWARF"
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dwarf), !files.isEmpty, files.count <= 8 else { return nil }
            for file in files {
                let original = dwarf + "/" + file
                guard Date() < deadline, let uuids = symbolUUIDs(original, runner: runner) else { return nil }
                var matched = false
                for backup in backupPaths where URL(fileURLWithPath: backup.relative).lastPathComponent == file {
                    guard Date() < deadline else { return nil }
                    let path = archives + "/" + backup.relative
                    let marker = ".dSYM/Contents/Resources/DWARF/"
                    guard let boundary = path.range(of: marker), symbolUUIDs(path, runner: runner) == uuids else { continue }
                    let bundlePath = String(path[..<boundary.lowerBound]) + ".dSYM"
                    guard bundleDigest(bundlePath, deadline: deadline) == bundle else { continue }
                    proof.append(uuids.sorted().joined(separator: ",") + bundle); matched = true; break
                }
                guard matched else { return nil }
            }
        }
        return proof.sorted().joined(separator: "\n")
    }

    private static func symbolUUIDs(_ path: String, runner: CommandRunning) -> Set<String>? {
        let result = runner.run("/usr/bin/dwarfdump", ["--uuid", path], timeout: 3)
        guard result.ok else { return nil }
        let lines = result.stdout.split(separator: "\n")
        var ids = Set<String>()
        for line in lines {
            let fields = line.split(separator: " ")
            guard fields.count >= 3, fields[0] == "UUID:", UUID(uuidString: String(fields[1])) != nil,
                  fields[2].hasPrefix("("), fields[2].hasSuffix(")") else { return nil }
            ids.insert(fields[1].uppercased() + String(fields[2]))
        }
        return ids.isEmpty ? nil : ids
    }

    private static func bundleDigest(_ path: String, deadline: Date) -> String? {
        guard Date() < deadline, let tree = inventory(path), tree.entries.count <= 256 else { return nil }
        var parts: [String] = []
        for entry in tree.entries where !entry.directory {
            guard let digest = digestFile(path + "/" + entry.relative, deadline: deadline) else { return nil }
            parts.append("\(entry.relative.utf8.count):\(entry.relative):\(digest)")
        }
        guard !parts.isEmpty, Date() < deadline, inventory(path)?.fingerprint == tree.fingerprint else { return nil }
        return hash(parts.joined(separator: "\n"))
    }

    private static func digestFile(_ path: String, deadline: Date) -> String? {
        guard let parents = ApplicationAssociations.directoryIdentities(URL(fileURLWithPath: path).deletingLastPathComponent().path),
              let before = CleanupIdentity.capture(path: path), before.kind == .file,
              let size = before.logicalSize, size > 0, size <= 256 * 1024 * 1024 else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var h = SHA256(), buffer = [UInt8](repeating: 0, count: 64 * 1024), count: UInt64 = 0
        while true {
            guard Date() < deadline else { return nil }
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }; if n == 0 { break }
            count += UInt64(n); guard count <= 256 * 1024 * 1024 else { return nil }
            h.update(data: Data(buffer.prefix(n)))
        }
        guard count == size, CleanupIdentity.capture(path: path) == before,
              parents.allSatisfy({ CleanupIdentity.capture(path: $0.0) == $0.1 }) else { return nil }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
