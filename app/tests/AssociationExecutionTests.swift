// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

@main struct AssociationExecutionTests {
    static func main() throws {
        let fm = FileManager.default, temp = FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp).appendingPathComponent("roomy-association-run-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let installs = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        let cache = home.appendingPathComponent("Library/Caches/Sublime Text")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cache sample".utf8).write(to: cache.appendingPathComponent("sample.bin"))
        func makeApp(_ filename: String, id: String, title: String) throws -> URL {
            let app = installs.appendingPathComponent(filename + ".app")
            try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier":id, "CFBundleName":title, "CFBundleExecutable":"sublime_text", "CFBundlePackageType":"APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        let app = try makeApp("Sublime Text", id: "com.sample.editor", title: "Sublime Text")
        func preview() -> UninstallPlan {
            let inventory = ApplicationCatalog.discover(roots: [installs.path], runningPaths: [], sizeOf: ApplicationSession.measure)
            return UninstallPlanner.preview(app: inventory.apps.first { $0.path == app.path }!, catalog: inventory.apps, home: home.path, sizeOf: ApplicationSession.measure)
        }
        let plan = preview(), selected = plan.parts.first { $0.entry.path == cache.path }!.entry.id
        let store = CleanupProtectionStore(url: root.appendingPathComponent("protection.json"))
        var moved: [String] = [], env = CleanupEnvironment(); env.diskFree = { 0 }
        env.trash = { path in moved.append(path); return nil }
        // A newly installed app with a different ID still makes a name cache shared.
        let other = try makeApp("Other", id: "com.sample.other", title: "Sublime Text")
        var refused = false
        do { _ = try UninstallRunner.run(plan: plan, ids: [selected], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) }
        catch { refused = true }
        expect(refused && moved.isEmpty, "late same-name owner must refuse before mutation")
        try fm.removeItem(at: other)
        let parent = cache.deletingLastPathComponent(), heldParent = home.appendingPathComponent("HeldCaches")
        try fm.moveItem(at: parent, to: heldParent)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: heldParent.appendingPathComponent("Sublime Text"), to: cache)
        refused = false
        do { _ = try UninstallRunner.run(plan: plan, ids: [selected], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) }
        catch { refused = true }
        expect(refused && moved.isEmpty, "replaced association parent must require a new preview even if the leaf survives")
        // Changing a report's identity field after preview must also refuse.
        let reports = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        try fm.createDirectory(at: reports, withIntermediateDirectories: true)
        let report = reports.appendingPathComponent("sublime_text_2026-10-05-120000.ips")
        try Data("{\"bundleID\":\"com.sample.editor\"}\n{}".utf8).write(to: report)
        let reportPlan = preview(), reportID = reportPlan.parts.first { $0.entry.path == report.path }!.entry.id
        try Data("{\"bundleID\":\"com.sample.other\"}\n{}".utf8).write(to: report)
        refused = false
        do { _ = try UninstallRunner.run(plan: reportPlan, ids: [reportID], store: store, appRoots: [installs.path], env: env, runningPaths: { [] }) }
        catch { refused = true }
        expect(refused && moved.isEmpty, "changed report ownership must refuse before mutation")
        // A conflicting app arriving between preflight and the first item pauses execution.
        let fresh = preview(), freshID = fresh.parts.first { $0.entry.path == cache.path }!.entry.id
        var checks = 0
        let result = try UninstallRunner.run(plan: fresh, ids: [freshID], store: store, appRoots: [installs.path], env: env, runningPaths: {
            checks += 1
            if checks == 2 { _ = try makeApp("Other", id: "com.sample.other", title: "Sublime Text") }
            return []
        })
        expect(result.outcomes.count == 1 && !result.outcomes[0].ok && moved.isEmpty, "mid-run same-name owner must pause execution")
        print("AssociationExecutionTests passed: late/mid-run name ownership and changed report")
    }
}
