// SPDX-License-Identifier: MPL-2.0
import Foundation

private func check(_ value: Bool, _ message: String = "") { precondition(value, message) }

@main struct CleanupPreferenceLearningTests {
    static func main() throws {
        let response = CLIResponse(data: ["warnings": ["existing"]], text: "已恢复", status: 0)
            .addingPreferenceWarnings(["学习未更新"])
        check(response.text.contains("学习未更新"))
        check(response.data["warnings"] as? [String] == ["existing", "学习未更新"])
        check(response.status == 0, "advisory failures cannot turn successful file actions into retryable failures")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/roomy-preference-learning-\(UUID())")
        let trash = root.appendingPathComponent("trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func rustKey(_ project: String) -> CleanupPreferenceKey? {
            var item = ScanItem.trashTarget(path: root.path + "/target/" + project + "/target/debug/incremental/crate-abc",
                name: "crate", size: 5, rule: "Rust 增量缓存", evidence: "fixture", risk: .amber)
            item.cleanupEvidence = .init(version: 1, fingerprint: "fixture", kind: "rustIncremental")
            return CleanupPreferenceKeys.forRule(item)
        }
        check(rustKey("A") != nil && rustKey("A") != rustKey("B"), "ancestor target folder cannot merge independent projects")
        let store = CleanupPreferenceStore(directory: root)
        let ledger = TrashLedger(url: root.appendingPathComponent("pending-trash.json"), trashRoots: [trash.path])
        let path = root.appendingPathComponent("cache").path
        let destination = trash.appendingPathComponent("cache").path
        try Data("cache".utf8).write(to: URL(fileURLWithPath: path))
        var candidate = CleanupCandidate(source: "rule", key: path, title: "cache", size: 5, evidence: "fixture",
            risk: .amber, action: .trash(item: .trashTarget(path: path, name: "cache", size: 5, rule: "fixture", evidence: "fixture", risk: .amber)))
        candidate.entry.preferenceKey = .init(owner: "tool", kind: "cache", scope: "project")
        let list = CleanupList(candidates: [candidate])
        let learning = CleanupPreferenceLearning(store: store, source: .gui)
        let batch = learning.begin()
        try fm.moveItem(atPath: path, toPath: destination)
        let outcome = CleanupOutcome(id: candidate.entry.id, ok: true, message: "", bytes: 5, trashedTo: destination)
        learning.record(outcomes: [outcome], list: list, ledger: ledger, batch: batch)
        check(learning.warnings.isEmpty)
        check(try store.snapshot().events.count == 1)
        let saved = ledger.recoveryItems().first!
        check(saved.preferenceEventID != nil)
        let reloaded = TrashLedger(url: root.appendingPathComponent("pending-trash.json"), trashRoots: [trash.path])
        check(reloaded.recoveryItems().first?.preferenceEventID == saved.preferenceEventID)
        try store.setEnabled(false)
        _ = try learning.restore(ledger: reloaded, id: saved.recoveryID)
        check(fm.fileExists(atPath: path))
        try store.setEnabled(true)
        check(try store.snapshot().events.first?.revokedAt != nil)
        check(try store.snapshot().events.first?.restoredAt == nil)
        let background = CleanupPreferenceLearning(store: store, source: .automatic)
        check(background.begin() == nil)
        let failure = CleanupOutcome(id: candidate.entry.id, ok: false, message: "blocked", bytes: 0)
        learning.record(outcomes: [failure], list: list, ledger: ledger, batch: learning.begin())
        check(try store.snapshot().events.count == 1)
        let copy = candidate.withSize(99).requiringReview("test")
        check(copy.entry.preferenceKey == candidate.entry.preferenceKey)
        let decorated = learning.decorate(list.entries)
        check(decorated.map(\.defaultChecked) == list.entries.map(\.defaultChecked))
        check(decorated.map(\.tier) == list.entries.map(\.tier))
        check(decorated.map(\.selectable) == list.entries.map(\.selectable))
        try store.fenceRecovery()
        do { _ = try CleanupPreferenceStore(directory: root).snapshot(); preconditionFailure("recovery fence must survive restart") } catch {}
        try store.reset()
        check(try store.snapshot().events.isEmpty)
        // Simulate interruption after recovery was saved but before feedback was updated.
        let next = learning.begin()
        try fm.moveItem(atPath: path, toPath: destination)
        learning.record(outcomes: [outcome, outcome], list: list, ledger: ledger, batch: next)
        check(ledger.recoveryItems().count == 1)
        let second = ledger.recoveryItems().first!
        _ = try ledger.restore(id: second.recoveryID, preferenceFeedbackEnabled: true)
        let receiptState = try store.snapshot()
        check(receiptState.events.first?.restoredAt != nil, "receipt corrects preference after interrupted update")
        check(CleanupPreferencePolicy.hint(key: candidate.entry.preferenceKey, snapshot: receiptState)?.score == -1)
        check(ledger.recoveryItems().isEmpty)
        _ = ledger.purge { _ in preconditionFailure("receipts must never become deletion targets") }
        check(try store.snapshot().events.first?.revokedAt != nil, "purge cannot discard recent correction receipts")
        // Corrupt advisory storage cannot undo a completed move or lose its recovery entry.
        let errorBatch = learning.begin()
        try Data("broken".utf8).write(to: root.appendingPathComponent("cleanup-preferences.json"))
        try fm.moveItem(atPath: path, toPath: destination)
        learning.record(outcomes: [outcome], list: list, ledger: ledger, batch: errorBatch)
        check(!learning.warnings.isEmpty)
        check(fm.fileExists(atPath: destination))
        check(ledger.recoveryItems().count == 1)
        check(learning.decorate(list.entries).allSatisfy { $0.preference == nil })
        try tierLearning(trash: trash)
        print("CleanupPreferenceLearningTests passed")
    }

