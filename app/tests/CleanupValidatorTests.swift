// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

private func identity(_ path: String) -> CleanupIdentity {
    var value = stat()
    precondition(lstat(path, &value) == 0)
    return CleanupIdentity(deviceID: UInt64(UInt32(bitPattern: value.st_dev)),
        fileID: value.st_ino, kind: .file, allocatedSize: UInt64(value.st_blocks) * 512,
        modifiedAt: Int64(value.st_mtimespec.tv_sec), logicalSize: UInt64(value.st_size),
        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
}

private func item(path: String, identity: CleanupIdentity?, risk: Risk = .amber,
                  undo: Bool = true) -> ScanItem {
    ScanItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
        size: 4, atimeDays: nil, mtimeDays: nil, rule: "fixture", evidence: "fixture",
        risk: risk, gentle: nil, hard: "移到废纸篓", undo: undo, note: "",
        rebuild: .costly, identity: identity)
}

@main
struct CleanupValidatorTests {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("roomy-cleanup-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let file = folder.appendingPathComponent("candidate.bin")
        try Data("same".utf8).write(to: file)
        let expected = identity(file.path)

        guard case .allowed = CleanupValidator().validate(path: file.path,
            expected: item(path: file.path, identity: expected), home: home.path) else {
            preconditionFailure("unchanged regular file should validate")
        }

        try fm.removeItem(at: file)
        try Data("same".utf8).write(to: file)
        guard case .changed = CleanupValidator().validate(path: file.path,
            expected: item(path: file.path, identity: expected), home: home.path) else {
            preconditionFailure("equal-sized inode replacement must be rejected")
        }

        let replacement = identity(file.path)
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: home)
        guard case .blocked = CleanupValidator().validate(path: file.path,
            expected: item(path: file.path, identity: replacement), home: home.path) else {
            preconditionFailure("symlink replacement must be blocked")
        }

        let modified = folder.appendingPathComponent("modified.bin")
        try Data("old".utf8).write(to: modified)
        let old = identity(modified.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970:
            TimeInterval(old.modifiedAt + 10))], ofItemAtPath: modified.path)
        guard case .changed = CleanupValidator().validate(path: modified.path,
            expected: item(path: modified.path, identity: old), home: home.path) else {
            preconditionFailure("modified candidate must be rejected")
        }

        let inPlace = folder.appendingPathComponent("in-place.bin")
        try Data("four".utf8).write(to: inPlace)
        let inPlaceIdentity = identity(inPlace.path)
        try Data("fives".utf8).write(to: inPlace)
        guard case .changed = CleanupValidator().validate(path: inPlace.path,
            expected: item(path: inPlace.path, identity: inPlaceIdentity), home: home.path) else {
            preconditionFailure("in-place content change must be rejected")
        }

        let shallow = home.appendingPathComponent("shallow.bin")
        try Data().write(to: shallow)
        guard case .blocked = CleanupValidator().validate(path: shallow.path,
            expected: item(path: shallow.path, identity: identity(shallow.path)), home: home.path) else {
            preconditionFailure("home-level path must be blocked")
        }
        guard case .blocked = CleanupValidator().validate(path: modified.path,
            expected: item(path: modified.path, identity: old, risk: .lock), home: home.path) else {
            preconditionFailure("protected item must be blocked")
        }
        guard case .blocked = CleanupValidator().validate(path: modified.path,
            expected: item(path: modified.path, identity: nil), home: home.path) else {
            preconditionFailure("old reports without identity must be blocked")
        }
        guard case .changed = CleanupValidator().validate(path: folder.appendingPathComponent("missing").path,
            expected: item(path: "missing", identity: old), home: home.path) else {
            preconditionFailure("missing candidate must be reported as changed")
        }

        let anchored = folder.appendingPathComponent("nested")
        try fm.createDirectory(at: anchored, withIntermediateDirectories: true)
        let anchoredFile = anchored.appendingPathComponent("candidate")
        try Data("same".utf8).write(to: anchoredFile)
        let anchoredIdentity = identity(anchoredFile.path)
        let outside = fm.temporaryDirectory.appendingPathComponent("roomy-outside-\(UUID().uuidString)")
        try fm.moveItem(at: folder, to: outside)
        try fm.createSymbolicLink(at: folder, withDestinationURL: outside)
        defer { try? fm.removeItem(at: outside) }
        guard case .blocked = CleanupValidator().validate(path: anchoredFile.path,
            expected: item(path: anchoredFile.path, identity: anchoredIdentity), home: home.path) else {
            preconditionFailure("ancestor symlink escape must be blocked")
        }
        print("cleanup validator ok")
    }
}
