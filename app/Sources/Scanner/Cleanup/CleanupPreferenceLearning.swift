// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Only manual entry points create this service. The common cleanup runner never learns.
final class CleanupPreferenceLearning {
    enum Source { case gui, cli, automatic }
    let store: CleanupPreferenceStore
    private let source: Source
    private(set) var warnings: [String] = []

    init(store: CleanupPreferenceStore, source: Source) { self.store = store; self.source = source }
    func attempt(_ body: () throws -> Void) {
        do { try body() } catch { warnings.append(error.localizedDescription) }
    }
    func begin() -> CleanupPreferenceBatch? {
        guard source != .automatic else { return nil }
        do { return try store.beginBatch() } catch { warnings.append(error.localizedDescription); return nil }
    }

    /// Rows as the user saw them: protections are already applied by the caller; tier overrides are applied here.
    private func presented(_ list: CleanupList) -> (entries: [String: CleanupEntry], manualKeys: Set<String>) {
        let overrides = (try? store.snapshot().overrides) ?? []
        let entries = CleanupTierOverrides.apply(list.entries, overrides: overrides)
        return (Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                Set(overrides.filter { $0.origin == .manual }.map(\.keyID)))
    }

    func record(outcomes: [CleanupOutcome], list: CleanupList, ledger: TrashLedger, batch: CleanupPreferenceBatch?) {
        var seen = Set<String>()
        let shown = source != .automatic && batch != nil ? presented(list).entries : [:]
        for outcome in outcomes where outcome.ok && seen.insert(outcome.id).inserted {
            guard let candidate = list.candidate(id: outcome.id) else { continue }
            let reversible = candidate.action?.reversible
            let learns = source != .automatic && candidate.entry.source != "launchagent"
            let tier = shown[outcome.id]?.tier ?? candidate.entry.tier
            guard let destination = outcome.trashedTo else {
                // Irreversible success (tool / Docker / simulator / model removal): nothing to recover, so no ledger entry.
                guard learns, reversible == false, let batch else { continue }
                let event = CleanupPreferenceEvent.deletion(batch: batch, candidateID: outcome.id, title: candidate.entry.title,
                    path: candidate.entry.path, key: candidate.entry.preferenceKey, at: Date(), tier: tier, reversible: false)
                attempt { try store.record(events: [event], generation: batch.generation) }
                continue
            }
            let event = learns && reversible == true ? batch.map { CleanupPreferenceEvent.deletion(batch: $0, candidateID: outcome.id,
                title: candidate.entry.title, path: candidate.entry.path, key: candidate.entry.preferenceKey, at: Date(),
                tier: tier, reversible: true) } : nil
            var item = TrashedItem(path: destination, bytes: outcome.bytes, title: candidate.entry.title,
                originalPath: candidate.entry.path, recoveryNote: candidate.entry.source == "launchagent" ? "启动项文件已还原；后台服务需要手动重新启用" : nil)
            item.preferenceEventID = event?.id
            item.preferenceBatchID = event?.batchID
            item.preferenceKey = event?.key
            // No positive feedback until recovery information has been durably saved.
            do {
                let prior = ledger.recoveryItems().contains { $0.path == destination && $0.preferenceEventID == event?.id }
                if !prior { try ledger.recordChecked([item]) }
            } catch { warnings.append("文件已移入废纸篓，但恢复记录未能保存：" + error.localizedDescription); continue }
            if let event, let batch { attempt { try store.record(events: [event], generation: batch.generation) } }
        }
    }

    /// GUI only: default-checked, selectable A rows the user unticked while running others. One event per key per batch.
    func recordDeclined(list: CleanupList, ranIDs: [String], batch: CleanupPreferenceBatch?) {
        guard source == .gui, let batch else { return }
        let ran = Set(ranIDs)
        let (shown, manualKeys) = presented(list)
        let ranKeys = Set(list.entries.filter { ran.contains($0.id) }.compactMap { $0.preferenceKey?.id })
        var keys = Set<String>()
        var events: [CleanupPreferenceEvent] = []
        let now = Date()
        for original in list.entries {
            guard let entry = shown[original.id], entry.tier == .obsolete, entry.defaultChecked, entry.selectable,
                  entry.source != "launchagent", !ran.contains(entry.id), let key = entry.preferenceKey,
                  !ranKeys.contains(key.id), !manualKeys.contains(key.id), keys.insert(key.id).inserted else { continue }
            events.append(.declined(batch: batch, key: key, title: entry.title, path: entry.path, at: now, candidateID: entry.id))
        }
        guard !events.isEmpty else { return }
        attempt { try store.record(events: events, generation: batch.generation) }
    }

    /// Writes learned tier changes after a manual run or restore. Never from automatic runs; failures are only warnings.
    /// `batch` fences the write: if learning was reset since the run began, nothing is written.
    func applyLearning(entries: [CleanupEntry], batch: CleanupPreferenceBatch? = nil, now: Date = Date()) {
        guard source != .automatic else { return }
        let snapshot: CleanupPreferenceSnapshot
        do { snapshot = try store.snapshot(now: now) } catch { warnings.append(error.localizedDescription); return }
        let generation = batch?.generation ?? snapshot.generation
        guard snapshot.generation == generation else { return }
        for change in CleanupTierLearning.changes(snapshot: snapshot, entries: entries, now: now) {
            attempt {
                try store.setTier(key: change.key, tier: change.tier, from: change.fromTier, origin: .learned,
                                  reason: change.reason, now: now, expectedGeneration: generation)
            }
        }
    }

    func restore(ledger: TrashLedger, id: String) throws -> TrashedItem {
        let record = ledger.recoveryItems().first { $0.recoveryID == id }
        var fenced = false
        var feedbackEnabled = false
        if let eventID = record?.preferenceEventID {
            attempt {
                let state = try store.snapshot()
                feedbackEnabled = state.enabled
                if state.events.contains(where: { $0.id == eventID }) { try store.fenceRecovery(); fenced = true }
            }
        }
        let restored: TrashedItem
        do { restored = try ledger.restore(id: id, preferenceFeedbackEnabled: feedbackEnabled) }
        catch {
            if fenced { attempt { try store.finishRecovery() } }
            throw error
        }
        if let eventID = restored.preferenceEventID {
            attempt {
                try store.restore(eventID: eventID, batchID: restored.preferenceBatchID, key: restored.preferenceKey)
                if fenced { try store.finishRecovery() }
            }
        }
        return restored
    }

    func decorate(_ entries: [CleanupEntry]) -> [CleanupEntry] {
        let snapshot: CleanupPreferenceSnapshot?
        do { snapshot = try store.snapshot() }
        catch { warnings.append(error.localizedDescription); snapshot = nil }
        let hinted = entries.map { entry -> CleanupEntry in
            var result = entry
            result.preference = snapshot.flatMap { CleanupPreferencePolicy.hint(key: entry.preferenceKey, snapshot: $0) }
            return result
        }
        // Tier overrides are the user's own decisions: they apply even when learning is switched off.
        guard let snapshot else {
            // Pinned rows could silently revert to factory A: show factory tiers but check nothing by default.
            warnings.append("档位调整记录暂时无法读取，本次不默认勾选")
            return hinted.map { var e = $0; e.defaultChecked = false; return e }
        }
        return CleanupTierOverrides.apply(hinted, overrides: snapshot.overrides)
    }
}
