// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        Swift.withUnsafeBytes(of: &encoded) { append(contentsOf: $0) }
    }
}

private struct SnapshotCursor {
    let data: Data
    private(set) var offset = 0

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw SnapshotError.truncated
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let width = MemoryLayout<T>.size
        let bytes = try readData(count: width)
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { destination in
            bytes.copyBytes(to: destination)
        }
        return T(littleEndian: value)
    }
}

enum SnapshotCodec {
    static func encode(index: ScanIndex, metadata: SnapshotMetadata) throws -> Data {
        let metadataEncoder = PropertyListEncoder()
        metadataEncoder.outputFormat = .binary
        let metadataData = try metadataEncoder.encode(metadata)
        let indexData = try encodeIndex(index)

        var payload = Data()
        payload.append(metadataData)
        payload.append(indexData)
        let checksum = Data(SHA256.hash(data: payload))

        var result = Data(capacity: SnapshotFormat.headerSize + payload.count)
        result.append(SnapshotFormat.magic)
        result.appendLittleEndian(SnapshotFormat.schema)
        result.appendLittleEndian(UInt32(0))
        result.appendLittleEndian(UInt64(metadataData.count))
        result.appendLittleEndian(UInt64(indexData.count))
        result.append(checksum)
        precondition(result.count == SnapshotFormat.headerSize)
        result.append(payload)
        return result
    }

    static func decode(_ data: Data) throws -> CachedScan {
        guard data.count >= SnapshotFormat.headerSize else { throw SnapshotError.truncated }
        var cursor = SnapshotCursor(data: data)
        guard try cursor.readData(count: 8) == SnapshotFormat.magic else {
            throw SnapshotError.badMagic
        }
        let schema: UInt32 = try cursor.readInteger()
        guard schema == SnapshotFormat.schema else { throw SnapshotError.unsupportedSchema(schema) }
        let _: UInt32 = try cursor.readInteger()
        let metadataLength64: UInt64 = try cursor.readInteger()
        let indexLength64: UInt64 = try cursor.readInteger()
        let expectedChecksum = try cursor.readData(count: 32)
        guard metadataLength64 <= UInt64(Int.max), indexLength64 <= UInt64(Int.max) else {
            throw SnapshotError.truncated
        }
        let metadataLength = Int(metadataLength64)
        let indexLength = Int(indexLength64)
        guard metadataLength <= data.count - SnapshotFormat.headerSize,
              indexLength <= data.count - SnapshotFormat.headerSize - metadataLength,
              SnapshotFormat.headerSize + metadataLength + indexLength == data.count else {
            throw SnapshotError.truncated
        }

        let metadataData = try cursor.readData(count: metadataLength)
        let indexData = try cursor.readData(count: indexLength)
        var payload = Data()
        payload.append(metadataData)
        payload.append(indexData)
        guard Data(SHA256.hash(data: payload)) == expectedChecksum else {
            throw SnapshotError.checksumMismatch
        }

        let metadata: SnapshotMetadata
        do {
            metadata = try PropertyListDecoder().decode(SnapshotMetadata.self, from: metadataData)
        } catch {
            throw SnapshotError.malformed("metadata")
        }
        return CachedScan(index: try decodeIndex(indexData), metadata: metadata)
    }

    private static func encodeIndex(_ index: ScanIndex) throws -> Data {
        let rootBytes = Data(index.rootPath.utf8)
        guard rootBytes.count <= Int(UInt32.max) else {
            throw SnapshotError.malformed("root path")
        }
        let names = index.stringPool.snapshotComponents()
        var data = Data()
        data.appendLittleEndian(UInt32(rootBytes.count))
        data.append(rootBytes)
        data.appendLittleEndian(UInt32(names.offsets.count))
        data.appendLittleEndian(UInt64(names.bytes.count))
        for offset in names.offsets { data.appendLittleEndian(offset) }
        for length in names.lengths { data.appendLittleEndian(length) }
        data.append(names.bytes)
        data.appendLittleEndian(UInt64(index.entries.count))
        for entry in index.entries {
            data.appendLittleEndian(entry.id)
            data.appendLittleEndian(entry.parentID)
            data.appendLittleEndian(entry.fileID)
            data.appendLittleEndian(entry.deviceID)
            data.appendLittleEndian(entry.nameID)
            data.append(entry.kind.rawValue)
            data.appendLittleEndian(entry.flags.rawValue)
            data.append(0)
            data.appendLittleEndian(entry.logicalSize)
            data.appendLittleEndian(entry.allocatedSize)
            data.appendLittleEndian(entry.physicalAllocatedSize)
            data.appendLittleEndian(UInt64(bitPattern: entry.modifiedAt))
        }
        return data
    }

