// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func expect(_ condition: Bool) { precondition(condition) }

@main struct UninstallRunnerTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.path
        let base = temp.hasPrefix("/var/") ? "/private" + temp : temp
        let root = URL(fileURLWithPath: base).appendingPathComponent("roomy-uninstall-\(UUID())")
        let apps = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        let app = apps.appendingPathComponent("Sample.app"), cache = home.appendingPathComponent("Library/Caches/com.sample.editor")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.sample.editor", "CFBundleName": "Sample", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        defer { try? fm.removeItem(at: root) }
        let store = CleanupProtectionStore(url: root.appendingPathComponent("protection.json"))
        let inventory = ApplicationCatalog.discover(roots: [apps.path], runningPaths: [], sizeOf: { _ in 10 })
        var plan = UninstallPlanner.preview(app: inventory.apps[0], catalog: inventory.apps, home: home.path, sizeOf: { _ in 10 })
        let ids = plan.parts.filter { $0.entry.selectable }.map { $0.entry.id }
        var moved: [String] = []
        var env = CleanupEnvironment(); env.diskFree = { 0 }
        env.trash = { path in moved.append(path); return nil }
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env,
                runningPaths: { [app.path + "/Contents/MacOS/helper"] })
            preconditionFailure("running app")
        } catch { }
        expect(moved.isEmpty)
        try store.set(plan.candidates.first { $0.entry.path == cache.path }!, protected: true)
        let guarded = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
        expect(moved == [app.path] && guarded.outcomes.contains { !$0.ok })
        try store.remove(id: plan.candidates.first { $0.entry.path == cache.path }!.entry.id)
        moved = []
        // A duplicate installed after preview makes associated data shared.
        let duplicate = apps.appendingPathComponent("Second.app")
        try fm.copyItem(at: app, to: duplicate)
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
            preconditionFailure("late shared owner must block")
        } catch { }
        expect(moved.isEmpty)
        try fm.removeItem(at: duplicate)
        // The same ownership change during a run pauses every remaining item.
        var ownershipChecks = 0
        let lateOwner = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: {
            ownershipChecks += 1
            if ownershipChecks == 2 { try fm.copyItem(at: app, to: duplicate) }
            return []
        })
        expect(moved.isEmpty && lateOwner.outcomes.allSatisfy { !$0.ok })
        try fm.removeItem(at: duplicate)
        let incomplete = apps.appendingPathComponent("Unreadable.app")
        try fm.createDirectory(at: incomplete, withIntermediateDirectories: true)
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
            preconditionFailure("unknown bundle owner must block associations")
        } catch { }
        expect(moved.isEmpty)
        try fm.removeItem(at: incomplete)
        expect(ApplicationCatalog.discover(roots: [apps.path, root.appendingPathComponent("Missing").path], runningPaths: [], sizeOf: { _ in 0 }).warnings.isEmpty)
        let deepRoot = apps.appendingPathComponent("a")
        let deep = deepRoot.appendingPathComponent("b/c/d/e/DeepCopy.app")
        try fm.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: app, to: deep)
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
            preconditionFailure("bounded inventory must disclose incomplete ownership")
        } catch { }
        expect(moved.isEmpty)
        try fm.removeItem(at: deepRoot)
        // Editing nested metadata may leave the bundle directory identity unchanged.
        let info = app.appendingPathComponent("Contents/Info.plist")
        let originalInfo = try Data(contentsOf: info)
        var changedInfo = plist; changedInfo["CFBundleIdentifier"] = "com.sample.other"
        try PropertyListSerialization.data(fromPropertyList: changedInfo, format: .xml, options: 0).write(to: info)
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
            preconditionFailure("changed metadata must block")
        } catch { }
        expect(moved.isEmpty)
        try originalInfo.write(to: info)
        // Replacing the bundle after preview refuses all related-data removal too.
        try fm.moveItem(at: app, to: apps.appendingPathComponent("held.app"))
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
            preconditionFailure("replacement bundle")
        } catch { }
        expect(moved.isEmpty)
        try fm.removeItem(at: app); try fm.moveItem(at: apps.appendingPathComponent("held.app"), to: app)
        // Restoring identical bytes does not restore the metadata identity from
        // preview. A stale plan must still refuse; successful runs need a new one.
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
            preconditionFailure("rewritten metadata requires a fresh preview")
        } catch { }
        expect(moved.isEmpty)
        let refreshed = ApplicationCatalog.discover(roots: [apps.path], runningPaths: [], sizeOf: { _ in 10 })
        plan = UninstallPlanner.preview(app: refreshed.apps[0], catalog: refreshed.apps, home: home.path, sizeOf: { _ in 10 })
        // Partial failure retains the failed path; other successes are independently reported.
        env.trash = { path in
            if path == cache.path { throw NSError(domain: "sample", code: 1) }
            moved.append(path); return "/sample-trash/Sample.app"
        }
        let partial = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
        expect(partial.outcomes.filter { $0.ok }.count == 1 && partial.outcomes.filter { !$0.ok }.count == 1)
        expect(moved == [app.path] && fm.fileExists(atPath: cache.path))
        moved = []; env.trash = { path in moved.append(path); return "/sample-trash/" + URL(fileURLWithPath: path).lastPathComponent }
        var processChecks = 0
        let interrupted = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [apps.path], env: env, runningPaths: {
            processChecks += 1
            if processChecks >= 3 { throw NSError(domain: "process-check", code: 1) }
            return []
        })
        expect(interrupted.outcomes.filter { $0.ok }.count == 1 && interrupted.outcomes.filter { !$0.ok }.count == 1)
        // The app must remain in a registered install scope.
        do {
            _ = try UninstallRunner.run(plan: plan, ids: ids, store: store, appRoots: [home.path], env: env, runningPaths: { [] })
            preconditionFailure("outside installation roots")
        } catch { }
        // End-to-end private sample: move bundle/cache, persist ledger, reload,
        // restore both and compare bytes. Never use the user's actual Trash.
        let sampleTrash = root.appendingPathComponent("SampleTrash")
        try fm.createDirectory(at: sampleTrash, withIntermediateDirectories: true)
        let cacheFile = cache.appendingPathComponent("sample.bin")
        let sampleData = Data("recoverable sample cache".utf8)
        try sampleData.write(to: cacheFile)
        let currentApps = ApplicationCatalog.discover(roots: [apps.path], runningPaths: [], sizeOf: ApplicationSession.measure)
        let actualPlan = UninstallPlanner.preview(app: currentApps.apps[0], catalog: currentApps.apps, home: home.path, sizeOf: ApplicationSession.measure)
        env.trash = { path in
            let destination = sampleTrash.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
            try fm.moveItem(atPath: path, toPath: destination.path)
            return destination.path
        }
        let actual = try UninstallRunner.run(plan: actualPlan, ids: actualPlan.parts.filter { $0.entry.selectable }.map { $0.entry.id }, store: store, appRoots: [apps.path], env: env, runningPaths: { [] })
        expect(actual.outcomes.count == 2 && actual.outcomes.allSatisfy { $0.ok })
        expect(!fm.fileExists(atPath: app.path) && !fm.fileExists(atPath: cache.path))
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let ledger = TrashLedger(url: ledgerURL, trashRoots: [sampleTrash.path])
        ledger.record(actual.outcomes.map { outcome in
            TrashedItem(path: outcome.trashedTo!, bytes: outcome.bytes, title: outcome.id,
                originalPath: actualPlan.candidates.first { $0.entry.id == outcome.id }!.entry.path)
        })
        let reloaded = TrashLedger(url: ledgerURL, trashRoots: [sampleTrash.path])
        expect(reloaded.pending().count == 2)
        for item in reloaded.pending() { _ = try reloaded.restore(id: item.recoveryID) }
        expect(try Data(contentsOf: info) == originalInfo)
        expect(try Data(contentsOf: cacheFile) == sampleData)
        expect(reloaded.pending().isEmpty)
        print("UninstallRunnerTests passed (including temporary uninstall/recovery)")
    }
}
