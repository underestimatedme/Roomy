// SPDX-License-Identifier: MPL-2.0
import Foundation

enum OperationHistory {
    /// Bound memory and ignore a partial first/last record while a cleanup is writing.
    static func read(url: URL, limit: Int = 200) throws -> [[String: Any]] {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return [] }
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > 1_048_576 ? size - 1_048_576 : 0
        try handle.seek(toOffset: start)
        var lines = (try handle.readToEnd() ?? Data()).split(separator: 10, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.reversed().compactMap { line -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        }.prefix(max(0, min(limit, 200))))
    }
}
