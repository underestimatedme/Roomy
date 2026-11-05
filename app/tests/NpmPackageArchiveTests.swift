// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import Darwin

@main
struct NpmPackageArchiveTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let path = CommandLine.arguments[2]
            if CommandLine.arguments[1] == "--fifo-digest" { precondition(CacheContent.digest(SHA256.self, path: path, deadline: Date().addingTimeInterval(1)) == nil) }
            else { precondition(CacheContent.smallData(path) == nil) }
            return
        }
        let fm = FileManager.default, directory = fm.temporaryDirectory.appendingPathComponent("roomy-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        // Independent ustar fixtures; production delegates parsing to libarchive.
        func tar(_ entries: [(String, UInt8, String, String)]) -> Data {
            var result = Data()
            for (name, type, body, link) in entries {
                var header = [UInt8](repeating: 0, count: 512)
                func field(_ offset: Int, _ value: String) { for (i, byte) in value.utf8.enumerated() { header[offset+i] = byte } }
                field(0, name); field(100, "0000644\0"); field(108, "0000000\0"); field(116, "0000000\0")
                field(124, String(format: "%011o", body.utf8.count) + "\0"); field(136, "00000000000\0")
                for i in 148..<156 { header[i] = 32 }; header[156] = type
                field(157, link); field(257, "ustar\0"); field(263, "00")
                let sum = header.reduce(0) { $0 + Int($1) }; field(148, String(format: "%06o", sum) + "\0 ")
                result.append(contentsOf: header); result.append(Data(body.utf8))
                result.append(Data(repeating: 0, count: (512 - body.utf8.count % 512) % 512))
            }
            result.append(Data(repeating: 0, count: 1024)); return result
        }
        let file = directory.appendingPathComponent("fixture.tar")
        func inspect(_ entries: [(String, UInt8, String, String)]) throws -> NpmPackageArchive.Contents? {
            try tar(entries).write(to: file)
            return NpmPackageArchive.contents(path: file.path, deadline: Date().addingTimeInterval(5))
        }
        let valid = try inspect([("package/lib/index.js", 48, "hello", "")])
        precondition(valid?.files.keys.sorted() == ["lib/index.js"] && valid?.directories == ["lib"])
        let unsafe: [[(String, UInt8, String, String)]] = [
            [("package/../source", 48, "source", "")], [("/absolute", 48, "source", "")],
            [("another-root/source", 48, "source", "")], [("package/lib//source", 48, "source", "")],
            [("package/./source", 48, "source", "")], [("package/symlink", 50, "", "../../source")],
            [("package/hardlink", 49, "", "package/source")], [("package/fifo", 54, "", "")],
            [("package/source", 48, "one", ""), ("package/source", 48, "two", "")]
        ]
        for entries in unsafe { let result = try inspect(entries); precondition(result == nil, "unsafe archive accepted: \(entries)") }
        try tar([("package/source", 48, "content", "")]).write(to: file)
        precondition(NpmPackageArchive.contents(path: file.path, deadline: .distantPast) == nil)
        let value = " comment=" + String(repeating: "x", count: 256 * 1024) + "\n"
        var length = value.utf8.count + 1
        while String(length).utf8.count + value.utf8.count != length { length = String(length).utf8.count + value.utf8.count }
        let pax = String(length) + value
        try tar([("GlobalPax0", 103, pax, ""), ("package/source", 48, "ok", "")]).write(to: file)
        precondition(NpmPackageArchive.contents(path: file.path, deadline: Date().addingTimeInterval(5), expandedLimit: 128 * 1024) == nil,
            "hidden global PAX metadata must count toward the decompression budget")
        precondition(ProcessRunner().run("/usr/bin/gzip", ["-f", file.path], timeout: 5).ok)
        precondition(NpmPackageArchive.contents(path: file.path + ".gz", deadline: Date().addingTimeInterval(5), expandedLimit: 128 * 1024) == nil,
            "compressed hidden PAX metadata must count toward the expanded budget")
        precondition(NpmPackageArchive.contents(path: file.path + ".gz", deadline: Date().addingTimeInterval(5), expandedLimit: 1024 * 1024) != nil,
            "a supported metadata stream below its expanded limit should remain readable")
        let fifo = directory.appendingPathComponent("fifo").path
        precondition(mkfifo(fifo, 0o600) == 0)
        for mode in ["--fifo-digest", "--fifo-data"] {
            let result = ProcessRunner().run(CommandLine.arguments[0], [mode, fifo], timeout: 1)
            precondition(result.ok && !result.timedOut, "cache reads must reject a FIFO before blocking on open")
        }
        print("NpmPackageArchiveTests passed")
    }
}
