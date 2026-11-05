// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum IndexPatchError: Error, Equatable {
    case replacementOutsideRoot(String)
    case replacementPathMissing(String)
    case emptyReplacement(String)
    case replacementRootMismatch(String)
}

struct IndexPatcher {
    private let pathExists: (String) -> Bool

    init(pathExists: @escaping (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) {
        self.pathExists = pathExists
    }

    func normalizedRoots(_ paths: [String], under rootPath: String) -> [String] {
        let root = standardized(rootPath)
        let rootComponents = components(root)
        let candidates = Set(paths.map(standardized))
            .filter { isWithin(components($0), root: rootComponents) }
            .sorted { lhs, rhs in
                let leftCount = components(lhs).count
                let rightCount = components(rhs).count
                return leftCount == rightCount ? lhs < rhs : leftCount < rightCount
            }

        var result: [String] = []
        for candidate in candidates {
            let candidateComponents = components(candidate)
            if result.contains(where: { isWithin(candidateComponents, root: components($0)) }) {
                continue
            }
            result.append(candidate)
        }
        return result.sorted()
    }

    func rescanRoots(_ changedPaths: [String], in index: ScanIndex) -> [String] {
        var indexed: [String: EntryID] = [:]
        indexed.reserveCapacity(index.entries.count)
        for entry in index.entries { indexed[index.path(for: entry.id)] = entry.id }

        let root = standardized(index.rootPath)
        var rescans: [String] = []
        for dirty in normalizedRoots(changedPaths, under: root) {
            var candidate = dirty
            while candidate != root, indexed[candidate] == nil {
                candidate = standardized(URL(fileURLWithPath: candidate).deletingLastPathComponent().path)
            }
            if let id = indexed[candidate], index.entries[Int(id)].kind != .directory {
                candidate = index.path(for: index.entries[Int(id)].parentID)
            }
            while candidate != root, !pathExists(candidate) {
                candidate = standardized(URL(fileURLWithPath: candidate).deletingLastPathComponent().path)
            }
            rescans.append(candidate)
        }
        return normalizedRoots(rescans, under: root)
    }

    func replaceSubtrees(in original: ScanIndex, with replacements: [String: ScanIndex]) throws -> ScanIndex {
        let root = standardized(original.rootPath)
        var replacementsByPath: [String: ScanIndex] = [:]
        for (path, replacement) in replacements {
            let normalized = standardized(path)
            guard isWithin(components(normalized), root: components(root)) else {
                throw IndexPatchError.replacementOutsideRoot(path)
            }
            guard !replacement.entries.isEmpty else {
                throw IndexPatchError.emptyReplacement(path)
            }
            guard standardized(replacement.rootPath) == normalized else {
                throw IndexPatchError.replacementRootMismatch(path)
            }
            replacementsByPath[normalized] = replacement
        }

        let originalPaths = Set(original.entries.map { original.path(for: $0.id) })
        if let missing = replacementsByPath.keys.first(where: { !originalPaths.contains($0) }) {
            throw IndexPatchError.replacementPathMissing(missing)
        }

        var rebuilt = ScanIndex(rootPath: original.rootPath)
        var stack: [(index: ScanIndex, id: EntryID, parent: EntryID, name: String?, canReplace: Bool)] = [
            (original, 0, 0, nil, true)
        ]
        while let item = stack.popLast() {
            let sourcePath = item.index.path(for: item.id)
            if item.canReplace, let replacement = replacementsByPath[sourcePath] {
                stack.append(contentsOf: subtreeItems(
                    replacement, rootID: 0, parent: item.parent,
                    rootName: item.index.name(for: item.id)
                ).reversed())
                continue
            }

            let sourceEntry = item.index.entries[Int(item.id)]
            let newID = rebuilt.append(
                parentID: item.parent,
                fileID: sourceEntry.fileID,
                deviceID: sourceEntry.deviceID,
                name: item.name ?? item.index.name(for: item.id),
                kind: sourceEntry.kind,
                logicalSize: sourceEntry.logicalSize,
                allocatedSize: sourceEntry.allocatedSize,
                modifiedAt: sourceEntry.modifiedAt,
                flags: sourceEntry.flags,
                physicalAllocatedSize: sourceEntry.physicalAllocatedSize
            )
            for child in item.index.children(of: item.id).reversed() {
                stack.append((item.index, child, newID, nil, item.canReplace))
            }
        }
        rebuilt.recomputeHardLinkAccounting()
        return rebuilt
    }

    private func subtreeItems(
        _ index: ScanIndex,
        rootID: EntryID,
        parent: EntryID,
        rootName: String
    ) -> [(index: ScanIndex, id: EntryID, parent: EntryID, name: String?, canReplace: Bool)] {
        // A marker entry is expanded by the main iterative traversal, which then remaps descendants.
        [(index, rootID, parent, rootName, false)]
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    }

    private func isWithin(_ path: [String], root: [String]) -> Bool {
        path.count >= root.count && Array(path.prefix(root.count)) == root
    }
}
