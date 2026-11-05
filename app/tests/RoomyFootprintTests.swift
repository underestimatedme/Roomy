// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

/// Roomy 自身占用的只读统计：全部在临时目录里造数据，绝不读真实用户目录。
@main struct RoomyFootprintTests {
    static func main() throws {
        let fm = FileManager.default
        let temporaryPath = fm.temporaryDirectory.path
        let base = URL(fileURLWithPath: temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath)
            .appendingPathComponent("roomy-footprint-\(UUID())")
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: base) }

        func path(_ relative: String) -> String { base.appendingPathComponent(relative).path }
        func write(_ relative: String, _ bytes: Int) throws {
            try Data(count: bytes).write(to: URL(fileURLWithPath: path(relative)))
        }
        func allocated(_ fullPath: String) -> UInt64 {
            var metadata = stat()
            guard lstat(fullPath, &metadata) == 0 else { return 0 }
            return UInt64(metadata.st_blocks) * 512
        }
        func category(_ footprint: RoomyFootprint, _ id: String) -> FootprintCategory {
            guard let value = footprint.categories.first(where: { $0.id == id }) else { preconditionFailure("missing category \(id)") }
            return value
        }

        // ---- 1. 真实存在的存储文件名各归各类 ----
        // 后缀规则单独列出来：真实索引叫 scan-index-<时间戳>.roomyidx，是这台机器上最大的一份 Roomy 文件
        let cases: [(String, String)] = [
            ("pending-trash.json", "recovery"), ("operations.jsonl", "recovery"),
            ("cleanup-preferences.json", "config"), ("protected-cleanup.json", "config"),
            ("code-roots.json", "config"), ("automation.json", "config"), ("license.json", "config"),
            ("last-scan.json", "index"), ("last-cleanup.json", "index"),
            ("scan-index-2026-11-05-093000.roomyidx", "index"),
            ("scan-index-0001.roomyidx", "index"),
            ("scan-0001.roomyhist", "history"),
            ("SpaceGrowth", "history"), ("operation.lock", "other"), ("unknown.bin", "other")]
        for (name, kind) in cases {
            expect(RoomyFootprintScanner.classify(name) == kind, "\(name) must classify as \(kind), got \(RoomyFootprintScanner.classify(name))")
        }
        expect(RoomyFootprintScanner.classify("scan-index-2026-11-05.roomyidx") != "other",
               "the full scan index never falls back to other")
        expect(RoomyFootprintScanner.details["index"]!.contains("重新扫描生成"),
               "the scan index is described as rebuildable by rescanning")
        expect(RoomyFootprintScanner.titles["index"] == "扫描缓存与索引",
               "the index bucket names the scan cache and index, got \(RoomyFootprintScanner.titles["index"] ?? "nil")")
        expect(RoomyFootprintScanner.details["index"]!.contains(".roomyidx")
               && RoomyFootprintScanner.details["index"]!.contains("按文件夹查看"),
               "the .roomyidx purpose is explained")
        expect(RoomyFootprintScanner.details["history"]!.contains("不会重新生成")
               && RoomyFootprintScanner.details["history"]!.contains("roomyhist"),
               "the old scan records are kept, not described as rebuildable")

        // ---- 2. 应用支持目录按真实文件名分桶，合计只含子项，App 本体单独一行 ----
        try fm.createDirectory(atPath: path("Roomy.app/Contents"), withIntermediateDirectories: true)
        try write("Roomy.app/Contents/binary", 128 * 1_024)
        let support = path("support")
        try fm.createDirectory(atPath: support, withIntermediateDirectories: false)
        for name in ["pending-trash.json", "operations.jsonl", "cleanup-preferences.json",
                     "protected-cleanup.json", "code-roots.json", "last-scan.json", "last-cleanup.json", "unknown.bin"] {
            try write("support/\(name)", 16 * 1_024)
        }
        try fm.createDirectory(atPath: support + "/SpaceGrowth", withIntermediateDirectories: false)
        try write("support/SpaceGrowth/history.json", 32 * 1_024)
        // 真实样本：两个顶级 .roomyidx 互为硬链接，另有子目录里的第三个链接指向同一 inode，合计只算一次
        try write("support/a.roomyidx", 96 * 1_024)
        try fm.linkItem(atPath: support + "/a.roomyidx", toPath: support + "/b.roomyidx")
        try fm.createDirectory(atPath: support + "/nested", withIntermediateDirectories: false)
        try fm.linkItem(atPath: support + "/a.roomyidx", toPath: support + "/nested/c.roomyidx")

        let footprint = RoomyFootprintScanner.measure(appBundle: path("Roomy.app"), appSupport: support, capturedAt: Date())
        expect(Set(footprint.categories.map(\.id)).count == footprint.categories.count, "categories are listed once each")
        expect(footprint.categories.first?.id == "app", "the app bundle comes first")
        expect(footprint.categories.last?.id == "support", "the support total comes last")
        for id in ["index", "history", "config", "recovery", "other"] {
            let bucket = category(footprint, id)
            expect(bucket.bytes != nil && bucket.bytes! > 0, "\(id) must hold real bytes, got \(String(describing: bucket.bytes))")
            expect(bucket.status == "measured", "\(id) must be measured, got \(bucket.status)")
            expect(bucket.fileCount != nil && bucket.fileCount! > 0, "\(id) counts its files")
        }
        expect(category(footprint, "recovery").fileCount == 2, "pending-trash.json and operations.jsonl are the recovery records")
        expect(category(footprint, "config").fileCount == 3, "cleanup preferences, protected list and code roots are configuration")
        expect(category(footprint, "index").fileCount == 4,
               "last-scan.json, last-cleanup.json and the two top-level .roomyidx names are the index")
        expect(category(footprint, "index").bytes ==
               allocated(support + "/last-scan.json") + allocated(support + "/last-cleanup.json")
               + allocated(support + "/a.roomyidx"),
               "a hardlinked index file shared by two top-level names and a subdirectory is charged once: "
               + "\(String(describing: category(footprint, "index").bytes))")
        expect(category(footprint, "history").fileCount == 1, "the growth history file is its own category")
        expect(category(footprint, "history").detail.contains("不会重新生成"), "scan history is not described as a deletable index")
        expect(category(footprint, "recovery").detail.contains("请保留"), "recovery records are not described as deletable")
        let sum = ["index", "history", "config", "recovery", "other"].reduce(UInt64(0)) { $0 + (category(footprint, $1).bytes ?? 0) }
        expect(category(footprint, "support").bytes == sum, "the support total is the sum of its own children only")
        let app = category(footprint, "app")
        expect(app.bytes != nil && app.bytes! > 0 && category(footprint, "support").bytes != app.bytes,
               "the app bundle and the support directory are measured apart and never added together")
        expect(category(footprint, "support").status == "measured" && footprint.warnings.isEmpty,
               "a clean read reports no warnings: \(footprint.warnings)")

        // ---- 3. 跨顶级子项的硬链接只算一次 ----
        let hard = path("hardlinks")
        try fm.createDirectory(atPath: hard + "/a", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: hard + "/b", withIntermediateDirectories: true)
        try write("hardlinks/a/big.bin", 256 * 1_024)
        let beforeLink = category(RoomyFootprintScanner.measure(appBundle: path("Roomy.app"), appSupport: hard), "support").bytes
        try fm.linkItem(atPath: hard + "/a/big.bin", toPath: hard + "/b/same.bin")
        let afterLink = category(RoomyFootprintScanner.measure(appBundle: path("Roomy.app"), appSupport: hard), "support").bytes
        expect(beforeLink != nil && beforeLink! > 0, "the hardlink fixture has real bytes")
        expect(afterLink == beforeLink, "a hardlink shared by two top-level children is charged once: \(String(describing: afterLink)) vs \(String(describing: beforeLink))")

        // ---- 4. 符号链接指向的外部内容不计入，并且有说明 ----
        let outside = path("outside")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try write("outside/huge.bin", 512 * 1_024)
        let links = path("links")
        try fm.createDirectory(atPath: links, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: links + "/external", withDestinationPath: outside)
        try fm.createSymbolicLink(atPath: links + "/external.bin", withDestinationPath: outside + "/huge.bin")
        let linkOnly = RoomyFootprintScanner.measure(appBundle: path("Roomy.app"), appSupport: links)
        expect(category(linkOnly, "support").bytes == 0, "links to outside data are not counted")
        expect(linkOnly.warnings.contains { $0.contains("符号链接") }, "excluded links are explained: \(linkOnly.warnings)")

        let inside = path("inside")
        try fm.createDirectory(atPath: inside + "/data", withIntermediateDirectories: true)
        try write("inside/data/real.bin", 64 * 1_024)
        try fm.createSymbolicLink(atPath: inside + "/data/ext.bin", withDestinationPath: outside + "/huge.bin")
        let inner = RoomyFootprintScanner.measure(appBundle: path("Roomy.app"), appSupport: inside)
        expect(category(inner, "support").bytes == allocated(inside + "/data/real.bin"),
               "a link inside a child directory is skipped while its siblings are measured")

        // ---- 5. 不存在是"未发现"，读不到是"未知"，都不是 0 ----
        let absent = RoomyFootprintScanner.measure(appBundle: path("no-app"), appSupport: path("no-support"))
        expect(category(absent, "app").status == "missing" && category(absent, "app").bytes == nil, "a missing app bundle is reported as missing")
        expect(category(absent, "support").status == "missing" && category(absent, "support").bytes == nil, "a missing support directory has no total")
        expect(absent.warnings.contains { $0.contains("没有找到 App 本体") }, "a missing app bundle is explained")

        let locked = path("locked")
        try fm.createDirectory(atPath: locked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o000])
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        let denied = RoomyFootprintScanner.measure(appBundle: locked + "/inner", appSupport: locked)
        expect(category(denied, "app").status == "unknown" && category(denied, "app").bytes == nil,
               "a permission error is unknown, not missing: \(category(denied, "app").status)")
        expect(category(denied, "support").status == "unknown" && category(denied, "support").bytes == nil,
               "an unreadable support directory must not report 0 bytes as its total")
        expect(denied.warnings.contains { $0.contains("无法确认") || $0.contains("无法读取") }, "the unreadable directory is explained: \(denied.warnings)")

        // ---- 6. 部分读取保留标识和已读到的字节 ----
        let partial = path("partial")
        try fm.createDirectory(atPath: partial + "/keep/secret", withIntermediateDirectories: true)
        try write("partial/keep/f.bin", 64 * 1_024)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: partial + "/keep/secret")
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: partial + "/keep/secret") }
        let partialFootprint = RoomyFootprintScanner.measure(appBundle: path("Roomy.app"), appSupport: partial)
        let other = category(partialFootprint, "other")
        expect(other.status == "partial", "a partially read bucket keeps its marker: \(other.status)")
        expect(other.bytes == allocated(partial + "/keep/f.bin"), "the readable bytes are still reported")
        expect(category(partialFootprint, "support").status == "partial", "the total is marked partial too")
        expect(partialFootprint.warnings.contains { $0.contains("部分") }, "the partial read is explained: \(partialFootprint.warnings)")

        print("RoomyFootprintTests passed: real storage names and .roomyidx/.roomyhist suffixes classified, support total without the app bundle, hardlinks charged once across children and across top-level files, symlinks outside not counted, missing vs unknown vs partial, no zero for unknown bytes")
    }
}
