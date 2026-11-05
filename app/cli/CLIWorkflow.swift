// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum CLIWorkflow {
    static func recordMove(_ entry: [String: Any], list: CleanupList, ledger: TrashLedger) {
        guard entry["ok"] as? Bool == true, let destination = entry["trashedTo"] as? String, !destination.isEmpty,
              let id = entry["id"] as? String, let candidate = list.candidate(id: id) else { return }
        ledger.record([TrashedItem(path: destination, bytes: candidate.entry.size, title: candidate.entry.title,
            originalPath: candidate.entry.path,
            recoveryNote: candidate.entry.source == "launchagent" ? "文件可恢复；后台服务需手动重新启用" : nil)])
    }

    static func clean(ids: [String], list: CleanupList, store: CleanupProtectionStore,
                      ledger: TrashLedger, environment: CleanupEnvironment, learning: CleanupPreferenceLearning? = nil) throws -> CleanupRunSummary {
        let selected = Array(Set(ids)).sorted()
        guard !selected.isEmpty else { throw cliError("请逐项指定本轮扫描返回的 --id") }
        let current = try store.apply(to: list)
        for id in selected {
            guard let candidate = current.candidate(id: id), candidate.entry.selectable,
                  candidate.entry.tier != .locked, candidate.action != nil else {
                throw cliError("所选项目未知、受保护或不能删；未执行任何清理：\(id)")
            }
        }
        let batch = learning?.begin()
        let before = environment.diskFree()
        var outcomes: [CleanupOutcome] = [], trashed: UInt64 = 0, permanent: UInt64 = 0
        for id in selected {
            let live = try store.apply(to: list)
            let result = CleanupRunner.run(ids: [id], list: live, env: environment, progress: { _ in })
            outcomes += result.outcomes; trashed += result.trashedBytes; permanent += result.permanentBytes
            if let learning {
                learning.record(outcomes: result.outcomes, list: live, ledger: ledger, batch: batch)
            } else {
            ledger.record(result.outcomes.compactMap { outcome in
                guard outcome.ok, let destination = outcome.trashedTo else { return nil }
                let candidate = live.candidate(id: id)
                return TrashedItem(path: destination, bytes: outcome.bytes, title: candidate?.entry.title ?? "",
                    originalPath: candidate?.entry.path,
                    recoveryNote: candidate?.entry.source == "launchagent" ? "文件可恢复；后台服务需手动重新启用" : nil)
            })
            }
        }
        if let learning {
            let entries = (try? store.apply(to: list).entries) ?? current.entries
            learning.applyLearning(entries: entries, batch: batch)
        }
        let after = environment.diskFree()
        return CleanupRunSummary(outcomes: outcomes, freedBytes: after > before ? after - before : 0, trashedBytes: trashed, permanentBytes: permanent)
    }
}
