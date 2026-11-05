// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

struct SavedCodeRoot: Codable, Equatable {
    let path: String
    let deviceID: UInt64
    let fileID: UInt64
}

struct CodeRootStatus: Codable {
    let path: String
    let state: String
    let reason: String
}

/// Explicit user selections retain their exact boundary and are reloaded for
/// each scan. A path alone cannot authorize a replacement directory after mount
/// changes, nor grant a cleanup action for anything inside it.
final class CodeRootStore: @unchecked Sendable {
    static let shared = CodeRootStore(url: URL(fileURLWithPath: HOME + "/Library/Application Support/Roomy/code-roots.json"))
    /// chosen：用户在首次启动的选择面板里确认过。确认过以后扫描范围只认 roots（可以是空的），不再并入自动发现的位置
    private struct Document: Codable { let version: Int; let roots: [SavedCodeRoot]; var chosen: Bool? = nil }
    private let url: URL
    private let home: String
    private let lock = NSLock()

    init(url: URL, home: String = HOME) { self.url = url; self.home = home }

    func records() throws -> [SavedCodeRoot] { lock.lock(); defer { lock.unlock() }; return try load() }
    func isChosen() throws -> Bool { lock.lock(); defer { lock.unlock() }; return try loadDocument().chosen }
    func statuses() throws -> [CodeRootStatus] { try records().map(status) }
    func availableRoots() throws -> [String] { try statuses().filter { $0.state == "available" }.map(\.path) }

    func add(paths: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let document = try loadDocument()
        var values = document.roots
        guard !paths.isEmpty, paths.count <= 64 else { throw failure("请选择代码目录，最多保存 64 个。") }
        for record in try paths.map(validated) { values.removeAll { $0.path == record.path }; values.append(record) }
        guard values.count <= 64 else { throw failure("最多保存 64 个代码目录。") }
        try save(values.sorted { $0.path < $1.path }, chosen: document.chosen)
    }

    /// 首次启动的选择：整份替换成这些目录（可以一个都不选），之后扫描范围只认它们
    func choose(paths: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard paths.count <= 64 else { throw failure("最多保存 64 个代码目录。") }
        var values: [SavedCodeRoot] = []
        for record in try paths.map(validated) where !values.contains(where: { $0.path == record.path }) { values.append(record) }
        try save(values.sorted { $0.path < $1.path }, chosen: true)
    }

    private func validated(_ raw: String) throws -> SavedCodeRoot {
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), let pointer = realpath(expanded, nil) else { throw failure("目录不存在或无法读取：\(raw)") }
        let path = String(cString: pointer); free(pointer)
        guard allowed(path), ApplicationAssociations.directoryIdentities(path) != nil,
              let identity = CleanupIdentity.capture(path: path), identity.kind == .directory else { throw failure("请选择具体的代码工作目录，不能选择系统目录或整个用户目录。") }
        let record = SavedCodeRoot(path: path, deviceID: identity.deviceID, fileID: identity.fileID)
        guard status(record).state == "available" else { throw failure("无法读取此目录，请检查系统访问权限：\(path)") }
        return record
    }

    func remove(path: String) throws {
        lock.lock(); defer { lock.unlock() }
        let document = try loadDocument()
        try save(document.roots.filter { $0.path != path }, chosen: document.chosen)
    }

    private func status(_ record: SavedCodeRoot) -> CodeRootStatus {
        func result(_ state: String, _ reason: String) -> CodeRootStatus { .init(path: record.path, state: state, reason: reason) }
        guard let identity = CleanupIdentity.capture(path: record.path) else { return result("missing", "目录不存在或无法访问；请重新选择。") }
        guard allowed(record.path), ApplicationAssociations.directoryIdentities(record.path) != nil,
              identity.kind == .directory, identity.deviceID == record.deviceID, identity.fileID == record.fileID else {
            return result("changed", "目录或挂载位置已变化；请重新选择后再扫描。")
        }
        let fd = open(record.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return result("unreadable", "无法读取，请检查系统访问权限。") }
        close(fd)
        return result("available", "已保存；扫描前会重新检查位置。")
    }

    private func allowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path == GitRepositoryDiscovery.normalizedPath(path), path.utf8.count <= 4096,
              path.split(separator: "/").count >= 2, path != home else { return false }
        let broad = ["/Users", "/opt", "/Volumes", "/private", "/private/var", "/private/tmp", "/var", "/tmp"]
        let system = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/dev", "/cores",
            "/private/etc", "/private/var/db", "/private/var/log", "/private/var/run", "/private/var/spool", "/private/var/vm"]
        return !broad.contains(path) && !system.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func load() throws -> [SavedCodeRoot] { try loadDocument().roots }

    private func loadDocument() throws -> (roots: [SavedCodeRoot], chosen: Bool) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return ([], false) }
            throw failure("代码目录配置无法读取；请修复配置后重新扫描。")
        }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0, before.st_size <= 1024 * 1024 else { throw failure("代码目录配置类型或大小异常。") }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count, fstat(fd, &after) == 0,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw failure("代码目录配置读取期间发生变化。") }
        guard let document = try? JSONDecoder().decode(Document.self, from: Data(bytes)), document.version == 1,
              document.roots.count <= 64, document.roots.allSatisfy({ allowed($0.path) }),
              Set(document.roots.map(\.path)).count == document.roots.count else { throw failure("代码目录配置损坏或版本不支持；手动目录未纳入扫描。") }
        return (document.roots, document.chosen == true)
    }

    private func save(_ records: [SavedCodeRoot], chosen: Bool) throws {
        let parent = (url.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        guard ApplicationAssociations.directoryIdentities(parent) != nil else { throw failure("代码目录配置位置不可安全写入。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, roots: records, chosen: chosen ? true : nil)).write(to: url, options: .atomic)
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "RoomyCodeRoots", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
