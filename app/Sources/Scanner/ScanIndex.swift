// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Compact scan-owned tree. Entry IDs are array indexes and remain stable until a subtree patch.
struct ScanIndex: Codable, Equatable, Sendable {
    private static let noEntry = EntryID.max

    let rootPath: String
    private(set) var stringPool: StringPool
    private(set) var entries: [ScanEntry] = []
    private var ownAllocated: [UInt64] = []
    private var aggregateAllocated: [UInt64] = []
    private var firstChild: [EntryID] = []
    private var lastChild: [EntryID] = []
    private var nextSibling: [EntryID] = []

    init(rootPath: String = "/", stringPool: StringPool = StringPool()) {
        if rootPath == "/" {
            self.rootPath = "/"
        } else {
            self.rootPath = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        }
        self.stringPool = stringPool
    }

    mutating func internName(_ value: String) -> UInt32 {
        stringPool.intern(value)
    }

    @discardableResult
    mutating func append(
        parentID: EntryID,
        fileID: UInt64,
        deviceID: UInt64,
        name: String,
        kind: EntryKind,
        logicalSize: UInt64,
        allocatedSize: UInt64,
        modifiedAt: Int64,
        flags: EntryFlags,
        physicalAllocatedSize: UInt64? = nil
    ) -> EntryID {
        let id = EntryID(entries.count)
        let entry = ScanEntry(
            id: id,
            parentID: parentID,
            fileID: fileID,
            deviceID: deviceID,
            nameID: internName(name),
            kind: kind,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            modifiedAt: modifiedAt,
            flags: flags,
            physicalAllocatedSize: physicalAllocatedSize
        )
        append(entry)
        return id
    }

    mutating func append(_ entry: ScanEntry) {
        let id = EntryID(entries.count)
        precondition(entry.id == id, "entry IDs must be contiguous")
        precondition(id == 0 || entry.parentID < id, "parent must precede child")

        entries.append(entry)
        ownAllocated.append(entry.allocatedSize)
        aggregateAllocated.append(entry.allocatedSize)
        firstChild.append(Self.noEntry)
        lastChild.append(Self.noEntry)
        nextSibling.append(Self.noEntry)

        guard id != 0 else { return }
        let parent = Int(entry.parentID)
        if lastChild[parent] == Self.noEntry {
            firstChild[parent] = id
        } else {
            nextSibling[Int(lastChild[parent])] = id
        }
        lastChild[parent] = id
    }

    func name(for id: EntryID) -> String {
        stringPool.value(for: entries[Int(id)].nameID)
    }

    func path(for id: EntryID) -> String {
        precondition(Int(id) < entries.count, "unknown entry ID")
        if id == 0 { return rootPath }

        var components: [String] = []
        var cursor = id
        while cursor != 0 {
            components.append(name(for: cursor))
            cursor = entries[Int(cursor)].parentID
        }
        let suffix = components.reversed().joined(separator: "/")
        return rootPath == "/" ? "/" + suffix : rootPath + "/" + suffix
    }

    func children(of id: EntryID) -> [EntryID] {
        precondition(Int(id) < entries.count, "unknown entry ID")
        var result: [EntryID] = []
        var cursor = firstChild[Int(id)]
        while cursor != Self.noEntry {
            result.append(cursor)
            cursor = nextSibling[Int(cursor)]
        }
        return result
    }

    mutating func finalizeAggregates() {
        aggregateAllocated = ownAllocated
        guard entries.count > 1 else { return }
        for index in stride(from: entries.count - 1, through: 1, by: -1) {
            let parent = Int(entries[index].parentID)
            aggregateAllocated[parent] &+= aggregateAllocated[index]
        }
    }

    mutating func recomputeHardLinkAccounting() {
        var seen: Set<FileIdentity> = []
        var rebuilt: [ScanEntry] = []
        rebuilt.reserveCapacity(entries.count)
        ownAllocated.removeAll(keepingCapacity: true)
        ownAllocated.reserveCapacity(entries.count)
        for entry in entries {
            var charged = entry.physicalAllocatedSize
            if entry.kind == .file && !seen.insert(entry.identity).inserted {
                charged = 0
            }
            rebuilt.append(ScanEntry(id: entry.id, parentID: entry.parentID,
                fileID: entry.fileID, deviceID: entry.deviceID, nameID: entry.nameID,
                kind: entry.kind, logicalSize: entry.logicalSize, allocatedSize: charged,
                modifiedAt: entry.modifiedAt, flags: entry.flags,
                physicalAllocatedSize: entry.physicalAllocatedSize))
            ownAllocated.append(charged)
        }
        entries = rebuilt
        finalizeAggregates()
    }

    func totalAllocated(of id: EntryID) -> UInt64 {
        aggregateAllocated[Int(id)]
    }
}
