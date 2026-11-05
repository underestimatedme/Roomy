// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct CleanupEvidenceTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("roomy-evidence-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let root = realpath(temporary, nil).map { p in defer { free(p) }; return String(cString: p) }!
        defer { try? fm.removeItem(atPath: root) }
        let objectSource = root + "/fixture.c", object = root + "/fixture.o"
        try "int fixture(void) { return 0; }".write(toFile: objectSource, atomically: true, encoding: .utf8)
        precondition(ProcessRunner().run("/usr/bin/xcrun", ["clang", "-c", objectSource, "-o", object], timeout: 30).ok)
        func write(_ path: String, _ value: String = "sample") throws {
            try fm.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
            if path.hasSuffix(".o") { try fm.copyItem(atPath: object, toPath: path) }
            else { try value.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        func scanned(_ path: String, _ rule: String) -> ScanItem {
            buildRuleItems([RuleTarget(ruleIndex: RULES.firstIndex { $0.name == rule }!, path: path)], sizes: { _ in 4096 })[0]
        }
        func mustReview(_ item: ScanItem) {
            let c = CleanupListBuilder.fromRule(item)
            precondition(!c.entry.defaultChecked && !c.entry.selectable, "insufficient evidence must not authorize cleanup: \(item.rule)")
            precondition(!item.undo && item.risk != .green, "scan and list must agree: \(item.rule)")
        }
        let node = root + "/project/node_modules"
        try write(node + "/package/index.js", "locally patched source")
        mustReview(scanned(node, "node_modules"))
        try write(root + "/project/package.json", "{\"dependencies\":{\"package\":\"1.0.0\"}}")
        try write(root + "/project/package-lock.json", "{\"lockfileVersion\":3}")
        mustReview(scanned(node, "node_modules")) // A lockfile cannot prove absence of local package edits.
        let venv = root + "/python/.venv"
        try write(venv + "/pyvenv.cfg", "home = /usr/bin")
        try write(venv + "/lib/python3.12/site-packages/private-1.0.dist-info/METADATA", "Name: private\nVersion: 1.0")
        try write(venv + "/lib/python3.12/site-packages/other-1.0.dist-info/METADATA", "Name: other\nVersion: 1.0")
        mustReview(scanned(venv, "Python 虚拟环境")) // Two arbitrary packages are not bootstrap-only.
        let uv = root + "/.cache/uv"
        try write(uv + "/archive-v0/pkg/data")
        mustReview(scanned(uv, "uv 缓存"))
        var oldUV = ScanItem.trashTarget(path: uv, name: "uv", size: 4096, rule: "uv 缓存", evidence: "old cached result", risk: .green)
        // Old snapshots must not bypass the new execution policy.
        if case .allowed = CleanupValidator().validate(path: uv, expected: oldUV, home: root) {
            preconditionFailure("legacy uv trash authorization survived")
        }
        oldUV = oldUV.withSize(8192)
        let derived = root + "/Library/Developer/Xcode/DerivedData/App-abc"
        try write(derived + "/Build/Intermediates.noindex/objects/A.o")
        try write(derived + "/Build/Products/Release-iphoneos/App.app.dSYM/Contents/Resources/DWARF/App")
        let mixed = scanned(derived, "Xcode DerivedData")
        mustReview(mixed)
        let list = CleanupListBuilder.build(items: [mixed], probes: [])
        guard let generated = list.candidates.first(where: { $0.targetPath == derived + "/Build/Intermediates.noindex" }) else {
            preconditionFailure("mixed DerivedData should expose its separately checked generated child")
        }
        precondition(generated.entry.selectable, "ordinary generated objects should still be cleanable")
        guard case .trash(let generatedItem) = generated.action else { preconditionFailure("child action") }
        let previewID = CLISelection.scoped(CleanupList(candidates: [generated])).entries[0].id
        let nested = derived + "/Build/Intermediates.noindex/objects/A.o"
        let topIdentity = CleanupIdentity.capture(path: generatedItem.path)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: nested))
        try handle.seekToEnd(); try handle.write(contentsOf: Data([42])); try handle.close()
        precondition(CleanupIdentity.capture(path: generatedItem.path) == topIdentity, "fixture must leave top directory metadata untouched")
        if case .allowed = CleanupValidator().validate(path: generatedItem.path, expected: generatedItem, home: root) {
            preconditionFailure("nested change must invalidate cleanup evidence")
        }
        let refreshed = CleanupListBuilder.fromRule(CleanupEvidence.applying(to: generatedItem))
        precondition(CLISelection.scoped(CleanupList(candidates: [refreshed])).entries[0].id != previewID,
            "a new scan after deep changes must invalidate the old CLI selection ID")
        let source = root + "/Library/Developer/Xcode/DerivedData/Source-abc"
        try write(source + "/SourcePackages/checkouts/local/OnlyCopy.swift")
        mustReview(scanned(source, "Xcode DerivedData"))
        let normal = root + "/Library/Developer/Xcode/DerivedData/Normal-abc"
        try write(normal + "/Build/Intermediates.noindex/A.o")
        let safe = scanned(normal, "Xcode DerivedData")
        precondition(safe.undo && CleanupListBuilder.fromRule(safe).entry.selectable, "generated-only cache should remain usable")
        let ambiguous = root + "/Library/Developer/Xcode/DerivedData/Ambiguous-abc"
        try write(ambiguous + "/OnlyCopy.pch", "#define PRIVATE_SOURCE 1")
        mustReview(scanned(ambiguous, "Xcode DerivedData"))
        print("CleanupEvidenceTests passed")
    }
}