    /// Irreversible successes, declined A rows and learned tier changes.
    static func tierLearning(trash: URL) throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/roomy-tier-learning-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = CleanupPreferenceStore(directory: root)
        let ledger = TrashLedger(url: root.appendingPathComponent("pending-trash.json"), trashRoots: [trash.path])
        var tool = CleanupCandidate(source: "tool", key: "npm", title: "npm 缓存", size: 7, evidence: "fixture", risk: .amber,
            action: .toolClean(.npmCache, scope: "/fixture/.npm"), tier: .rebuildable)
        tool.entry.preferenceKey = CleanupPreferenceKeys.forTool(.npmCache, scope: "/fixture/.npm")
        let toolList = CleanupList(candidates: [tool])
        let toolOutcome = CleanupOutcome(id: tool.entry.id, ok: true, message: "", bytes: 7)

        // An irreversible success is recorded without a ledger entry, with the tier and reversibility it had.
        let gui = CleanupPreferenceLearning(store: store, source: .gui)
        let guiBatch = gui.begin()
        gui.record(outcomes: [toolOutcome], list: toolList, ledger: ledger, batch: guiBatch)
        check(gui.warnings.isEmpty, "\(gui.warnings)")
        var events = try store.snapshot().events
        check(events.count == 1 && events[0].kind == .deletion && events[0].reversible == false && events[0].tier == .rebuildable)
        check(ledger.recoveryItems().isEmpty, "irreversible success has nothing to recover")
        gui.record(outcomes: [toolOutcome, toolOutcome], list: toolList, ledger: ledger, batch: guiBatch)
        check(try store.snapshot().events.count == 1, "deduped by batch and candidate")
        // A failed irreversible action learns nothing.
        gui.record(outcomes: [.init(id: tool.entry.id, ok: false, message: "x", bytes: 0)], list: toolList, ledger: ledger, batch: gui.begin())
        check(try store.snapshot().events.count == 1)

