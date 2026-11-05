// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct CLIUninstallRecoveryTests {
    static func main() throws {
        let root = "/private/tmp/roomy-cli-uninstall-" + UUID().uuidString, fm = FileManager.default
        defer { try? fm.removeItem(atPath: root) }
        let apps = root + "/Applications", home = root + "/Home", trash = root + "/Trash"
        for path in [apps + "/Sample.app/Contents", home + "/Library/Caches/com.fixture.sample", home + "/Library/Logs/com.fixture.sample", trash] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let info = ["CFBundleIdentifier": "com.fixture.sample", "CFBundleName": "Sample", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: apps + "/Sample.app/Contents/Info.plist"))
        for path in [home + "/Library/Caches/com.fixture.sample/bytes", home + "/Library/Logs/com.fixture.sample/bytes"] {
            try Data("fixture bytes".utf8).write(to: URL(fileURLWithPath: path))
        }
        let inventory = ApplicationCatalog.discover(roots: [apps], runningPaths: [], sizeOf: ApplicationSession.measure)
        let plan = UninstallPlanner.preview(app: inventory.apps[0], catalog: inventory.apps, home: home, sizeOf: ApplicationSession.measure)
        let selected = plan.parts.filter { $0.role == "cache" }.map { $0.entry.id }
        precondition(selected.count == 2)
        let ledger = TrashLedger(url: URL(fileURLWithPath: root + "/ledger.json"), trashRoots: [trash])
        let store = CleanupProtectionStore(url: URL(fileURLWithPath: root + "/protected.json"))
        var env = CleanupEnvironment(); env.diskFree = { 100 }
        env.trash = { path in
            let destination = trash + "/" + UUID().uuidString
            try fm.moveItem(atPath: path, toPath: destination)
            return destination
        }
        env.log = { CLIWorkflow.recordMove($0, list: CleanupList(candidates: plan.candidates), ledger: ledger) }
        var processChecks = 0
        let result = try UninstallRunner.run(plan: plan, ids: selected, store: store, appRoots: [apps], env: env, runningPaths: {
            processChecks += 1
            if processChecks == 3 {
                precondition(ledger.recoveryItems().count == 1, "completed move must already be recorded before next process check")
                throw cliError("fixture process-check failure")
            }
            return []
        })
        precondition(result.outcomes.filter(\.ok).count == 1)
        let record = ledger.recoveryItems()[0]
        _ = try ledger.restore(id: record.recoveryID)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: record.originalPath! + "/bytes"))
        precondition(bytes == Data("fixture bytes".utf8))
        print("CLI partial uninstall durable recovery ok")
    }
}
