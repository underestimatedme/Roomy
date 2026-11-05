// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Repository markers identify where to scan, never what can be deleted.
enum GitRepositoryDiscovery {
    struct Result {
        let repositories: [String]
        let visitedDirectories: Int
        let incomplete: Bool
    }

    static func discover(searchRoots: [String], excluded: [String] = [], maxDepth: Int = 8,
                         directoryLimit: Int = 10_000, secondsPerRoot: TimeInterval = 2,
                         validateMarkers: Bool = true) -> Result {
        var found = Set<String>(), visited = Set<String>(), incomplete = false
        var exploredDepth: [String: Int] = [:]
        func exclusionKey(_ path: String) -> String { normalizedPath(path).precomposedStringWithCanonicalMapping.lowercased() }
        let excludedRoots = excluded.map(exclusionKey)
        func blocked(_ path: String) -> Bool {
            let key = exclusionKey(path)
            return excludedRoots.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        for raw in searchRoots {
            guard raw.hasPrefix("/") else { incomplete = true; continue }
            let root = normalizedPath(raw)
            let deadline = Date().addingTimeInterval(secondsPerRoot)
            var stack = [(root, 0)], rootVisited = 0
            while let (path, depth) = stack.popLast() {
                if blocked(path) || (exploredDepth[path].map { $0 >= maxDepth - depth } ?? false) { continue }
                guard rootVisited < directoryLimit, Date() < deadline else { incomplete = true; break }
                guard CleanupIdentity.capture(path: path)?.kind == .directory,
                      ApplicationAssociations.directoryIdentities(path) != nil else { continue }
                visited.insert(path); rootVisited += 1
                guard let entries = directoryEntries(path, deadline: deadline) else { incomplete = true; continue }
                exploredDepth[path] = maxDepth - depth
                if entries.contains(where: { $0.name == ".git" }),
                   !validateMarkers || repositoryMarker(path + "/.git", blocked: blocked) {
                    found.insert(path); continue
                }
                let children = entries.filter { entry in
                    entry.isDir && !WorkspaceArtifacts.boundaries.contains(entry.name) &&
                        (!entry.name.hasPrefix(".") || entry.name == ".worktrees") &&
                        !entry.name.hasPrefix(".venv") && !["homebrew", "Library", "Applications"].contains(entry.name) &&
                        ![".app", ".framework", ".xcarchive", ".bundle", ".photoslibrary"].contains(where: entry.name.hasSuffix) &&
                        !blocked(path + "/" + entry.name)
                }.sorted { $0.name > $1.name }
                guard depth < maxDepth else { if !children.isEmpty { incomplete = true }; continue }
                stack += children.map { (path + "/" + $0.name, depth + 1) }
            }
        }
        return Result(repositories: found.sorted(), visitedDirectories: visited.count, incomplete: incomplete)
    }

    private static func repositoryMarker(_ path: String, blocked: (String) -> Bool) -> Bool {
        let directory: String
        switch CleanupIdentity.capture(path: path)?.kind {
        case .directory: directory = path
        case .file:
            guard let raw = markerData(path), let text = String(data: raw, encoding: .utf8),
                  text.hasPrefix("gitdir: ") else { return false }
            let target = String(text.dropFirst(8)).trimmingCharacters(in: .newlines)
            guard !target.isEmpty, !target.contains("\n"), !target.contains("\r") else { return false }
            directory = resolve(target, relativeTo: (path as NSString).deletingLastPathComponent)
        default: return false
        }
        guard !blocked(directory), ApplicationAssociations.directoryIdentities(directory) != nil,
              let head = markerData(directory + "/HEAD"), let text = String(data: head, encoding: .utf8) else { return false }
        let reference = text.trimmingCharacters(in: .newlines)
        guard reference.hasPrefix("ref: refs/") || CacheContent.isHex(reference, count: 40) || CacheContent.isHex(reference, count: 64) else { return false }
        var common = directory
        if CleanupIdentity.capture(path: directory + "/commondir") != nil {
            guard let bytes = markerData(directory + "/commondir"), let raw = String(data: bytes, encoding: .utf8) else { return false }
            let value = raw.trimmingCharacters(in: .newlines)
            guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { return false }
            common = resolve(value, relativeTo: directory)
        }
        return !blocked(common) && ApplicationAssociations.directoryIdentities(common) != nil &&
            CleanupIdentity.capture(path: common + "/objects")?.kind == .directory &&
            CleanupIdentity.capture(path: common + "/config")?.kind == .file
    }

    private static func resolve(_ target: String, relativeTo parent: String) -> String {
        normalizedPath(target.hasPrefix("/") ? target : parent + "/" + target)
    }

    private struct Child { let name: String; let isDir: Bool }

    /// Do not materialize an arbitrarily wide directory before checking budgets.
    /// A partial listing is never used to infer that a repository was found.
    private static func directoryEntries(_ path: String, deadline: Date) -> [Child]? {
        guard let fd = try? openDir(path) else { return nil }
        guard let stream = fdopendir(fd) else { close(fd); return nil }
        defer { closedir(stream) }
        var output: [Child] = [], count = 0
        while Date() < deadline {
            errno = 0
            guard let record = readdir(stream) else { return errno == 0 ? output : nil }
            let name = withUnsafePointer(to: &record.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: record.pointee.d_name)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1; guard count <= 2048 else { return nil }
            var directory = Int(record.pointee.d_type) == Int(DT_DIR)
            if Int(record.pointee.d_type) == Int(DT_UNKNOWN) {
                var metadata = stat()
                guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                directory = metadata.st_mode & S_IFMT == S_IFDIR
            }
            if directory || name == ".git" { output.append(Child(name: name, isDir: directory)) }
        }
        return nil
    }

    /// Git metadata is untrusted. Opening a FIFO must not suspend the scanner.
    private static func markerData(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size > 0, metadata.st_size <= 4096 else { return nil }
        var data = [UInt8](repeating: 0, count: Int(metadata.st_size))
        guard read(fd, &data, data.count) == data.count else { return nil }
        return Data(data)
    }

    /// Pure lexical normalization. Foundation may shorten an existing /private/var
    /// path to the /var symlink, which would break the no-link ancestor check.
    static func normalizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }
}