        // Automatic runs never learn, even when handed a valid batch.
        let auto = CleanupPreferenceLearning(store: store, source: .automatic)
        auto.record(outcomes: [toolOutcome], list: toolList, ledger: ledger, batch: gui.begin())
        let path = root.appendingPathComponent("auto-cache").path
        let destination = trash.appendingPathComponent("auto-cache-\(UUID())").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        var cache = CleanupCandidate(source: "rule", key: path, title: "cache", size: 1, evidence: "fixture", risk: .amber,
            action: .trash(item: .trashTarget(path: path, name: "cache", size: 1, rule: "fixture", evidence: "fixture", risk: .amber)),
            tier: .obsolete)
        cache.entry.preferenceKey = .init(owner: "fixture", kind: "cache", scope: "auto")
        try fm.moveItem(atPath: path, toPath: destination)
        auto.record(outcomes: [.init(id: cache.entry.id, ok: true, message: "", bytes: 1, trashedTo: destination)],
                    list: CleanupList(candidates: [cache]), ledger: ledger, batch: gui.begin())
        check(ledger.recoveryItems().count == 1 && ledger.recoveryItems()[0].preferenceEventID == nil, "automatic keeps recovery, not feedback")
        auto.recordDeclined(list: CleanupList(candidates: [cache, tool]), ranIDs: [tool.entry.id], batch: gui.begin())
        check(try store.snapshot().events.count == 1, "automatic source produced no events")

        // Declined: only default-checked, selectable A rows the user left out, once per key per batch, GUI only.
        var keyless = cache; keyless.entry.preferenceKey = nil
        var unchecked = CleanupCandidate(source: "rule", key: "/fixture/u", title: "u", size: 1, evidence: "f", risk: .amber,
            action: .trash(item: .trashTarget(path: "/fixture/u", name: "u", size: 1, rule: "f", evidence: "f", risk: .amber)), tier: .obsolete)
        unchecked.entry.preferenceKey = .init(owner: "fixture", kind: "cache", scope: "u"); unchecked.entry.defaultChecked = false
        var twinEntry = CleanupEntry(id: "twin", title: "cache", size: 2, estimateIsApprox: false, evidence: "f",
            actionLabel: cache.entry.actionLabel, reversible: true, risk: .amber, selectable: true, defaultChecked: true, source: "rule")
        twinEntry.tier = .obsolete; twinEntry.preferenceKey = cache.entry.preferenceKey
        let twin = CleanupCandidate(entry: twinEntry, action: cache.action)
        let declineList = CleanupList(candidates: [tool, cache, twin, keyless, unchecked])
        let cli = CleanupPreferenceLearning(store: store, source: .cli)
        cli.recordDeclined(list: declineList, ranIDs: [tool.entry.id], batch: cli.begin())
        check(try store.snapshot().events.count == 1, "CLI never records declined")
        let declineBatch = gui.begin()
        gui.recordDeclined(list: declineList, ranIDs: [tool.entry.id], batch: declineBatch)
        gui.recordDeclined(list: declineList, ranIDs: [tool.entry.id], batch: declineBatch)
        events = try store.snapshot().events.filter { $0.kind == .declined }
        check(events.count == 1 && events[0].key == cache.entry.preferenceKey && events[0].tier == .obsolete, "\(events)")
        // A key the user did clean in this batch is not declined.
        gui.recordDeclined(list: declineList, ranIDs: ["twin"], batch: gui.begin())
        check(try store.snapshot().events.filter { $0.kind == .declined }.count == 1)
        check(!CleanupPreferencePolicy.rows(snapshot: try store.snapshot()).contains { $0.id == cache.entry.preferenceKey!.id },
              "declined-only keys are not listed as cleanup history")
        // A key with a manual tier is the user's decision: unticking it is not a learning signal.
        try store.setTier(key: cache.entry.preferenceKey!, tier: .obsolete, from: .obsolete, origin: .manual, reason: "r")
        gui.recordDeclined(list: declineList, ranIDs: [tool.entry.id], batch: gui.begin())
        check(try store.snapshot().events.filter { $0.kind == .declined }.count == 1, "no declined event for a manual key")
        try store.undoOverride(keyID: cache.entry.preferenceKey!.id)

