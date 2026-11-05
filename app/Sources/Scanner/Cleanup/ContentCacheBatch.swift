// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

private final class CacheBatchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanItem] = []
    func append(_ item: ScanItem) { lock.lock(); values.append(item); lock.unlock() }
    var items: [ScanItem] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Share two activity snapshots across a read-only discovery batch. Execution
/// never reuses these snapshots: each selected unit gets fresh live checks.
enum ContentCacheBatch {
    static func children(root: String, rule: String, title: String, family: CacheFamily,
                         runner: CommandRunning,
                         relativePaths: [String]? = nil,
                         verify: @escaping (ScanItem, CacheActivitySnapshot, Date) -> CleanupEvidenceDecision,
                         recheck: (ScanItem) -> Bool) -> [ScanItem] {
        guard let before = CacheActivitySnapshot.capture(runner: runner) else { return [] }
        let names = (relativePaths ?? ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { CacheContent.isHex($0, count: 2) }).sorted()
        let deadline = Date().addingTimeInterval(40)
        let results = CacheBatchResults()
        DispatchQueue.concurrentPerform(iterations: min(4, names.count)) { worker in
            for index in stride(from: worker, to: names.count, by: 4) {
                guard Date() < deadline else { break }
                let path = root + "/" + names[index]
                guard !before.blocks(path: path, family: family) else { continue }
                let item = ScanItem.trashTarget(path: path, name: title + " · " + names[index],
                    size: 0, rule: rule, evidence: "", risk: .amber)
                let decision = verify(item, before, deadline)
                guard decision.allowed, let bytes = decision.inspectedBytes, bytes > 0 else { continue }
                results.append(CleanupEvidence.applying(to: item.withSize(bytes), decision: decision))
            }
        }
        guard let after = CacheActivitySnapshot.capture(runner: runner) else { return [] }
        let finalDeadline = Date().addingTimeInterval(10)
        return results.items.sorted { $0.path < $1.path }.filter {
            Date() < finalDeadline && !after.blocks(path: $0.path, family: family) && recheck($0)
        }
    }
}

enum CacheContent {
    static let byteLimit: UInt64 = 512 * 1024 * 1024

    static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func digest<H: HashFunction>(_ type: H.Type, path: String, deadline: Date) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size >= 0,
              UInt64(st.st_size) <= byteLimit else { return nil }
        var hash = H(), buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while Date() < deadline {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return hash.finalize().map { String(format: "%02x", $0) }.joined() }
            guard count > 0 else { return nil }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return nil
    }

    static func smallData(_ path: String, limit: Int = 4096) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size <= limit else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        guard read(fd, &bytes, bytes.count) == bytes.count else { return nil }
        return Data(bytes)
    }
}
