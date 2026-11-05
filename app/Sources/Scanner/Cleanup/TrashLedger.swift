// SPDX-License-Identifier: GPL-3.0-only
// 进废纸篓不释放空间（同一个 APFS 卷）。这里记下 Roomy 自己移进废纸篓的东西，
// 让用户过几天确认没问题后，只把这些永久删除——废纸篓里别的东西一概不碰。

import Darwin
import Foundation

struct TrashedItem: Codable, Equatable {
    let path: String    // 在废纸篓里的位置
    let bytes: UInt64
    let title: String
    var deviceID: UInt64? = nil   // 记录时的身份：同一位置换成了别的东西就不认
    var fileID: UInt64? = nil
    var originalPath: String? = nil
    var recordedAt: String? = nil
    var recoveryNote: String? = nil
    var preferenceEventID: String? = nil
    var preferenceBatchID: String? = nil
    var preferenceKey: CleanupPreferenceKey? = nil
    var preferenceRestoredAt: Date? = nil
    var preferenceRestoreLearned: Bool? = nil
    var recoveryID: String { CleanupCandidate.stableID("recovery", "\(path)\u{0}\(fileID ?? 0)") }
}

final class TrashLedger: @unchecked Sendable {
    private let url: URL
    private let trashRoots: [String]
    private let lock = NSLock()

    init(url: URL, trashRoots: [String] = [HOME + "/.Trash"]) {
        self.url = url
        self.trashRoots = trashRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    func record(_ items: [TrashedItem]) {
        guard !items.isEmpty else { return }
        let stamped = items.map { item -> TrashedItem in
            var item = item
            if item.recordedAt == nil { item.recordedAt = ISO8601DateFormatter().string(from: Date()) }
            var st = stat()
            if lstat(item.path, &st) == 0 {
                item.deviceID = UInt64(UInt32(bitPattern: st.st_dev)); item.fileID = st.st_ino
            }
            return item
        }
        lock.lock(); defer { lock.unlock() }
        save(load() + stamped)
    }

    /// Background execution must stop on recording errors instead of silently losing recovery data.
    func validateForRecording() throws {
        lock.lock(); defer { lock.unlock() }
        _ = try checkedRecords()
    }

    func recordChecked(_ items: [TrashedItem]) throws {
        lock.lock(); defer { lock.unlock() }
        let existing = try checkedRecords()
        let stamped = try items.map { original -> TrashedItem in
            var item = original
            guard let identity = CleanupIdentity.capture(path: item.path) else { throw restoreError("无法核实移入废纸篓后的文件") }
            item.deviceID = identity.deviceID; item.fileID = identity.fileID
            item.recordedAt = item.recordedAt ?? ISO8601DateFormatter().string(from: Date())
            return item
        }
        try JSONEncoder().encode(existing + stamped).write(to: url, options: .atomic)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw restoreError("恢复记录无法核实") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw restoreError("恢复记录未能持久保存") }
    }

