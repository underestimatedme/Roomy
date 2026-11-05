// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

struct FixturePath: Codable { let path: String; let logicalSize: UInt64 }
struct FixtureManifest: Codable {
    let schema: Int
    let seed: UInt64
    let rootDevice: UInt64
    let expectedPaths: [FixturePath]
    let hardLinkGroups: [[String]]
    let sharedContentCandidates: [String]
    let deniedPaths: [String]
    let disappearingPath: String
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: make-scan-fixture DESTINATION [--seed N]") }
let destination = URL(fileURLWithPath: arguments[1]).standardizedFileURL
var seed: UInt64 = 42
if let position = arguments.firstIndex(of: "--seed"), position + 1 < arguments.count {
    seed = UInt64(arguments[position + 1]) ?? 42
}
let fm = FileManager.default
let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
guard destination.path != "/", destination.path != home.path else {
    fail("refusing unsafe fixture destination")
}
let parent = destination.deletingLastPathComponent()
if !fm.fileExists(atPath: parent.path) {
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
}
guard let resolvedParent = try? parent.resolvingSymlinksInPath().resourceValues(
    forKeys: [.isDirectoryKey]), resolvedParent.isDirectory == true else {
    fail("fixture parent must be an existing directory")
}
if fm.fileExists(atPath: destination.path) {
    var destinationStat = stat()
    guard lstat(destination.path, &destinationStat) == 0,
          destinationStat.st_mode & S_IFMT == S_IFDIR else {
        fail("fixture destination must be a real directory, not a link")
    }
    guard (try? fm.contentsOfDirectory(atPath: destination.path).isEmpty) == true else {
        fail("fixture destination must be empty")
    }
} else {
    try fm.createDirectory(at: destination, withIntermediateDirectories: false)
}

func write(_ relative: String, bytes: [UInt8]) throws {
    let url = destination.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

func writeSparse(_ relative: String, logicalSize: off_t) throws {
    let url = destination.appendingPathComponent(relative)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    guard fd >= 0, ftruncate(fd, logicalSize) == 0 else { if fd >= 0 { close(fd) }; fail("cannot create sparse fixture") }
    var marker: UInt8 = 1
    _ = withUnsafeBytes(of: &marker) { pwrite(fd, $0.baseAddress, 1, logicalSize - 1) }
    close(fd)
}

var expected: [FixturePath] = []
func record(_ path: String) throws {
    let attributes = try fm.attributesOfItem(atPath: destination.appendingPathComponent(path).path)
    expected.append(FixturePath(path: path,
        logicalSize: (attributes[.size] as? NSNumber)?.uint64Value ?? 0))
}

try write("regular/alpha.bin", bytes: Array(repeating: UInt8(seed & 0xff), count: 4096))
try record("regular/alpha.bin")

let sparse = destination.appendingPathComponent("sparse/large.sparse")
try fm.createDirectory(at: sparse.deletingLastPathComponent(), withIntermediateDirectories: true)
let sparseFD = open(sparse.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
guard sparseFD >= 0 else { fail("cannot create sparse file") }
guard ftruncate(sparseFD, 10 * 1024 * 1024) == 0 else { close(sparseFD); fail("cannot size sparse file") }
var byte = UInt8(seed & 0xff)
_ = withUnsafeBytes(of: &byte) { pwrite(sparseFD, $0.baseAddress, 1, 10 * 1024 * 1024 - 1) }
close(sparseFD)
try record("sparse/large.sparse")

try write("links/original.dat", bytes: Array(repeating: 7, count: 8192))
let hardlink = destination.appendingPathComponent("other/hardlink.dat")
try fm.createDirectory(at: hardlink.deletingLastPathComponent(), withIntermediateDirectories: true)
guard link(destination.appendingPathComponent("links/original.dat").path, hardlink.path) == 0 else {
    fail("cannot create hard link")
}
try record("links/original.dat"); try record("other/hardlink.dat")

try fm.createDirectory(at: destination.appendingPathComponent("cycles/a"), withIntermediateDirectories: true)
try fm.createSymbolicLink(at: destination.appendingPathComponent("cycles/a/back"),
    withDestinationURL: destination.appendingPathComponent("cycles"))
try write("Example.app/Contents/MacOS/payload", bytes: [1, 2, 3, 4])
try record("Example.app/Contents/MacOS/payload")
try writeSparse(".ollama/models/example.gguf", logicalSize: 128 * 1024 * 1024)
try record(".ollama/models/example.gguf")
try writeSparse("Movies/sample.mov", logicalSize: 128 * 1024 * 1024)
try record("Movies/sample.mov")
try writeSparse("Documents/report.pdf", logicalSize: 128 * 1024 * 1024)
try record("Documents/report.pdf")

let denied = destination.appendingPathComponent("denied")
try fm.createDirectory(at: denied, withIntermediateDirectories: true)
try write("denied/secret.bin", bytes: [8])
try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)

let disappearing = "volatile/remove-before-scan"
try fm.createDirectory(at: destination.appendingPathComponent(disappearing), withIntermediateDirectories: true)

var shared: [String] = []
let clone = destination.appendingPathComponent("clones/alpha-clone.bin")
try fm.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
if clonefile(destination.appendingPathComponent("regular/alpha.bin").path, clone.path, 0) == 0 {
    shared.append("clones/alpha-clone.bin")
    try record("clones/alpha-clone.bin")
}

var rootStat = stat()
guard lstat(destination.path, &rootStat) == 0 else { fail("cannot stat fixture root") }
let manifest = FixtureManifest(schema: 1, seed: seed,
    rootDevice: UInt64(UInt32(bitPattern: rootStat.st_dev)), expectedPaths: expected,
    hardLinkGroups: [["links/original.dat", "other/hardlink.dat"]],
    sharedContentCandidates: shared, deniedPaths: ["denied"],
    disappearingPath: disappearing)
let data = try JSONEncoder().encode(manifest)
try data.write(to: destination.appendingPathComponent("fixture-manifest.json"), options: .atomic)
print(destination.path)
