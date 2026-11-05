// SPDX-License-Identifier: MPL-2.0
import Foundation

struct ProtectedCleanupItem: Codable, Equatable {
    let id: String
    let title: String
    let path: String?
}

/// The native execution boundary re-reads this store; a stale page cannot bypass it.
final class CleanupProtectionStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func all() throws -> [ProtectedCleanupItem] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    func set(_ candidate: CleanupCandidate, protected: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try load().filter { $0.id != candidate.entry.id }
        if protected {
            records.append(ProtectedCleanupItem(id: candidate.entry.id, title: candidate.entry.title, path: candidate.targetPath))
        }
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        let records = try load().filter { $0.id != id }
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }

    func blocks(path: String) throws -> Bool {
        try all().contains { Self.overlaps($0.path, path) }
    }

    func apply(to list: CleanupList) throws -> CleanupList {
        let records = try all()
        var result = list
        result.candidates = list.candidates.map { c in
            guard records.contains(where: { $0.id == c.entry.id || Self.overlaps($0.path, c.targetPath ?? c.entry.path) }) else { return c }
            var protected = c.locked("你加了保护")
            protected.entry.userProtected = true
            return protected
        }
        return result
    }

    private static func overlaps(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = URL(fileURLWithPath: a).standardizedFileURL.path
        let y = URL(fileURLWithPath: b).standardizedFileURL.path
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }

    private func load() throws -> [ProtectedCleanupItem] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [] }
        catch { throw failure(error) }
        do { return try JSONDecoder().decode([ProtectedCleanupItem].self, from: data) }
        catch { throw failure(error) }
    }

    private func failure(_ error: Error) -> NSError {
        NSError(domain: "RoomyProtection", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "保护清单无法读取，已暂停清理以免误删：\(error.localizedDescription)"])
    }
}
