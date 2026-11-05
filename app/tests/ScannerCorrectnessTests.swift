// SPDX-License-Identifier: MPL-2.0
import Foundation

private struct FixturePath: Codable { let path: String; let logicalSize: UInt64 }
private struct FixtureManifest: Codable {
    let schema: Int
    let seed: UInt64
    let rootDevice: UInt64
    let expectedPaths: [FixturePath]
    let hardLinkGroups: [[String]]
    let sharedContentCandidates: [String]
    let deniedPaths: [String]
    let disappearingPath: String
}

@main
struct ScannerCorrectnessTests {
    static func main() async throws {
        let location = ProcessInfo.processInfo.environment["ROOMY_CORRECTNESS_ROOT"] ?? "build/fixtures/correctness"
        let root = URL(fileURLWithPath: location).standardizedFileURL
        let manifest = try JSONDecoder().decode(FixtureManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("fixture-manifest.json")))
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
            ofItemAtPath: root.appendingPathComponent(manifest.disappearingPath).path)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(manifest.disappearingPath))
        for path in manifest.deniedPaths {
            try? FileManager.default.setAttributes([.posixPermissions: 0],
                ofItemAtPath: root.appendingPathComponent(path).path)
        }
        defer {
            for path in manifest.deniedPaths {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                    ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }

        let completion = try await runIndexScan(root: root, workerCount: 4)
        let index = completion.index
        let entriesByPath = Dictionary(uniqueKeysWithValues: index.entries.map {
            (String(index.path(for: $0.id).dropFirst(root.path.count + 1)), $0)
        })
        for expected in manifest.expectedPaths {
            guard let entry = entriesByPath[expected.path] else {
                preconditionFailure("missing expected path \(expected.path)")
            }
            precondition(entry.logicalSize == expected.logicalSize)
        }
        for group in manifest.hardLinkGroups {
            let charged = group.compactMap { entriesByPath[$0]?.allocatedSize }
            precondition(charged.filter { $0 > 0 }.count == 1, "hard links must be charged once")
        }
        precondition(entriesByPath["cycles/a/back"]?.kind == .symbolicLink)
        precondition(!entriesByPath.keys.contains { $0.contains("cycles/a/back/a") },
            "symlink cycles must not be traversed")
        precondition(entriesByPath["Example.app"]?.flags.contains(.package) == true)
        precondition(index.totalAllocated(of: 0) == index.entries.reduce(0) { $0 &+ $1.allocatedSize })

        let classified = classifyScanIndex(index)
        let byPath = Dictionary(uniqueKeysWithValues: classified.map {
            (String(index.path(for: $0.entryID).dropFirst(root.path.count + 1)), Set($0.tags))
        })
        precondition(byPath[".ollama/models/example.gguf"]?.contains(.aiModel) == true)
        precondition(byPath["Movies/sample.mov"]?.contains(.media) == true)
        precondition(byPath["Documents/report.pdf"]?.contains(.document) == true)
        for clone in manifest.sharedContentCandidates {
            precondition(entriesByPath[clone]?.flags.contains(.mayShareContent) == true,
                "APFS clone candidates must carry shared-content state")
        }
        precondition(index.entries.allSatisfy { $0.deviceID == manifest.rootDevice },
            "fixture scan must not cross a mount boundary")
        precondition(!entriesByPath.keys.contains { $0.hasPrefix(manifest.disappearingPath) })
        print("scanner correctness ok \(index.entries.count) entries \(index.totalAllocated(of: 0)) bytes")
    }
}
