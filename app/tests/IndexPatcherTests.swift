// SPDX-License-Identifier: MPL-2.0
import Foundation

private func makeOriginal() -> ScanIndex {
    var index = ScanIndex(rootPath: "/Users")
    _ = index.append(parentID: 0, fileID: 1, deviceID: 9, name: "", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    let a = index.append(parentID: 0, fileID: 2, deviceID: 9, name: "a", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    _ = index.append(parentID: a, fileID: 3, deviceID: 9, name: "old.bin", kind: .file,
        logicalSize: 10, allocatedSize: 100, modifiedAt: 1, flags: [])
    let ab = index.append(parentID: 0, fileID: 4, deviceID: 9, name: "ab", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    _ = index.append(parentID: ab, fileID: 5, deviceID: 9, name: "keep.bin", kind: .file,
        logicalSize: 20, allocatedSize: 200, modifiedAt: 1, flags: [])
    index.finalizeAggregates()
    return index
}

private func makeReplacement() -> ScanIndex {
    var index = ScanIndex(rootPath: "/Users/a")
    _ = index.append(parentID: 0, fileID: 2, deviceID: 9, name: "", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 2, flags: [])
    _ = index.append(parentID: 0, fileID: 6, deviceID: 9, name: "new.bin", kind: .file,
        logicalSize: 30, allocatedSize: 300, modifiedAt: 2, flags: [])
    index.finalizeAggregates()
    return index
}

@main
struct IndexPatcherTests {
    static func main() throws {
        let patcher = IndexPatcher(pathExists: { _ in true })
        let normalized = patcher.normalizedRoots([
            "/Users/a", "/Users/a/b", "/Users/ab", "/Users/a",
            "/Users/missing/child", "/private/outside"
        ], under: "/Users")
        precondition(normalized == ["/Users/a", "/Users/ab", "/Users/missing/child"])

        let original = makeOriginal()
        precondition(patcher.rescanRoots(["/Users/a/deleted.bin"], in: original) == ["/Users/a"])

        let patched = try patcher.replaceSubtrees(
            in: original,
            with: ["/Users/a": makeReplacement()]
        )
        precondition(patched.entries.map(\.id) == Array(0..<UInt64(patched.entries.count)))
        precondition(patched.entries.map(\.parentID) == [0, 0, 1, 0, 3])
        precondition(patched.path(for: 2) == "/Users/a/new.bin")
        precondition(patched.path(for: 4) == "/Users/ab/keep.bin")
        precondition(patched.totalAllocated(of: 0) == 500)
        precondition(patched.totalAllocated(of: 1) == 300)
        precondition(patched.totalAllocated(of: 3) == 200)
        precondition(!patched.entries.contains(where: { patched.name(for: $0.id) == "old.bin" }))

        print("index patcher ok")
    }
}
