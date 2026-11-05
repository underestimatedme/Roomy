// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func scheduleExpect(_ value: Bool, _ message: String = "expectation failed") { precondition(value, message) }

private final class ScheduleAgentRunner: CommandRunning {
    var calls: [[String]] = []
    var isLoaded = false
    var failBootstrap = false
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        scheduleExpect(executable == "/bin/launchctl")
        calls.append(arguments)
        if arguments.first == "print" { return .init(status: isLoaded ? 0 : 113, stdout: "", stderr: "", timedOut: false) }
        if arguments.first == "bootstrap" {
            if failBootstrap { return .init(status: 5, stdout: "", stderr: "fixture bootstrap failed", timedOut: false) }
            isLoaded = true
        }
        if arguments.first == "bootout" { isLoaded = false }
        return .init(status: 0, stdout: "", stderr: "", timedOut: false)
    }
}

private struct IdleScheduleRunner: CommandRunning {
    var xcodeRunning = false
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        scheduleExpect(executable == "/bin/ps", "unexpected tool in generated-file test")
        return .init(status: 0, stdout: xcodeRunning ? "/Applications/Xcode.app/Contents/MacOS/Xcode\n" : "/bin/ps\n", stderr: "", timedOut: false)
    }
}

@main struct CLIScheduleTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/roomy-schedule-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let state = root.appendingPathComponent("State"), home = root.appendingPathComponent("Home")
        let cache = home.appendingPathComponent("Library/Caches/fixture/Cache")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("original-cache".utf8).write(to: cache.appendingPathComponent("payload"))
        let scope = AutomationScope(kind: .appCache, path: cache.path, title: "Fixture cache")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var moves = 0, discoveries = 0, confirmations = 0
        var env = AutomationEnvironment()
        env.volume = { AutomationVolume(id: "fixture-volume", path: home.path, total: 1000, available: 500) }
        env.access = {}
        env.discover = { rule in
            discoveries += 1
            if !fm.fileExists(atPath: cache.path) { return [] }
            let item = ScanItem.trashTarget(path: cache.path, name: "Fixture", size: 14, rule: "应用可重建缓存", evidence: "fixture", risk: .amber)
            return [CleanupCandidate(source: "appcache", key: cache.path, title: "Fixture", size: 14, evidence: "fixture", risk: .amber, action: .trash(item: item))]
        }
        env.perform = { snapshot, _ in
            moves += 1
            let target = root.appendingPathComponent("trashed-\(moves)")
            do {
                try fm.moveItem(at: cache, to: target)
                return .init(id: snapshot.id, ok: true, message: "fixture moved", bytes: 14, trashedTo: target.path)
            } catch { return .init(id: snapshot.id, ok: false, message: error.localizedDescription, bytes: 0) }
        }
        func command(_ args: [String], at date: Date = now) throws -> CLIResponse {
            try CLISchedule.run(CLIOptions.parse(["schedule"] + args), state: state, home: home.path,
                                now: date, scopes: { [scope] }, environment: env,
                                confirm: { _ in confirmations += 1 })
        }
        let store = AutomationStore(directory: state.appendingPathComponent("CLISchedules"))
        let add = ["add", "每日缓存", "--every-days", "1", "--scope", cache.path]
        _ = try command(["list"])
        _ = try command(add)
        scheduleExpect(!fm.fileExists(atPath: state.path) && confirmations == 0 && moves == 0, "queries and preview must not create state")
        for args in [["schedule"], ["schedule", "add", "x"],
                     ["schedule", "add", "x", "--every-days", "0", "--scope", cache.path],
                     ["schedule", "list", "--apply"], ["schedule", "run", "--once"],
                     ["scan", "--scope", cache.path], ["schedule", "install", "--yes"]] {
            do { _ = try CLIOptions.parse(args); preconditionFailure("invalid schedule arguments accepted: \(args)") } catch {}
        }
        do { _ = try command(["add", "x", "--every-days", "1", "--scope", home.path, "--apply"]); preconditionFailure("arbitrary directory accepted") } catch {}
        _ = try command(add + ["--apply"])
        let saved = try store.read()
        let id = saved.rules[0].id
        scheduleExpect(saved.rules[0].task == .cliCleanup && saved.rules[0].mode == .automatic)
        scheduleExpect(saved.runtimes[id]?.nextDue == now.addingTimeInterval(86400))
        _ = try command(["run", "--apply"])
        scheduleExpect(moves == 0 && discoveries == 0, "not due means no discovery or moves")
        _ = try command(["run"] , at: now.addingTimeInterval(86400))
        scheduleExpect(moves == 0, "run defaults to preview")
        let due = now.addingTimeInterval(86400)
        // A live GUI/CLI mutation blocks the scheduled action on the SAME operation lease.
        var lease: OperationLease? = try OperationLease.acquire(path: state.appendingPathComponent("operation.lock").path)
        _ = try command(["run", "--apply", "--yes"], at: due)
        scheduleExpect(moves == 0 && fm.fileExists(atPath: cache.path))
        let waiting = try store.read()
        scheduleExpect(waiting.runs.last?.status == .scanning && waiting.runtimes[id]?.retryAt != nil)
        withExtendedLifetime(lease) {}; lease = nil
        _ = try command(["run", "--apply", "--yes"], at: due.addingTimeInterval(900))
        let completed = try store.read()
        scheduleExpect(moves == 1 && completed.runs.last?.status == .completed)
        scheduleExpect(completed.runtimes[id]?.nextDue == due.addingTimeInterval(900 + 86400))
        let ledger = TrashLedger(url: state.appendingPathComponent("pending-trash.json"), trashRoots: [root.path])
        scheduleExpect(ledger.recoveryItems().count == 1, "scheduled moves use the shared recovery ledger")
        scheduleExpect(ledger.recoveryItems()[0].originalPath == cache.path)
        scheduleExpect(!fm.fileExists(atPath: state.appendingPathComponent("automation.json").path), "GUI automation database untouched")
        // A recreated cache is reclassified each round, not replayed using a stale preview ID.
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("new-cache".utf8).write(to: cache.appendingPathComponent("payload"))
        let protection = CleanupProtectionStore(url: state.appendingPathComponent("protected-cleanup.json"))
        let protectedItem = ScanItem.trashTarget(path: cache.path, name: "Fixture", size: 9, rule: "应用可重建缓存", evidence: "", risk: .amber)
        let protectedCandidate = CleanupCandidate(source: "appcache", key: cache.path, title: "Fixture", size: 9, evidence: "", risk: .amber, action: .trash(item: protectedItem))
        try protection.set(protectedCandidate, protected: true)
        _ = try command(["run", "--apply"], at: due.addingTimeInterval(900 + 86400))
        scheduleExpect(moves == 1 && fm.fileExists(atPath: cache.path), "protection added after authorization must win")
        try protection.set(protectedCandidate, protected: false)
        _ = try command(["disable", id, "--apply"])
        scheduleExpect(try store.read().rules[0].enabled == false)
        _ = try command(["run", "--apply"], at: due.addingTimeInterval(4*86400))
        scheduleExpect(moves == 1)
        _ = try command(["enable", id, "--apply"], at: due.addingTimeInterval(4*86400))
        // An interrupted action is not retried until it is manually checked and the rule resumed.
        var interrupted = AutomationRun(ruleID: id, revision: 3, title: "interrupted", createdAt: due, updatedAt: due, reasons: ["time"])
        interrupted.status = .running; interrupted.intentID = "fixture-intent"
        try store.update { db in db.runs.append(interrupted); db.runtimes[id]?.activeRunID = interrupted.id }
        _ = try command(["run", "--apply"], at: due.addingTimeInterval(5*86400))
        scheduleExpect(try store.read().runtimes[id]?.blocker != nil)
        do { _ = try command(["enable", id, "--apply"]); preconditionFailure("unacknowledged intent resumed") } catch {}
        _ = try command(["acknowledge", interrupted.id, "--apply"])
        _ = try command(["enable", id, "--apply"])
        _ = try command(["remove", id, "--apply"])
        scheduleExpect(try store.read().rules.isEmpty)
        scheduleExpect(try store.read().runs.contains { $0.id == interrupted.id }, "removing a rule preserves history")
        // The default GUI environment cannot execute explicit CLI rules either.
        var guiEnv = env
        guiEnv.allowsCLICleanup = false
        try store.update { db in db.rules = saved.rules; db.runtimes[id] = AutomationRuntime(nextDue: due) }
        try AutomationWorker(store: store, environment: guiEnv).tick(now: due)
        let guiDB = try store.read()
        scheduleExpect(moves == 1 && guiDB.runtimes[id]?.blocker != nil, "GUI host must not opt into CLI deletion")

        // launchd lifecycle uses structured argv and verifies failures, with no real user registration in this suite.
        let runner = ScheduleAgentRunner()
        let agent = CLIScheduleAgent(home: home.path, runner: runner)
        let program = root.appendingPathComponent("bin with spaces/roomy")
        try fm.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        try agent.install(executable: program.path)
        scheduleExpect(try agent.loaded())
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent.url), format: nil) as! [String: Any]
        scheduleExpect(plist["ProgramArguments"] as? [String] == [program.path, "schedule", "run", "--apply", "--yes"])
        scheduleExpect(plist["StartInterval"] as? Int == 900)
        try agent.install(executable: program.path)
        scheduleExpect(runner.calls.contains { $0 == ["bootout", agent.target] })
        try agent.uninstall()
        scheduleExpect(!runner.isLoaded && !fm.fileExists(atPath: agent.url.path))
        runner.failBootstrap = true
        do { try agent.install(executable: program.path); preconditionFailure("failed bootstrap reported success") } catch {}
        scheduleExpect(!fm.fileExists(atPath: agent.url.path), "failed install must not leave a login job configured")
        try fm.createSymbolicLink(at: agent.url, withDestinationURL: program)
        do { try agent.uninstall(); preconditionFailure("symlink agent accepted") } catch {}
        scheduleExpect(fm.fileExists(atPath: program.path))
        // Full native discovery -> evidence -> validator -> move -> shared journal -> byte-for-byte restore.
        // Only the process listing and trash destination are substituted; the cleanup path is production code.
        let nativeHome = root.appendingPathComponent("NativeHome"), nativeState = root.appendingPathComponent("NativeState")
        let objects = nativeHome.appendingPathComponent("Library/Developer/Xcode/DerivedData/Fixture/Build/Intermediates.noindex")
        let privateTrash = root.appendingPathComponent("PrivateTrash")
        try fm.createDirectory(at: objects, withIntermediateDirectories: true)
        try fm.createDirectory(at: privateTrash, withIntermediateDirectories: true)
        let objectSource = root.appendingPathComponent("fixture.c")
        try "int scheduled_fixture(void) { return 42; }\n".write(to: objectSource, atomically: true, encoding: .utf8)
        scheduleExpect(ProcessRunner().run("/usr/bin/xcrun", ["clang", "-c", objectSource.path, "-o", objects.appendingPathComponent("fixture.o").path], timeout: 30).ok)
        let bytes = try Data(contentsOf: objects.appendingPathComponent("fixture.o"))
        var nativeCleanup = CleanupEnvironment()
        nativeCleanup.runner = IdleScheduleRunner()
        nativeCleanup.trash = { path in
            let destination = privateTrash.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(atPath: path, toPath: destination.path)
            return destination.path
        }
        func nativeCommand(_ args: [String], at date: Date) throws -> CLIResponse {
            try CLISchedule.run(CLIOptions.parse(["schedule"] + args), state: nativeState, home: nativeHome.path,
                                now: date, cleanup: nativeCleanup, confirm: { _ in })
        }
        _ = try nativeCommand(["add", "Native once", "--every-days", "1", "--scope", objects.path, "--once", "--apply"], at: now)
        let nativeResult = try nativeCommand(["run", "--apply"], at: due)
        scheduleExpect(nativeResult.status == 0 && !fm.fileExists(atPath: objects.path), "production cleanup must move the generated object cache")
        let nativeDB = try AutomationStore(directory: nativeState.appendingPathComponent("CLISchedules")).read()
        scheduleExpect(nativeDB.rules[0].enabled == false && nativeDB.runtimes[nativeDB.rules[0].id]?.nextDue == nil, "one-shot rule disables after one round")
        let nativeLedger = TrashLedger(url: nativeState.appendingPathComponent("pending-trash.json"), trashRoots: [privateTrash.path])
        let recorded = nativeLedger.recoveryItems()
        scheduleExpect(recorded.count == 1)
        _ = try nativeLedger.restore(id: recorded[0].recoveryID)
        scheduleExpect(try Data(contentsOf: objects.appendingPathComponent("fixture.o")) == bytes, "restored bytes must match")
        let operations = try OperationHistory.read(url: nativeState.appendingPathComponent("operations.jsonl"))
        scheduleExpect(operations.count == 1 && operations[0]["client"] as? String == "cli-schedule", "ordinary history includes scheduled operations")
        // Xcode starting before a later round prevents the generated-cache move.
        _ = try nativeCommand(["add", "Blocked by Xcode", "--every-days", "1", "--scope", objects.path, "--apply"], at: now)
        nativeCleanup.runner = IdleScheduleRunner(xcodeRunning: true)
        _ = try nativeCommand(["run", "--apply"], at: due)
        scheduleExpect(fm.fileExists(atPath: objects.path), "running owner must prevent scheduled cleanup")
        print("CLIScheduleTests passed")
    }
}