        // applyLearning: three days of manual cleanup → learned B, visible through decorate.
        let key = CleanupPreferenceKey(owner: "fixture", kind: "cache", scope: "learned")
        var row = CleanupCandidate(source: "rule", key: "/fixture/l", title: "l", size: 1, evidence: "f", risk: .amber,
            action: .trash(item: .trashTarget(path: "/fixture/l", name: "l", size: 1, rule: "f", evidence: "f", risk: .amber)))
        row.entry.preferenceKey = key
        func days(_ batch: CleanupPreferenceBatch) -> [CleanupPreferenceEvent] {
            [1, 3, 5].map { CleanupPreferenceEvent.deletion(batch: .init(id: UUID().uuidString, generation: batch.generation),
                candidateID: "l-\($0)", title: "l", path: nil, key: key, at: Date().addingTimeInterval(-Double($0) * 86400),
                tier: .review, reversible: true) }
        }
        // A reset between the run and applyLearning drops the learned change.
        let stale = gui.begin()!
        try store.reset()
        let fresh = gui.begin()!
        try store.record(events: days(fresh), generation: fresh.generation)
        gui.applyLearning(entries: [row.entry], batch: stale)
        check(try store.snapshot().overrides.isEmpty, "stale generation writes nothing")
        auto.applyLearning(entries: [row.entry], batch: fresh)
        check(try store.snapshot().overrides.isEmpty, "automatic sources never write tier changes")
        gui.applyLearning(entries: [row.entry], batch: fresh)
        check(gui.warnings.isEmpty, "\(gui.warnings)")
        let learned = try store.snapshot().overrides
        check(learned.count == 1 && learned[0].origin == .learned && learned[0].tier == .rebuildable && learned[0].fromTier == .review)
        let shown = gui.decorate([row.entry])[0]
        check(shown.tier == .rebuildable && shown.tierReason == "Roomy 按你的习惯调整：近 90 天你在 3 个不同日期清理过同类内容",
              shown.tierReason ?? "nil")
        // Running again does not cascade to A.
        gui.applyLearning(entries: [row.entry], batch: gui.begin())
        check(try store.snapshot().overrides.first?.tier == .rebuildable)
        // Recording now carries the tier the user saw (after overrides).
        let seen = CleanupOutcome(id: row.entry.id, ok: true, message: "", bytes: 0)
        let irreversibleRow = CleanupCandidate(entry: row.entry, action: .toolClean(.goBuildCache, scope: "/fixture/go"))
        gui.record(outcomes: [seen], list: CleanupList(candidates: [irreversibleRow]), ledger: ledger, batch: gui.begin())
        check(try store.snapshot().events.contains { $0.candidateID == row.entry.id && $0.tier == .rebuildable })

        // Restoring a factory-A row that is no longer in the list (CLI restore passes no entries) still steps it down.
        let restoredKey = CleanupPreferenceKey(owner: "fixture", kind: "cache", scope: "restored-a")
        let runBatch = gui.begin()!
        let aEvent = CleanupPreferenceEvent.deletion(batch: runBatch, candidateID: "ra", title: "ra", path: nil, key: restoredKey,
            at: Date().addingTimeInterval(-3600), tier: .obsolete, reversible: true)
        try store.record(events: [aEvent], generation: runBatch.generation)
        try store.restore(eventID: aEvent.id)
        gui.applyLearning(entries: [])
        let demoted = try store.snapshot().overrides.first { $0.keyID == restoredKey.id }
        check(demoted?.origin == .learned && demoted?.tier == .rebuildable && demoted?.fromTier == .obsolete, "\(String(describing: demoted))")
        gui.applyLearning(entries: [])
        check(try store.snapshot().overrides.first { $0.keyID == restoredKey.id }?.tier == .rebuildable, "one step only")
    }
}
