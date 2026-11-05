// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

indirect enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init?(foundation value: Any) {
        switch value {
        case let object as [String: Any]:
            var converted: [String: JSONValue] = [:]
            for (key, item) in object {
                guard let value = JSONValue(foundation: item) else { return nil }
                converted[key] = value
            }
            self = .object(converted)
        case let array as [Any]:
            let converted = array.compactMap(JSONValue.init(foundation:))
            guard converted.count == array.count else { return nil }
            self = .array(converted)
        case let string as String: self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case _ as NSNull: self = .null
        default: return nil
        }
    }
}

enum ManifestReadOutcome: Equatable, Sendable {
    case value(JSONValue)
    case malformed
    case tooLarge
    case notRegular
    case unreadable
}

protocol ManifestReading: Sendable {
    func readJSON(at url: URL, maxBytes: Int) -> ManifestReadOutcome
}

struct ManifestReader: ManifestReading {
    func readJSON(at url: URL, maxBytes: Int = 1_048_576) -> ManifestReadOutcome {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return errno == ELOOP ? .notRegular : .unreadable }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegular }
        guard info.st_size >= 0, info.st_size <= maxBytes else { return .tooLarge }

        var data = Data(count: Int(info.st_size))
        let didRead = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return info.st_size == 0 }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard didRead,
              let object = try? JSONSerialization.jsonObject(with: data),
              let value = JSONValue(foundation: object) else { return .malformed }
        return .value(value)
    }
}
