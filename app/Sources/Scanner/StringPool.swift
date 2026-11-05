// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Stores each distinct UTF-8 file name once. IDs remain stable for the life of a scan.
struct StringPool: Codable, Equatable, Sendable {
    private var bytes = Data()
    private var offsets: [UInt32] = []
    private var lengths: [UInt32] = []
    private var idsByValue: [String: UInt32] = [:]

    var count: Int { offsets.count }

    func id(for value: String) -> UInt32? { idsByValue[value] }

    mutating func intern(_ value: String) -> UInt32 {
        if let existing = idsByValue[value] {
            return existing
        }

        let encoded = Data(value.utf8)
        precondition(bytes.count <= Int(UInt32.max) - encoded.count, "string pool exceeds UInt32 address space")
        precondition(offsets.count < Int(UInt32.max), "string pool has too many entries")

        let id = UInt32(offsets.count)
        offsets.append(UInt32(bytes.count))
        lengths.append(UInt32(encoded.count))
        bytes.append(encoded)
        idsByValue[value] = id
        return id
    }

    func value(for id: UInt32) -> String {
        let index = Int(id)
        precondition(index < offsets.count, "unknown string pool ID")
        let start = Int(offsets[index])
        let end = start + Int(lengths[index])
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case bytes
        case offsets
        case lengths
    }

    init() {}

    init(snapshotBytes: Data, offsets: [UInt32], lengths: [UInt32]) throws {
        guard offsets.count == lengths.count else { throw StringPoolSnapshotError.invalidTable }
        bytes = snapshotBytes
        self.offsets = offsets
        self.lengths = lengths
        for id in offsets.indices {
            let start = Int(offsets[id])
            let length = Int(lengths[id])
            guard start <= bytes.count, length <= bytes.count - start else {
                throw StringPoolSnapshotError.outOfBounds
            }
            idsByValue[String(decoding: bytes[start..<(start + length)], as: UTF8.self)] = UInt32(id)
        }
    }

    func snapshotComponents() -> (bytes: Data, offsets: [UInt32], lengths: [UInt32]) {
        (bytes, offsets, lengths)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bytes = try values.decode(Data.self, forKey: .bytes)
        offsets = try values.decode([UInt32].self, forKey: .offsets)
        lengths = try values.decode([UInt32].self, forKey: .lengths)
        guard offsets.count == lengths.count else {
            throw DecodingError.dataCorruptedError(forKey: .lengths, in: values,
                debugDescription: "string pool offsets and lengths differ")
        }
        for id in offsets.indices {
            let start = Int(offsets[id])
            let length = Int(lengths[id])
            guard start <= bytes.count, length <= bytes.count - start else {
                throw DecodingError.dataCorruptedError(forKey: .bytes, in: values,
                    debugDescription: "string pool entry is out of bounds")
            }
            idsByValue[String(decoding: bytes[start..<(start + length)], as: UTF8.self)] = UInt32(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bytes, forKey: .bytes)
        try values.encode(offsets, forKey: .offsets)
        try values.encode(lengths, forKey: .lengths)
    }
}

enum StringPoolSnapshotError: Error {
    case invalidTable
    case outOfBounds
}