    private func checkedRecords() throws -> [TrashedItem] {
        guard ApplicationAssociations.directoryIdentities(url.deletingLastPathComponent().path) != nil else {
            throw restoreError("恢复记录目录不可安全读取")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw restoreError("恢复记录无法读取")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_size <= 32*1024*1024 else { throw restoreError("恢复记录类型或大小异常") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        return try JSONDecoder().decode([TrashedItem].self, from: data)
    }

    /// 仍在废纸篓里、仍是 Roomy 移进去的那个东西（不是被换进来的符号链接）的项
    func pending() -> [TrashedItem] {
        lock.lock(); defer { lock.unlock() }
        let kept = load().filter { !isGone($0) }
        // Polling must remain read-only: the GUI and CLI may read while another
        // process records a move. Mutating operations compact gone records later.
        return kept.filter(isPurgeable)
    }

    /// Legacy items without an identity remain visible for manual recovery, but cannot be executed.
    func recoveryItems() -> [TrashedItem] {
        lock.lock(); defer { lock.unlock() }
        return load().filter { !isGone($0) }
    }

    func purge(remove: (String) throws -> Void) -> (removed: [TrashedItem], failed: [(TrashedItem, String)]) {
        lock.lock(); defer { lock.unlock() }
        var removed: [TrashedItem] = [], failed: [(TrashedItem, String)] = [], keep: [TrashedItem] = []
        for item in load() {
            if item.preferenceRestoredAt != nil { keep.append(item); continue }
            if isPurgeable(item) {
                do { try remove(item.path); removed.append(item) } catch {
                    failed.append((item, error.localizedDescription)); keep.append(item)
                }
            } else if !isGone(item) {
                keep.append(item)
            }
        }
        save(keep)
        return (removed, failed)
    }

    /// Only the stored original location is used. The page supplies an opaque ledger ID.
    func restore(id: String, preferenceFeedbackEnabled: Bool = false) throws -> TrashedItem {
        lock.lock(); defer { lock.unlock() }
        var items = load()
        guard let index = items.firstIndex(where: { $0.recoveryID == id && $0.preferenceRestoredAt == nil }), isPurgeable(items[index]) else {
            throw restoreError("文件已不在原废纸篓位置，或身份已变化，请刷新记录")
        }
        let item = items[index]
        guard let original = item.originalPath, original.hasPrefix("/"),
              !trashRoots.contains(where: { original == $0 || original.hasPrefix($0 + "/") }) else {
            throw restoreError("旧记录缺少原路径，无法自动恢复；请在废纸篓中手动还原")
        }
        let source = try secureParent(item.path)
        defer { close(source.fd) }
        let destination = try secureParent(original)
        defer { close(destination.fd) }
        var current = stat()
        guard fstatat(source.fd, source.leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
              UInt64(UInt32(bitPattern: current.st_dev)) == item.deviceID, current.st_ino == item.fileID,
              (current.st_mode & S_IFMT) != S_IFLNK else {
            throw restoreError("废纸篓里的文件已变化，未恢复")
        }
        // RENAME_EXCL is atomic: an existing file (including a dangling symlink) is never replaced.
        guard renameatx_np(source.fd, source.leaf, destination.fd, destination.leaf, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            if code == EEXIST { throw restoreError("原位置已有同名内容，未覆盖；请先在 Finder 中处理冲突") }
            throw restoreError("无法恢复到原位置：\(String(cString: strerror(code)))；文件仍在废纸篓")
        }
        if item.preferenceEventID != nil {
            // A receipt lets the advisory store revoke stale feedback even if its own write fails.
            items[index].preferenceRestoredAt = Date()
            items[index].preferenceRestoreLearned = preferenceFeedbackEnabled
        } else { items.remove(at: index) }
        save(items)
        return item
    }

    private func secureParent(_ path: String) throws -> (fd: Int32, leaf: String) {
        // Foundation rewrites /private/var to /var, introducing a symlink on macOS.
        // Normalize only lexical components; preserve the actual recorded parent path.
        guard path.hasPrefix("/") else { throw restoreError("原路径不合法") }
        var parts: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." {
                guard !parts.isEmpty else { throw restoreError("原路径不合法") }
                parts.removeLast()
            } else { parts.append(component) }
        }
        guard let leaf = parts.last, parts.count >= 2 else { throw restoreError("原路径不合法") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw restoreError("无法安全检查原目录") }
        for component in parts.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw restoreError("原目录不存在、没有权限或已变成链接；文件仍在废纸篓") }
            fd = next
        }
        return (fd, leaf)
    }

    private func restoreError(_ message: String) -> NSError {
        NSError(domain: "RoomyRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// 删除废纸篓里的一项；遇到只读目录树（如 Go 模块缓存）时先给 owner 补上写权限再删。
    /// 只用在账本复核过的路径上（仍在废纸篓里、仍是原物）。
    static func forceRemove(_ path: String) throws {
        let fm = FileManager.default
        do { try fm.removeItem(atPath: path); return } catch {}
        var st = stat()
        func addOwnerWrite(_ p: String) {
            guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
            fchmodat(AT_FDCWD, p, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW)
            for child in (try? fm.contentsOfDirectory(atPath: p)) ?? [] { addOwnerWrite(p + "/" + child) }
        }
        addOwnerWrite(path)
        try fm.removeItem(atPath: path)
    }

    /// 确定已经不在了：不在废纸篓范围、文件不存在（ENOENT），或同一位置换成了别的东西
    private func isGone(_ item: TrashedItem) -> Bool {
        if item.preferenceRestoredAt != nil { return true }
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        guard trashRoots.contains(where: { path.hasPrefix($0 + "/") }) else { return true }
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT }
        if (st.st_mode & S_IFMT) == S_IFLNK { return true }
        guard let device = item.deviceID, let file = item.fileID else { return false }
        return !(UInt64(UInt32(bitPattern: st.st_dev)) == device && st.st_ino == file)
    }

    private func isPurgeable(_ item: TrashedItem) -> Bool {
        if item.preferenceRestoredAt != nil { return false }
        let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
        guard trashRoots.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK,
              let device = item.deviceID, let file = item.fileID else { return false }
        return UInt64(UInt32(bitPattern: st.st_dev)) == device && st.st_ino == file
    }

    private func load() -> [TrashedItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TrashedItem].self, from: data)) ?? []
    }

    private func save(_ items: [TrashedItem]) {
        let retained = items.filter { $0.preferenceRestoredAt.map { Date().timeIntervalSince($0) <= CleanupPreferencePolicy.retention } ?? true }
        guard let data = try? JSONEncoder().encode(retained) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
