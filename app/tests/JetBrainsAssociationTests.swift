// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main struct JetBrainsAssociationTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporary.hasPrefix("/var/") ? "/private" + temporary : temporary)
            .appendingPathComponent("roomy-jetbrains-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let installs = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        func file(_ path: String, _ bytes: Data = Data("sample".utf8)) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        func metadata(_ path: String, directory: String = "IdeaIC2024.3", code: String = "IC", version: String = "2024.3.5") throws {
            try file(path + "/Contents/Resources/product-info.json", JSONSerialization.data(withJSONObject:
                ["productCode": code, "version": version, "dataDirectoryName": directory]))
        }
        func app(_ filename: String, id: String = "com.jetbrains.intellij.ce") throws -> String {
            let path = installs.path + "/" + filename + ".app"
            try file(path + "/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList:
                ["CFBundleIdentifier": id, "CFBundleName": "IntelliJ IDEA", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2024.3.5"], format: .xml, options: 0))
            try metadata(path)
            return path
        }
        let appPath = try app("IntelliJ IDEA CE")
        let ultimatePath = try app("IntelliJ IDEA Ultimate", id: "com.jetbrains.intellij")
        try metadata(ultimatePath, directory: "IntelliJIdea2024.3", code: "IU")
        let library = home.path + "/Library"
        for category in ["Caches", "Logs", "Application Support"] {
            for name in ["IdeaIC2024.3", "IdeaIC2024.2", "IdeaIC2024.3-backup", "IntelliJIdea2024.3", "plugins", "PrivacyPolicy"] {
                try file(library + "/" + category + "/JetBrains/" + name + "/sample.bin")
            }
        }
        func plan() -> UninstallPlan {
            let inventory = ApplicationCatalog.discover(roots: [installs.path], runningPaths: [], sizeOf: ApplicationSession.measure)
            return UninstallPlanner.preview(app: inventory.apps.first { $0.path == appPath }!, catalog: inventory.apps,
                home: home.path, sizeOf: ApplicationSession.measure)
        }
        let initial = plan()
        let editions = ApplicationCatalog.discover(roots: [installs.path], runningPaths: [], sizeOf: ApplicationSession.measure)
        let ultimate = UninstallPlanner.preview(app: editions.apps.first { $0.path == ultimatePath }!, catalog: editions.apps,
            home: home.path, sizeOf: ApplicationSession.measure)
        precondition(ultimate.parts.contains { $0.entry.path == library + "/Caches/JetBrains/IntelliJIdea2024.3" && $0.entry.selectable && !$0.entry.defaultChecked }, "Ultimate must use its own verified edition directory")
        precondition(!ultimate.parts.contains { $0.entry.path?.contains("/JetBrains/IdeaIC") == true }, "Ultimate must not claim Community directories")
        for category in ["Caches", "Logs"] {
            let part = initial.parts.first { $0.entry.path == library + "/" + category + "/JetBrains/IdeaIC2024.3" }
            precondition(part != nil, "missing metadata-bound versioned JetBrains " + category)
            precondition(part!.entry.selectable && !part!.entry.defaultChecked, "versioned caches/logs require explicit review")
        }
        let settings = initial.parts.first { $0.entry.path == library + "/Application Support/JetBrains/IdeaIC2024.3" }
        precondition(settings != nil && !settings!.entry.selectable && !settings!.entry.defaultChecked, "IDE settings/plugins must remain review-only")
        precondition(!initial.parts.contains { part in
            let p = part.entry.path ?? ""
            return p.hasSuffix("/JetBrains") || p.contains("IdeaIC2024.2") || p.contains("-backup") || p.contains("IntelliJIdea2024.3") || p.hasSuffix("/plugins") || p.hasSuffix("/PrivacyPolicy")
        }, "vendor roots, other editions/versions and shared content must never become candidates")

        let cachePath = library + "/Caches/JetBrains/IdeaIC2024.3"
        let id = initial.parts.first { $0.entry.path == cachePath }!.entry.id
        var moved: [String] = []
        var env = CleanupEnvironment(); env.diskFree = { 0 }; env.trash = { moved.append($0); return nil }
        let store = CleanupProtectionStore(url: root.appendingPathComponent("protection.json"))
        // A second install can use the same vendor cache even with a different app path.
        let copy = try app("IDE copy", id: "com.jetbrains.unknown")
        precondition(plan().parts.contains { $0.entry.path == cachePath && !$0.entry.selectable }, "shared version directory must be review-only")
        var refused = false
        do { _ = try UninstallRunner.run(plan: initial, ids: [id], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) }
        catch { refused = true }
        precondition(refused && moved.isEmpty, "late shared owner must prevent mutation")
        try fm.removeItem(atPath: copy)
        let trash = root.appendingPathComponent("PrivateTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        env.trash = { path in
            let destination = trash.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(atPath: path, toPath: destination.path)
            return destination.path
        }
        let executable = plan()
        let result = try UninstallRunner.run(plan: executable, ids: [id], store: store,
            appRoots: [installs.path], env: env, runningPaths: { [] })
        precondition(result.outcomes.count == 1 && result.outcomes[0].ok, "selected IDE cache must move through the native runner")
        precondition(!fm.fileExists(atPath: cachePath) && fm.fileExists(atPath: appPath) &&
            fm.fileExists(atPath: library + "/Application Support/JetBrains/IdeaIC2024.3/sample.bin") &&
            fm.fileExists(atPath: library + "/Caches/JetBrains/IdeaIC2024.2/sample.bin"), "only the selected cache moves; IDE, settings and other versions remain")
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let ledger = TrashLedger(url: ledgerURL, trashRoots: [trash.path])
        ledger.record(result.outcomes.map { TrashedItem(path: $0.trashedTo!, bytes: $0.bytes, title: "IDE cache", originalPath: cachePath) })
        let reloaded = TrashLedger(url: ledgerURL, trashRoots: [trash.path])
        for record in reloaded.pending() { _ = try reloaded.restore(id: record.recoveryID) }
        let recovered = try Data(contentsOf: URL(fileURLWithPath: cachePath + "/sample.bin"))
        precondition(recovered == Data("sample".utf8), "IDE cache must restore byte-exactly after ledger reload")
        let fresh = plan()
        try metadata(appPath, directory: "IdeaIC2024.2", version: "2024.2.1")
        refused = false
        do { _ = try UninstallRunner.run(plan: fresh, ids: [id], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) }
        catch { refused = true }
        precondition(refused && moved.isEmpty, "changed product metadata must invalidate old association authority")
        for (directory, code, version) in [("../../other", "IC", "2024.3.5"), ("IdeaIC2024.3", "IU", "2024.3.5"),
                                           ("IdeaIC2024.2", "IC", "2024.3.5"), ("IdeaIC2024.3", "IC", "2024.2.1")] {
            try metadata(appPath, directory: directory, code: code, version: version)
            precondition(!plan().parts.contains { $0.entry.path?.contains("/JetBrains/") == true && $0.entry.selectable }, "invalid product metadata must not authorize a directory")
        }
        try metadata(appPath)
        let productFile = appPath + "/Contents/Resources/product-info.json"
        let held = root.appendingPathComponent("product-info.json").path
        try fm.moveItem(atPath: productFile, toPath: held)
        try fm.createSymbolicLink(atPath: productFile, withDestinationPath: held)
        precondition(!plan().parts.contains { $0.entry.path == cachePath && $0.entry.selectable }, "linked product metadata must be refused")
        try fm.removeItem(atPath: productFile); try fm.moveItem(atPath: held, toPath: productFile)
        let vendor = library + "/Caches/JetBrains", heldVendor = root.appendingPathComponent("HeldCaches").path
        try fm.moveItem(atPath: vendor, toPath: heldVendor)
        try fm.createSymbolicLink(atPath: vendor, withDestinationPath: heldVendor)
        precondition(!plan().parts.contains { $0.entry.path == cachePath && $0.entry.selectable }, "linked vendor cache must be refused")
        print("JetBrainsAssociationTests passed: exact version/edition, shared installs, metadata changes and links; private fixtures only")
    }
}
