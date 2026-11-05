// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

/// Small local advisory store. It has no file-cleanup authority.
final class CleanupPreferenceStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private static let filename = "cleanup-preferences.json"
    private static let limit = 4 * 1024 * 1024
    private static let overrideLimit = 2000

    init(directory: URL) { self.directory = directory }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "RoomyPreferences", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地偏好学习不可用：" + text])
    }

    /// Open every component without following links, holding the final directory descriptor.
    private func openDirectory() throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法读取记录目录") }
        for part in directory.path.split(separator: "/") {
            guard part != ".", part != ".." else { close(fd); throw failure("记录路径异常") }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw failure("记录目录不存在、不可读或含链接") }
            fd = next
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == getuid() else { close(fd); throw failure("记录目录所有者异常") }
        return fd
    }

    private func checkedFile(_ fd: Int32) throws {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_nlink == 1, st.st_size <= Self.limit else { throw failure("记录文件类型、所有者或大小异常") }
    }

    private func read(_ dir: Int32) throws -> CleanupPreferenceSnapshot {
        let fd = openat(dir, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return .init() }; throw failure("无法安全读取记录") }
        defer { close(fd) }
        try checkedFile(fd)
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit else { throw failure("记录过大") }
        let state: CleanupPreferenceSnapshot
        do { state = try JSONDecoder().decode(CleanupPreferenceSnapshot.self, from: data) }
        catch { throw failure("记录损坏或版本不支持；可在设置中清空学习记录") }
        guard (1...CleanupPreferenceSnapshot.currentSchema).contains(state.schema), state.events.count <= 2000,
              Set(state.events.map(\.id)).count == state.events.count else {
            throw failure("记录损坏或版本不支持；可在设置中清空学习记录")
        }
        guard state.overrides.count <= Self.overrideLimit, state.tierHistory.count <= CleanupPreferenceSnapshot.historyLimit,
              Set(state.overrides.map(\.keyID)).count == state.overrides.count,
              state.overrides.allSatisfy({ $0.tier != .locked }) else {
            throw failure("档位调整记录异常（数量超限、重复或含非法档位）；可在设置中清空学习记录")
        }
        return state
    }

    private struct RecoveryReceipt: Decodable {
        let preferenceEventID: String?
        let preferenceBatchID: String?
        let preferenceKey: CleanupPreferenceKey?
        let preferenceRestoredAt: Date?
        let preferenceRestoreLearned: Bool?
    }

    private struct ProtectionID: Decodable { let id: String }

    private func reconcileProtections(_ state: inout CleanupPreferenceSnapshot, dir: Int32) throws {
        guard state.events.contains(where: { $0.kind == .protection && $0.revokedAt == nil }) else { return }
        let fd = openat(dir, "protected-cleanup.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        var ids = Set<String>()
        if fd >= 0 {
            defer { close(fd) }
            try checkedFile(fd)
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: Self.limit + 1) ?? Data()
            guard data.count <= Self.limit else { throw failure("保护记录过大") }
            ids = Set(try JSONDecoder().decode([ProtectionID].self, from: data).map(\.id))
        } else if errno != ENOENT { throw failure("无法核对保护记录") }
        for i in state.events.indices where state.events[i].kind == .protection && state.events[i].revokedAt == nil {
            if !ids.contains(state.events[i].candidateID) { state.events[i].revokedAt = Date() }
        }
    }

    private func reconcile(_ state: inout CleanupPreferenceSnapshot, dir: Int32) throws {
        guard !state.events.isEmpty else { return }
        try reconcileProtections(&state, dir: dir)
        let fd = openat(dir, "pending-trash.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return }; throw failure("无法核对恢复记录") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
              st.st_size <= 32 * 1024 * 1024 else { throw failure("恢复记录不可核实") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 32 * 1024 * 1024 else { throw failure("恢复记录过大") }
        let receipts = try JSONDecoder().decode([RecoveryReceipt].self, from: data)
        for receipt in receipts {
            guard let id = receipt.preferenceEventID, let restoredAt = receipt.preferenceRestoredAt else { continue }
            let seed = state.events.first { $0.id == id }
            let batch = seed?.batchID ?? receipt.preferenceBatchID
            let key = seed?.key ?? receipt.preferenceKey
            for i in state.events.indices where state.events[i].kind == .deletion && state.events[i].revokedAt == nil {
                if state.events[i].id == id || (key != nil && state.events[i].key == key && state.events[i].batchID == batch) {
                    state.events[i].revokedAt = restoredAt
                    if receipt.preferenceRestoreLearned == true { state.events[i].restoredAt = restoredAt }
                }
            }
        }
    }

    private func write(_ state: CleanupPreferenceSnapshot, dir: Int32) throws {
        var state = state
        state.schema = CleanupPreferenceSnapshot.currentSchema
        state.tierHistory = Array(state.tierHistory.suffix(CleanupPreferenceSnapshot.historyLimit))
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.limit else { throw failure("记录过大") }
        let temp = ".preferences-\(UUID().uuidString)"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法保存记录") }
        defer { close(fd); unlinkat(dir, temp, 0) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, renameat(dir, temp, dir, Self.filename) == 0, fsync(dir) == 0 else { throw failure("无法持久保存记录") }
    }

    private func withLock<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let dir = try openDirectory(); defer { close(dir) }
        let fd = openat(dir, "cleanup-preferences.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("无法打开记录锁") }
        defer { close(fd) }
        try checkedFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw failure("记录正在更新，请稍后重试") }
        return try body(dir)
    }

    func snapshot(now: Date = Date()) throws -> CleanupPreferenceSnapshot {
        // Reading absent state does not create directories or files (CLI previews stay read-only).
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: directory.path) { return .init() }
        let dir = try openDirectory(); defer { close(dir) }
        // Atomic JSON alone cannot synchronize the recovery fence with reset/write.
        // Reuse an existing lock read-only so a fresh CLI preview creates no files.
        let reader = openat(dir, "cleanup-preferences.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { if reader >= 0 { close(reader) } }
        if reader >= 0 {
            try checkedFile(reader)
            guard flock(reader, LOCK_SH | LOCK_NB) == 0 else { throw failure("记录正在更新，请稍后重试") }
        } else if errno != ENOENT { throw failure("无法读取记录锁") }
        var state = try read(dir)
        try reconcile(&state, dir: dir)
        var marker = stat()
        if fstatat(dir, "cleanup-preferences.invalid", &marker, AT_SYMLINK_NOFOLLOW) == 0 {
            throw failure("上次恢复后的偏好未核对，请清空学习记录")
        }
        state.events = CleanupPreferencePolicy.current(state.events, now: now)
        return state
    }

    func beginBatch() throws -> CleanupPreferenceBatch? {
        let state = try snapshot()
        return state.enabled ? .init(id: UUID().uuidString, generation: state.generation) : nil
    }

    private func mutate(now: Date = Date(), _ body: (inout CleanupPreferenceSnapshot) -> Void) throws {
        try withLock { dir in
            var state = try read(dir)
            try reconcile(&state, dir: dir)
            body(&state)
            state.events = Array(CleanupPreferencePolicy.current(state.events, now: now)
                .sorted { $0.lastActivityAt == $1.lastActivityAt ? $0.id < $1.id : $0.lastActivityAt < $1.lastActivityAt }.suffix(2000))
            try write(state, dir: dir)
        }
    }

    func record(events: [CleanupPreferenceEvent], generation: String, now: Date = Date()) throws {
        try mutate(now: now) { state in
            guard state.enabled, state.generation == generation else { return }
            var seen = Set(state.events.map(\.id))
            state.events += events.filter { seen.insert($0.id).inserted }
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        try mutate { state in
            if state.enabled != enabled { state.generation = UUID().uuidString }
            state.enabled = enabled
        }
    }

    func restore(eventID: String, batchID: String? = nil, key: CleanupPreferenceKey? = nil, now: Date = Date()) throws {
        try mutate(now: now) { state in
            let seed = state.events.first { $0.id == eventID && $0.kind == .deletion }
            let batch = seed?.batchID ?? batchID, effectiveKey = seed?.key ?? key
            for i in state.events.indices where state.events[i].kind == .deletion && state.events[i].revokedAt == nil {
                if state.events[i].id == eventID || (effectiveKey != nil && state.events[i].key == effectiveKey && state.events[i].batchID == batch) {
                    state.events[i].revokedAt = now
                    if state.enabled { state.events[i].restoredAt = now }
                }
            }
        }
    }

    func protect(candidateID: String, title: String, path: String?, key: CleanupPreferenceKey?, now: Date = Date()) throws {
        try mutate(now: now) { state in
            guard state.enabled else { return }
            for i in state.events.indices where state.events[i].kind == .protection && state.events[i].candidateID == candidateID {
                state.events[i].revokedAt = now
            }
            state.events.append(.init(id: UUID().uuidString, batchID: UUID().uuidString, candidateID: candidateID,
                title: title, path: path, key: key, kind: .protection, at: now, localDay: ""))
        }
    }

    func unprotect(candidateID: String, now: Date = Date()) throws {
        try mutate(now: now) { state in
            for i in state.events.indices where state.events[i].kind == .protection && state.events[i].candidateID == candidateID {
                state.events[i].revokedAt = now
            }
        }
    }

    /// Keeps the newest `limit` overrides, evicting the oldest learned ones before any manual one.
    static func trimmed(_ overrides: [CleanupTierOverride], limit: Int) -> [CleanupTierOverride] {
        var result = overrides
        while result.count > limit {
            result.remove(at: result.firstIndex { $0.origin == .learned } ?? 0)
        }
        return result
    }

    /// Records a tier decision. A learned decision never replaces a manual one; a repeated decision keeps the
    /// first recorded tier (the one the user saw before any override) so that undo returns to it.
    /// Learned writes are advisory like `record`: dropped when learning is off or `expectedGeneration` is stale.
    func setTier(key: CleanupPreferenceKey, tier: CleanupTier, from: CleanupTier, origin: CleanupTierOverride.Origin,
                 reason: String, now: Date = Date(), expectedGeneration: String? = nil) throws {
        guard tier != .locked, from != .locked else { throw failure("“不能删”的档位不能被调整") }
        try mutate(now: now) { state in
            if origin == .learned {
                guard state.enabled else { return }
                if let expectedGeneration, state.generation != expectedGeneration { return }
            }
            let existing = state.overrides.first { $0.keyID == key.id }
            if origin == .learned, existing?.origin == .manual { return }
            let record = CleanupTierOverride(key: key, tier: tier, fromTier: existing?.fromTier ?? from,
                                             origin: origin, reason: reason, at: now)
            state.overrides.removeAll { $0.keyID == key.id }
            state.overrides.append(record)
            state.overrides = Self.trimmed(state.overrides, limit: Self.overrideLimit)
            state.tierHistory.append(record)
        }
    }

    /// learned → pinned as a manual override at the tier the user had before; manual → removed (factory tier).
    func undoOverride(keyID: String, now: Date = Date()) throws {
        try mutate(now: now) { state in
            guard let index = state.overrides.firstIndex(where: { $0.keyID == keyID }) else { return }
            let old = state.overrides[index]
            if old.origin == .learned {
                let pinned = CleanupTierOverride(key: old.key, tier: old.fromTier, fromTier: old.fromTier,
                                                 origin: .manual, reason: "撤销习惯调整", at: now)
                state.overrides[index] = pinned
                state.tierHistory.append(pinned)
            } else {
                state.overrides.remove(at: index)
                state.tierHistory.append(CleanupTierOverride(key: old.key, tier: old.fromTier, fromTier: old.tier,
                                                             origin: .manual, reason: "撤销手动调整", at: now))
            }
        }
    }

    func resetManualOverrides(now: Date = Date()) throws {
        try mutate(now: now) { state in
            let manual = state.overrides.filter { $0.origin == .manual }
            state.overrides.removeAll { $0.origin == .manual }
            state.tierHistory += manual.map {
                CleanupTierOverride(key: $0.key, tier: $0.fromTier, fromTier: $0.tier, origin: .manual, reason: "撤销手动调整", at: now)
            }
        }
    }

    func reset() throws {
        try withLock { dir in
            // Explicit reset can repair corrupt JSON, but never replace links or foreign files.
            let fd = openat(dir, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { defer { close(fd) }; try checkedFile(fd) }
            else if errno != ENOENT { throw failure("无法安全重置记录") }
            let old = try? read(dir)
            var state = CleanupPreferenceSnapshot(); state.enabled = old?.enabled ?? true
            state.generation = UUID().uuidString
            // Clearing learning removes what Roomy learned, never what the user decided by hand.
            state.overrides = old?.overrides.filter { $0.origin == .manual } ?? []
            state.tierHistory = old?.tierHistory.filter { $0.origin == .manual } ?? []
            try write(state, dir: dir)
            if unlinkat(dir, "cleanup-preferences.invalid", 0) != 0 && errno != ENOENT { throw failure("无法清除失效标记") }
        }
    }

    /// A durable fence before recovery; if feedback cannot be updated it survives restart.
    func fenceRecovery() throws {
        try withLock { dir in
            let fd = openat(dir, "cleanup-preferences.invalid", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw failure("无法保存恢复标记") }
            defer { close(fd) }
            try checkedFile(fd)
            guard fsync(fd) == 0, fsync(dir) == 0 else { throw failure("无法持久保存恢复标记") }
        }
    }

    func finishRecovery() throws {
        try withLock { dir in
            if unlinkat(dir, "cleanup-preferences.invalid", 0) != 0 && errno != ENOENT { throw failure("无法更新恢复标记") }
            guard fsync(dir) == 0 else { throw failure("无法持久保存恢复结果") }
        }
    }
}
