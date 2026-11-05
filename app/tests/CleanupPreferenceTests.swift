// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private func check(_ value: Bool, _ message: String = "") { precondition(value, message) }

@main struct CleanupPreferenceTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("roomy-preferences-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CleanupPreferenceStore(directory: root)
        let now = Date()
        let key = CleanupPreferenceKey(owner: "npm", kind: "download", scope: "user")
        check(try store.snapshot(now: now).enabled, "new installations learn by default")
        var ids: [String] = []
        for day in 0..<3 {
            let batch = try store.beginBatch()!
            let event = CleanupPreferenceEvent.deletion(batch: batch, candidateID: "cache", title: "npm", path: "/fixture/cache", key: key, at: now.addingTimeInterval(Double(-day) * 86400))
            ids.append(event.id)
            try store.record(events: [event, event], generation: batch.generation, now: now)
        }
        var snapshot = try store.snapshot(now: now)
        check(snapshot.events.count == 3)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: snapshot, now: now)?.score == 1)
        let oldBatch = try store.beginBatch()!
        try store.setEnabled(false)
        check(try store.beginBatch() == nil)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now), now: now) == nil)
        try store.restore(eventID: ids[0], now: now)
        try store.setEnabled(true)
        snapshot = try store.snapshot(now: now)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: snapshot, now: now) == nil, "disabled restore revokes without adding negative feedback")
        try store.restore(eventID: ids[1], now: now)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now), now: now)?.score == -1)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now.addingTimeInterval(91 * 86400)), now: now.addingTimeInterval(91 * 86400)) == nil)
        try store.reset()
        let late = CleanupPreferenceEvent.deletion(batch: oldBatch, candidateID: "late", title: "late", path: nil, key: key, at: now)
        try store.record(events: [late], generation: oldBatch.generation, now: now)
        try store.restore(eventID: ids[2], now: now)
        check(try store.snapshot(now: now).events.isEmpty, "reset fences late events and old recovery IDs")
        try store.setEnabled(false)
        try store.reset()
        check(try !CleanupPreferenceStore(directory: root).snapshot(now: now).enabled)
        try store.setEnabled(true)
        let batch = try store.beginBatch()!
        var events = (0..<4).map { i in CleanupPreferenceEvent.deletion(batch: batch, candidateID: "\(i)", title: "cache", path: nil, key: key, at: now) }
        try store.record(events: events, generation: batch.generation, now: now)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now), now: now) == nil, "one batch never counts as three days")
        try store.restore(eventID: events[0].id, now: now)
        check(CleanupPreferencePolicy.rows(snapshot: try store.snapshot(now: now), now: now).first?.cleanupDays == 0, "partial restore revokes whole batch contribution")
        let unknown = CleanupPreferenceEvent.deletion(batch: batch, candidateID: "unknown", title: "unknown", path: "/unknown", key: nil, at: now)
        events = [unknown]
        try store.record(events: events, generation: batch.generation, now: now)
        check(CleanupPreferencePolicy.rows(snapshot: try store.snapshot(now: now), now: now).contains { $0.reason == "已记录，暂无同类建议" })
        try store.protect(candidateID: "p", title: "cache", path: nil, key: key, now: now)
        try store.setEnabled(false)
        try store.unprotect(candidateID: "p", now: now)
        check(try store.snapshot(now: now).events.filter { $0.kind == .protection && $0.revokedAt == nil }.isEmpty)
        try Data("broken".utf8).write(to: root.appendingPathComponent("cleanup-preferences.json"))
        do { _ = try store.snapshot(now: now); preconditionFailure("corrupt data must not be overwritten") } catch {}
        try store.reset()
        check(try store.snapshot(now: now).events.isEmpty)
        let lockFD = open(root.appendingPathComponent("cleanup-preferences.lock").path, O_RDWR)
        check(lockFD >= 0)
        check(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        do { _ = try store.snapshot(); preconditionFailure("read must not race an in-flight reset/write") } catch {}
        close(lockFD)
        let boundedBatch = try store.beginBatch()!
        let many = (0..<2005).map { i in CleanupPreferenceEvent.deletion(batch: boundedBatch, candidateID: "bounded-\(i)",
            title: "test", path: nil, key: nil, at: now.addingTimeInterval(-Double(i))) }
        try store.record(events: many, generation: boundedBatch.generation, now: now)
        check(try store.snapshot(now: now).events.count == 2000)
        check(try store.snapshot(now: now).events.contains { $0.id == many[0].id })
        try store.reset()
        let lateRestoreBatch = try store.beginBatch()!
        let oldDelete = CleanupPreferenceEvent.deletion(batch: lateRestoreBatch, candidateID: "old", title: "old", path: nil, key: key,
            at: now.addingTimeInterval(-89 * 86400))
        try store.record(events: [oldDelete], generation: lateRestoreBatch.generation, now: now)
        try store.restore(eventID: oldDelete.id, now: now)
        let later = now.addingTimeInterval(2 * 86400)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: later), now: later)?.score == -1,
            "negative preference lasts 90 days from recovery, not from original deletion")
        try store.reset()
        let crowded = try store.beginBatch()!
        let siblings = (0..<10).map { i in CleanupPreferenceEvent.deletion(batch: crowded, candidateID: "sibling-\(i)",
            title: "siblings", path: nil, key: key, at: now.addingTimeInterval(Double(i - 20))) }
        try store.record(events: siblings, generation: crowded.generation, now: now)
        try store.restore(eventID: siblings[0].id, now: now)
        let fill = try store.beginBatch()!
        let filler = (0..<1995).map { i in CleanupPreferenceEvent.deletion(batch: fill, candidateID: "filler-\(i)",
            title: "filler", path: nil, key: nil, at: now.addingTimeInterval(-0.001 * Double(i))) }
        try store.record(events: filler, generation: fill.generation, now: now)
        let boundedRow = CleanupPreferencePolicy.rows(snapshot: try store.snapshot(now: now), now: now).first { $0.id == key.id }
        check(boundedRow == nil || boundedRow?.cleanupDays == 0, "evicting a restored event cannot revive its siblings")
        try store.reset()
        try Data("[{\"id\":\"p\"}]".utf8).write(to: root.appendingPathComponent("protected-cleanup.json"))
        try store.protect(candidateID: "p", title: "protected", path: nil, key: key, now: now)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now), now: now)?.score == -1)
        // The hard-protection removal succeeded, but its advisory update was interrupted.
        try Data("[]".utf8).write(to: root.appendingPathComponent("protected-cleanup.json"))
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now), now: now) == nil,
            "current protection list must reconcile a missed advisory unprotect")
        try store.reset()
        let midnightBatch = try store.beginBatch()!
        let acrossMidnight = [0, 1].map { i in CleanupPreferenceEvent.deletion(batch: midnightBatch, candidateID: "midnight-\(i)",
            title: "cache", path: nil, key: key, at: now.addingTimeInterval(Double(i - 2) * 86400)) }
        try store.record(events: acrossMidnight, generation: midnightBatch.generation, now: now)
        let secondBatch = try store.beginBatch()!
        try store.record(events: [.deletion(batch: secondBatch, candidateID: "third", title: "cache", path: nil, key: key, at: now)],
            generation: secondBatch.generation, now: now)
        check(CleanupPreferencePolicy.hint(key: key, snapshot: try store.snapshot(now: now), now: now) == nil,
            "a batch spanning midnight still contributes only one cleanup date")
        // Tier overrides share the store's guarantees: manual overrides survive reset, corruption and locks block writes.
        try store.reset()
        try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "m", now: now)
        try store.setEnabled(false)
        check(try store.snapshot(now: now).overrides.count == 1, "overrides remain readable while learning is off")
        try store.reset()
        check(try store.snapshot(now: now).overrides.count == 1, "reset keeps manual overrides")
        let overrideLock = open(root.appendingPathComponent("cleanup-preferences.lock").path, O_RDWR)
        check(overrideLock >= 0 && flock(overrideLock, LOCK_EX | LOCK_NB) == 0)
        do { try store.setTier(key: key, tier: .rebuildable, from: .review, origin: .manual, reason: "x"); preconditionFailure("setTier must respect the lock") } catch {}
        close(overrideLock)
        try Data("broken".utf8).write(to: root.appendingPathComponent("cleanup-preferences.json"))
        do { try store.setTier(key: key, tier: .rebuildable, from: .review, origin: .manual, reason: "x"); preconditionFailure("corrupt data must not be overwritten") } catch {}
        check(try String(contentsOf: root.appendingPathComponent("cleanup-preferences.json"), encoding: .utf8) == "broken")
        try FileManager.default.removeItem(at: root.appendingPathComponent("cleanup-preferences.json"))
        let target = root.appendingPathComponent("target"); try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cleanup-preferences.json"), withDestinationURL: target)
        do { try store.setEnabled(true); preconditionFailure("symlink must be rejected") } catch {}
        check(try String(contentsOf: target, encoding: .utf8) == "sentinel")
        print("CleanupPreferenceTests passed")
    }
}
