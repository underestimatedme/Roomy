// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct ApplicationTemporaryDirectory: Codable {
    let path: String
    let kind: String

    /// These locations come from Darwin for the current user, never the page.
    /// Only the standard /var alias is expanded; links inside them are refused.
    static func current() -> [ApplicationTemporaryDirectory] {
        func configuration(_ key: Int32) -> String? {
            let count = confstr(key, nil, 0)
            guard count > 1, count < 4096 else { return nil }
            var buffer = [CChar](repeating: 0, count: count)
            guard confstr(key, &buffer, count) == count else { return nil }
            var value = String(cString: buffer)
            while value.hasSuffix("/") { value.removeLast() }
            if value.hasPrefix("/var/") { value = "/private" + value }
            return value.hasPrefix("/private/var/folders/") ? value : nil
        }
        let userDirectory = configuration(Int32(_CS_DARWIN_USER_DIR))
        let temporary = configuration(Int32(_CS_DARWIN_USER_TEMP_DIR))
        // confstr(cache) can be denied by the host sandbox even when the
        // standard sibling exists. Do not invent any other global cache root.
        let cache = configuration(Int32(_CS_DARWIN_USER_CACHE_DIR)) ?? temporary.flatMap {
            $0.hasSuffix("/T") ? String($0.dropLast(1)) + "C" : nil
        }
        return [(cache, "cache"), (temporary, "temporary"), (userDirectory, "temporary")].compactMap { path, kind in
            path.map { ApplicationTemporaryDirectory(path: $0, kind: kind) }
        }
    }

    func identity() -> CleanupIdentity? {
        var st = stat()
        guard ["cache", "temporary"].contains(kind), path.split(separator: "/").count >= 3,
              ApplicationAssociations.directoryIdentities(path) != nil,
              lstat(path, &st) == 0, st.st_uid == getuid() else { return nil }
        return CleanupIdentity.capture(path: path)
    }
}
