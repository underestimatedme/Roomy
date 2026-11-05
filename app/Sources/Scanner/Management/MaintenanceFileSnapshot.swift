// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

/// Bounded descriptor reads through directories that have no symlink components.
/// Shared by maintenance inventories; never writes the inspected file.
struct MaintenanceFileSnapshot {
    let identity: CleanupIdentity
    let owner: uid_t
    let mode: mode_t
    let data: Data
    let plist: [String: Any]

    static func isAbsoluteLexicalPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func read(path: String, maximumBytes: Int, requirePlist: Bool = true) -> MaintenanceFileSnapshot? {
        guard isAbsoluteLexicalPath(path) else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return nil }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return nil }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(parent); parent = next
            guard parent >= 0 else { return nil }
        }
        defer { close(parent) }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= maximumBytes else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { return nil }
        let identity = CleanupIdentity(deviceID: UInt64(UInt32(bitPattern: after.st_dev)), fileID: after.st_ino,
            kind: .file, allocatedSize: UInt64(after.st_blocks) * 512, modifiedAt: Int64(after.st_mtimespec.tv_sec),
            logicalSize: UInt64(after.st_size), modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec))
        guard CleanupIdentity.capture(path: path) == identity else { return nil }
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        guard !requirePlist || plist != nil else { return nil }
        return MaintenanceFileSnapshot(identity: identity, owner: after.st_uid, mode: after.st_mode, data: data, plist: plist ?? [:])
    }
}
