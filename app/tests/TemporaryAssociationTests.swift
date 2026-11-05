// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

@main struct TemporaryAssociationTests {
    static func main() throws {
        let fm = FileManager.default, temp = FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp).appendingPathComponent("roomy-temp-associations-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        let bundle = apps.appendingPathComponent("Sample.app"), cacheRoot = root.appendingPathComponent("C"), tempRoot = root.appendingPathComponent("T")
        func directory(_ path: URL) throws { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        try directory(bundle.appendingPathComponent("Contents"))
        let info = ["CFBundleIdentifier":"com.sample.editor", "CFBundleName":"Sample", "CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        for parent in [cacheRoot, tempRoot] {
            for name in ["com.sample.editor", "com.sample.editor2", "Sample"] {
                let child = parent.appendingPathComponent(name); try directory(child)
                try Data("temporary fixture".utf8).write(to: child.appendingPathComponent("data.bin"))
            }
        }
        let dirs = [ApplicationTemporaryDirectory(path:cacheRoot.path, kind:"cache"), ApplicationTemporaryDirectory(path:tempRoot.path, kind:"temporary")]
        let inventory = ApplicationCatalog.discover(roots:[apps.path], runningPaths:[], sizeOf:ApplicationSession.measure)
        func preview() -> UninstallPlan {
            UninstallPlanner.preview(app:inventory.apps[0], catalog:inventory.apps, home:home.path, temporaryDirectories:dirs, sizeOf:ApplicationSession.measure)
        }
        let plan = preview()
        let cache = plan.parts.first { $0.entry.path == cacheRoot.path + "/com.sample.editor" }
        let temporary = plan.parts.first { $0.entry.path == tempRoot.path + "/com.sample.editor" }
        expect(cache?.entry.selectable == true && cache?.entry.defaultChecked == false, "missing manually reviewed per-user temporary cache")
        expect(temporary?.role == "data" && temporary?.entry.defaultChecked == false, "temporary files can contain unsaved data and must require data confirmation")
        expect(!plan.parts.contains { $0.entry.path?.hasSuffix("com.sample.editor2") == true }, "ID prefixes must never match")
        expect(!plan.parts.contains { $0.entry.path == cacheRoot.path || $0.entry.path == tempRoot.path }, "never select enclosing temporary roots")
        let store = CleanupProtectionStore(url:root.appendingPathComponent("protection.json")), trash = root.appendingPathComponent("TestTrash")
        try directory(trash)
        var env = CleanupEnvironment(); env.diskFree = { 0 }
        env.trash = { path in
            let destination = trash.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(atPath:path, toPath:destination.path); return destination.path
        }
        let result = try UninstallRunner.run(plan:plan, ids:[cache!.entry.id, temporary!.entry.id], store:store, appRoots:[apps.path], env:env, runningPaths:{ [] })
        expect(result.outcomes.count == 2 && result.outcomes.allSatisfy { $0.ok }, "native runner must accept only captured app children of trusted temporary roots")
        let ledgerURL = root.appendingPathComponent("ledger.json"), ledger = TrashLedger(url:ledgerURL, trashRoots:[trash.path])
        ledger.record(result.outcomes.map { outcome in TrashedItem(path:outcome.trashedTo!, bytes:outcome.bytes, title:outcome.id, originalPath:plan.candidates.first { $0.entry.id == outcome.id }!.entry.path) })
        let reloaded = TrashLedger(url:ledgerURL, trashRoots:[trash.path])
        for record in reloaded.pending() { _ = try reloaded.restore(id:record.recoveryID) }
        expect(try Data(contentsOf:cacheRoot.appendingPathComponent("com.sample.editor/data.bin")) == Data("temporary fixture".utf8), "cache recovery must preserve data")
        expect(try Data(contentsOf:tempRoot.appendingPathComponent("com.sample.editor/data.bin")) == Data("temporary fixture".utf8), "temporary recovery must preserve data")
        let fresh = preview(), held = root.appendingPathComponent("HeldC")
        try fm.moveItem(at:cacheRoot, to:held); try directory(cacheRoot)
        let selected = fresh.parts.first { $0.entry.path == cacheRoot.path + "/com.sample.editor" }!.entry.id
        var refused = false
        do { _ = try UninstallRunner.run(plan:fresh, ids:[selected], store:store, appRoots:[apps.path], env:env, runningPaths:{ [] }) }
        catch { refused = true }
        expect(refused, "replaced temporary root must not inherit execution authority")
        try fm.removeItem(at:cacheRoot); try fm.createSymbolicLink(at:cacheRoot, withDestinationURL:held)
        expect(!preview().parts.contains { $0.entry.path?.hasPrefix(cacheRoot.path + "/") == true }, "temporary root symlink must be skipped")
        print("TemporaryAssociationTests passed: private temporary cache/data uninstall and reload/restore")
    }
}