    private static func decodeIndex(_ data: Data) throws -> ScanIndex {
        var cursor = SnapshotCursor(data: data)
        let rootLength: UInt32 = try cursor.readInteger()
        let rootData = try cursor.readData(count: Int(rootLength))
        guard let rootPath = String(data: rootData, encoding: .utf8) else {
            throw SnapshotError.malformed("root path")
        }
        let nameCount32: UInt32 = try cursor.readInteger()
        let nameCount = Int(nameCount32)
        let nameByteCount64: UInt64 = try cursor.readInteger()
        guard nameByteCount64 <= UInt64(Int.max) else { throw SnapshotError.truncated }
        guard nameCount <= (data.count - cursor.offset) / 8 else {
            throw SnapshotError.truncated
        }
        var offsets: [UInt32] = []
        var lengths: [UInt32] = []
        offsets.reserveCapacity(nameCount)
        lengths.reserveCapacity(nameCount)
        for _ in 0..<nameCount { offsets.append(try cursor.readInteger()) }
        for _ in 0..<nameCount { lengths.append(try cursor.readInteger()) }
        let nameBytes = try cursor.readData(count: Int(nameByteCount64))
        let pool: StringPool
        do {
            pool = try StringPool(snapshotBytes: nameBytes, offsets: offsets, lengths: lengths)
        } catch {
            throw SnapshotError.malformed("string pool")
        }

        let entryCount64: UInt64 = try cursor.readInteger()
        guard entryCount64 <= UInt64(Int.max),
              entryCount64 <= UInt64((data.count - cursor.offset) / SnapshotFormat.entrySize) else {
            throw SnapshotError.truncated
        }
        var index = ScanIndex(rootPath: rootPath, stringPool: pool)
        for entryIndex in 0..<Int(entryCount64) {
            let id: UInt64 = try cursor.readInteger()
            let parentID: UInt64 = try cursor.readInteger()
            let fileID: UInt64 = try cursor.readInteger()
            let deviceID: UInt64 = try cursor.readInteger()
            let nameID: UInt32 = try cursor.readInteger()
            let kindRaw: UInt8 = try cursor.readInteger()
            let flagsRaw: UInt16 = try cursor.readInteger()
            let _: UInt8 = try cursor.readInteger()
            let logicalSize: UInt64 = try cursor.readInteger()
            let allocatedSize: UInt64 = try cursor.readInteger()
            let physicalAllocatedSize: UInt64 = try cursor.readInteger()
            let modifiedRaw: UInt64 = try cursor.readInteger()
            guard let kind = EntryKind(rawValue: kindRaw), Int(nameID) < pool.count else {
                throw SnapshotError.malformed("entry")
            }
            guard id == UInt64(entryIndex),
                  (entryIndex == 0 && parentID == 0 && kind == .directory) ||
                    (entryIndex > 0 && parentID < id),
                  entryIndex != 0 || pool.value(for: nameID).isEmpty,
                  allocatedSize <= physicalAllocatedSize else {
                throw SnapshotError.malformed("entry topology")
            }
            index.append(ScanEntry(id: id, parentID: parentID, fileID: fileID,
                deviceID: deviceID, nameID: nameID, kind: kind,
                logicalSize: logicalSize, allocatedSize: allocatedSize,
                modifiedAt: Int64(bitPattern: modifiedRaw), flags: EntryFlags(rawValue: flagsRaw),
                physicalAllocatedSize: physicalAllocatedSize))
        }
        guard cursor.offset == data.count else { throw SnapshotError.malformed("trailing index data") }
        index.finalizeAggregates()
        return index
    }
}
