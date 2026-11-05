// SPDX-License-Identifier: MPL-2.0
import Foundation

/// 详情里展开一项：直接子项按大小排、超出的合成一行；文件、链接、不存在的路径不展开
@main
struct FolderContentsTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("roomy-contents-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        func file(_ path: String, _ bytes: Int) throws {
            let full = base + "/" + path
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: URL(fileURLWithPath: full))
        }
        try file("nm/big/a/b/c.bin", 400_000)
        try file("nm/big/d.bin", 100_000)
        try file("nm/mid/x.bin", 200_000)
        try file("nm/readme.txt", 50_000)
        for i in 0..<4 { try file("nm/tiny\(i)/f", 4_096) }
        try fm.createSymbolicLink(atPath: base + "/nm/link", withDestinationPath: base + "/nm/big")

        let all = FolderContents.list(path: base + "/nm")!
        precondition(all.path == base + "/nm" && all.moreCount == 0)
        precondition(all.children.map(\.name).prefix(3) == ["big", "mid", "readme.txt"], "\(all.children.map(\.name))")
        precondition(!all.children.contains { $0.name == "link" }, "links are not followed or listed")
        precondition(all.children[0].isDir && !all.children[2].isDir)
        precondition(all.children[0].size >= 500_000 && all.children[0].size == BulkWalker().measureTargets([base + "/nm/big"])[base + "/nm/big"])

        let cut = FolderContents.list(path: base + "/nm/", limit: 3)!
        precondition(cut.path == base + "/nm" && cut.children.count == 3 && cut.moreCount == 4)
        precondition(cut.moreSize == all.children.dropFirst(3).reduce(0) { $0 + $1.size })

        precondition(FolderContents.list(path: base + "/nm/readme.txt") == nil)
        precondition(FolderContents.list(path: base + "/nm/link") == nil)
        precondition(FolderContents.list(path: base + "/missing") == nil)
        print("FolderContentsTests passed")
    }
}
