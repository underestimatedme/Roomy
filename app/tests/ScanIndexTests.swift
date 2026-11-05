// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct ScanIndexTests {
    static func main() {
        var pool = StringPool()
        let example1 = pool.intern("example")
        let example2 = pool.intern("example")
        precondition(example1 == example2)
        precondition(pool.value(for: example1) == "example")

        var index = ScanIndex(stringPool: pool)
        let rootID = index.append(parentID: 0, fileID: 1, deviceID: 9,
            name: "", kind: .directory, logicalSize: 0, allocatedSize: 0,
            modifiedAt: 1, flags: [])
        let usersID = index.append(parentID: rootID, fileID: 2, deviceID: 9,
            name: "Users", kind: .directory, logicalSize: 0, allocatedSize: 0,
            modifiedAt: 1, flags: [])
        let exampleID = index.append(parentID: usersID, fileID: 3, deviceID: 9,
            name: "example", kind: .directory, logicalSize: 0, allocatedSize: 0,
            modifiedAt: 1, flags: [])
        let fileID = index.append(parentID: exampleID, fileID: 4, deviceID: 9,
            name: "model.gguf", kind: .file, logicalSize: 12, allocatedSize: 4096,
            modifiedAt: 2, flags: [])

        index.finalizeAggregates()

        precondition(rootID == 0)
        precondition(index.path(for: fileID) == "/Users/example/model.gguf")
        precondition(index.children(of: rootID) == [usersID])
        precondition(index.children(of: exampleID) == [fileID])
        precondition(index.totalAllocated(of: rootID) == 4096)
        precondition(index.totalAllocated(of: usersID) == 4096)
        precondition(index.totalAllocated(of: fileID) == 4096)
        print("scan index ok")
    }
}
