// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct DiskNode: Codable {
    let id: String
    let name: String
    let path: String
    let kind: String
    let size: UInt64
    let logicalSize: UInt64
    let incomplete: Bool
}

struct DiskBreadcrumb: Codable { let id: String; let name: String }
struct DiskPage: Codable {
    let id: String
    let path: String
    let size: UInt64
    let items: [DiskNode]
    let breadcrumbs: [DiskBreadcrumb]
    let total: Int
    let offset: Int
    let skipped: Int
    let diagnostics: [ScanDiagnostic]
}

/// Read-only presentation over the existing hard-link-aware scan tree.
struct DiskExplorer {
    let index: ScanIndex
    let diagnostics: [ScanDiagnostic]

    func page(id: String, query: String = "", filesOnly: Bool = false, minBytes: UInt64 = 0,
              offset: Int = 0, limit: Int = 200) throws -> DiskPage {
        guard let nodeID = UInt64(id), nodeID < index.entries.count,
              index.entries[Int(nodeID)].kind == .directory else {
            throw NSError(domain: "RoomyDisk", code: 1, userInfo: [NSLocalizedDescriptionKey: "目录不在这次扫描中，请重新选择"])
        }
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var ids: [EntryID] = []
        var pending = index.children(of: nodeID)
        let recursive = filesOnly || !tokens.isEmpty
        while let child = pending.popLast() {
            let entry = index.entries[Int(child)]
            if recursive && entry.kind == .directory { pending.append(contentsOf: index.children(of: child)) }
            if filesOnly && entry.kind != .file { continue }
            guard index.totalAllocated(of: child) >= minBytes else { continue }
            if !tokens.isEmpty {
                let path = index.path(for: child).lowercased()
                guard tokens.allSatisfy(path.contains) else { continue }
            }
            ids.append(child)
        }
        ids.sort {
            let a = index.totalAllocated(of: $0), b = index.totalAllocated(of: $1)
            if a != b { return a > b }
            return index.name(for: $0).localizedStandardCompare(index.name(for: $1)) == .orderedAscending
        }
        let start = min(max(0, offset), ids.count)
        let end = min(ids.count, start + min(200, max(1, limit)))
        let items = ids[start..<end].map { child -> DiskNode in
            let entry = index.entries[Int(child)], path = index.path(for: child)
            let kind = entry.kind == .directory ? "directory" : entry.kind == .file ? "file" : entry.kind == .symbolicLink ? "link" : "other"
            return DiskNode(id: String(child), name: index.name(for: child), path: path, kind: kind,
                            size: index.totalAllocated(of: child), logicalSize: entry.logicalSize,
                            incomplete: diagnostics.contains { $0.path == path || $0.path.hasPrefix(path + "/") })
        }
        var breadcrumbs: [DiskBreadcrumb] = [], cursor = nodeID
        while true {
            breadcrumbs.append(DiskBreadcrumb(id: String(cursor), name: cursor == 0 ? index.rootPath : index.name(for: cursor)))
            if cursor == 0 { break }; cursor = index.entries[Int(cursor)].parentID
        }
        let path = index.path(for: nodeID)
        let skipped = diagnostics.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
        return DiskPage(id: id, path: path, size: index.totalAllocated(of: nodeID), items: items,
                        breadcrumbs: breadcrumbs.reversed(), total: ids.count, offset: start,
                        skipped: skipped.count, diagnostics: Array(skipped.prefix(20)))
    }
}
