// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct NestedBundleAssociationTests {
    static func main() throws {
        func expect(_ value: Bool, _ message: String) { precondition(value, message) }
        let fm = FileManager.default, temp = FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp).appendingPathComponent("roomy-nested-associations-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let installs = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        func directory(_ path: URL) throws { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        func makeBundle(_ path: URL, id: String, package: String = "APPL") throws {
            try directory(path.appendingPathComponent("Contents/MacOS"))
            let info = ["CFBundleIdentifier": id, "CFBundleName": path.deletingPathExtension().lastPathComponent, "CFBundlePackageType": package, "CFBundleExecutable": "helper"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
            try Data("private executable fixture".utf8).write(to: path.appendingPathComponent("Contents/MacOS/helper"))
        }
        let app = installs.appendingPathComponent("Parent.app"), helper = app.appendingPathComponent("Contents/PlugIns/Share.appex")
        try makeBundle(app, id: "com.fixture.parent")
        try makeBundle(helper, id: "com.fixture.parent.share", package: "XPC!")
        try makeBundle(app.appendingPathComponent("Contents/Helpers/Foreign.app"), id: "org.foreign.updater")
        let targets = ["Caches/com.fixture.parent.share", "Preferences/com.fixture.parent.share.plist", "Application Scripts/com.fixture.parent", "Application Scripts/com.fixture.parent.share", "Containers/com.fixture.parent.share"]
        for suffix in targets {
            let path = home.appendingPathComponent("Library/" + suffix)
            if suffix.hasSuffix(".plist") { try directory(path.deletingLastPathComponent()); try Data("fixture prefs".utf8).write(to: path) }
            else { try directory(path); try Data("private fixture".utf8).write(to: path.appendingPathComponent("keep.bin")) }
        }
        for suffix in ["Caches/com.fixture.parent.guessed", "Caches/org.foreign.updater", "Group Containers/group.com.fixture.parent.share"] { try directory(home.appendingPathComponent("Library/" + suffix)) }
        func inventory(_ running: [String] = []) -> ApplicationInventory { ApplicationCatalog.discover(roots: [installs.path], runningPaths: running, sizeOf: { _ in 1 }) }
        func preview(_ running: [String] = []) -> UninstallPlan {
            let found = inventory(running)
            return UninstallPlanner.preview(app: found.apps.first { $0.path == app.path }!, catalog: found.apps, home: home.path, sizeOf: ApplicationSession.measure)
        }
        let temporary = root.appendingPathComponent("DarwinCache")
        try directory(temporary.appendingPathComponent("com.fixture.parent.share"))
        let tempInventory = inventory()
        let tempPlan = UninstallPlanner.preview(app: tempInventory.apps.first { $0.path == app.path }!, catalog: tempInventory.apps,
            home: home.path, temporaryDirectories: [ApplicationTemporaryDirectory(path: temporary.path, kind: "cache")], sizeOf: ApplicationSession.measure)
        expect(tempPlan.parts.contains { $0.entry.path == temporary.path + "/com.fixture.parent.share" && $0.entry.selectable && !$0.entry.defaultChecked }, "proven nested temporary cache remains manual")
        let plan = preview()
        for suffix in targets {
            let part = plan.parts.first { $0.entry.path == home.path + "/Library/" + suffix }
            expect(part != nil && part!.entry.selectable && !part!.entry.defaultChecked, "metadata-proven association missing or preselected: " + suffix)
        }
        expect(!plan.parts.contains { $0.entry.path?.contains("com.fixture.parent.guessed") == true || $0.entry.path?.contains("org.foreign.updater") == true }, "prefix and foreign helper must not establish ownership")
        expect(!preview([helper.path + "/Contents/MacOS/helper"]).parts.contains { $0.entry.selectable }, "running nested executable protects parent associations")
        let store = CleanupProtectionStore(url: root.appendingPathComponent("protection.json"))
        var moved: [String] = [], env = CleanupEnvironment(); env.diskFree = { 0 }; env.trash = { moved.append($0); return nil }
        let selected = plan.parts.first { $0.entry.path == home.path + "/Library/Caches/com.fixture.parent.share" }!.entry.id
        // Another installation carrying this identifier makes it shared even if
        // that other app has a different parent namespace.
        let other = installs.appendingPathComponent("Other.app")
        try makeBundle(other, id: "com.fixture.other")
        try makeBundle(other.appendingPathComponent("Contents/PlugIns/Other.appex"), id: "com.fixture.parent.share", package: "XPC!")
        expect(preview().parts.contains { $0.entry.path == home.path + "/Library/Caches/com.fixture.parent.share" && !$0.entry.selectable }, "duplicate nested identity protected")
        var refused = false
        do { _ = try UninstallRunner.run(plan: plan, ids: [selected], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) } catch { refused = true }
        expect(refused && moved.isEmpty, "late duplicate must stop mutation")
        try fm.removeItem(at: other)
        // Replacing metadata with the SAME ID must invalidate the old proof.
        let replacement = helper.appendingPathComponent("Contents/Info.plist")
        let held = root.appendingPathComponent("held.plist")
        try fm.moveItem(at: replacement, to: held); try fm.copyItem(at: held, to: replacement)
        refused = false
        do { _ = try UninstallRunner.run(plan: plan, ids: [selected], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) } catch { refused = true }
        expect(refused && moved.isEmpty, "same-ID replacement invalidates source proof")
        try fm.removeItem(at: replacement); try fm.createSymbolicLink(at: replacement, withDestinationURL: held)
        expect(!preview().parts.contains { $0.entry.path == home.path + "/Library/Caches/com.fixture.parent.share" && $0.entry.selectable }, "linked metadata cannot grant ownership")
        try fm.removeItem(at: replacement); try fm.moveItem(at: held, to: replacement)
        let fresh = preview(), freshID = fresh.parts.first { $0.entry.path == home.path + "/Library/Caches/com.fixture.parent.share" }!.entry.id
        refused = false
        do { _ = try UninstallRunner.run(plan: fresh, ids: [freshID], store: store, appRoots: [installs.path], env: env, runningPaths: { [helper.path + "/Contents/MacOS/helper"] }) } catch { refused = true }
        expect(refused && moved.isEmpty, "late helper process must stop mutation")
        // A correctly proven, explicitly selected fixture can pass authority checks.
        let success = try UninstallRunner.run(plan: fresh, ids: [freshID], store: store, appRoots: [installs.path], env: env, runningPaths: { [] })
        expect(success.outcomes.count == 1 && success.outcomes[0].ok && moved == [home.path + "/Library/Caches/com.fixture.parent.share"], "valid explicit association reaches only selected fixture")
        moved.removeAll()
        let heldHelper = root.appendingPathComponent("HeldHelper.appex")
        try fm.moveItem(at: helper, to: heldHelper); try fm.createSymbolicLink(at: helper, withDestinationURL: heldHelper)
        expect(!preview().parts.contains { $0.entry.path == home.path + "/Library/Caches/com.fixture.parent.share" && $0.entry.selectable }, "linked nested bundle cannot grant ownership")
        try fm.removeItem(at: helper); try fm.moveItem(at: heldHelper, to: helper)
        let broad = app.appendingPathComponent("Contents/Helpers")
        for index in 0..<257 { try Data().write(to: broad.appendingPathComponent("fixture-\(index)")) }
        expect(!preview().parts.contains { $0.entry.path == home.path + "/Library/Caches/com.fixture.parent.share" && $0.entry.selectable }, "bounded discovery failure protects associations")
        for index in 0..<257 { try fm.removeItem(at: broad.appendingPathComponent("fixture-\(index)")) }
        let oldInventory = inventory(), oldRecord = oldInventory.apps.first { $0.path == app.path }!
        let heldApp = root.appendingPathComponent("Held.app"); try fm.moveItem(at: app, to: heldApp)
        try makeBundle(app, id: "com.fixture.parent")
        let replaced = UninstallPlanner.preview(app: oldRecord, catalog: oldInventory.apps, home: home.path, sizeOf: { _ in 1 })
        expect(!replaced.parts.contains { targets.map { home.path + "/Library/" + $0 }.contains($0.entry.path ?? "") && $0.entry.selectable }, "replaced app must not authorize metadata associations")
        print("NestedBundleAssociationTests passed; generated fixtures only")
    }
}
