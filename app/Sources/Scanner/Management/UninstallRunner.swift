// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum UninstallRunner {
    static func run(plan: UninstallPlan, ids: [String], store: CleanupProtectionStore,
                    appRoots: [String], catalogRoots: [String]? = nil, env: CleanupEnvironment,
                    runningPaths: () throws -> [String]) throws -> CleanupRunSummary {
        func refusal(_ message: String) -> NSError {
            NSError(domain: "RoomyUninstall", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard plan.app.blockReason == nil, !plan.app.system,
              plan.app.bundleID != "com.atlaspaces.roomy",
              appRoots.contains(where: { plan.app.path.hasPrefix($0 + "/") }) else {
            throw refusal(plan.app.blockReason ?? "应用不在允许卸载的安装目录中")
        }
        let known = Set(plan.candidates.map { $0.entry.id })
        guard !ids.isEmpty, ids.allSatisfy(known.contains) else { throw refusal("卸载项目不在本次预览中，请重新查看") }
        guard let expected = plan.app.identity, CleanupIdentity.capture(path: plan.app.path) == expected else {
            throw refusal("应用在预览后发生了变化，关联数据也未处理，请重新查看")
        }
        if ApplicationCatalog.isRunning(plan.app.path, processes: try runningPaths()) {
            throw refusal("应用或它的辅助进程正在运行，请先自行退出")
        }
        func ownershipFailure(associationIDs: [String]) -> String? {
            // Sizes are irrelevant here: reread current metadata rather than a
            // cached inventory, without an expensive recursive size scan.
            let inventory = ApplicationCatalog.discover(roots: catalogRoots ?? appRoots, runningPaths: [], sizeOf: { _ in 0 })
            guard let app = inventory.apps.first(where: { $0.path == plan.app.path }),
                  app.bundleID == plan.app.bundleID, app.blockReason == nil else {
                return "应用信息在预览后发生变化，请刷新应用并重新查看"
            }
            if !associationIDs.isEmpty && (!inventory.warnings.isEmpty || inventory.apps.filter({ $0.bundleID == plan.app.bundleID }).count != 1) {
                return "存在共享数据的应用副本，或应用目录未能完整读取；关联项目未处理，请刷新后重新查看"
            }
            if !associationIDs.isEmpty {
                guard plan.nestedBundleSourceIdentities.allSatisfy({ CleanupIdentity.capture(path: $0.key) == $0.value }) else {
                    return "应用组件或组件元数据在预览后变化，关联内容未处理，请刷新预览"
                }
                for id in associationIDs {
                    guard let parents = plan.associationParentIdentities[id], !parents.isEmpty,
                          parents.allSatisfy({ path, before in
                              guard let live = CleanupIdentity.capture(path: path) else { return false }
                              return live.kind == .directory && before.deviceID == live.deviceID && before.fileID == live.fileID
                          }) else { return "关联内容的父目录身份发生变化，已暂停处理，请重新查看预览" }
                }
                let refreshed = UninstallPlanner.preview(app: app, catalog: inventory.apps, home: plan.home, temporaryDirectories: plan.temporaryDirectories, sizeOf: { _ in 0 })
                let allowed = Set(refreshed.candidates.filter { $0.entry.selectable }.map { $0.entry.id })
                if !associationIDs.allSatisfy(allowed.contains) {
                    return "关联内容的归属或读取状态发生变化，已暂停处理，请重新查看预览"
                }
            }
            return nil
        }
        func temporaryRootFailure() -> String? {
            for directory in plan.temporaryDirectories where plan.candidates.contains(where: { ids.contains($0.entry.id) && $0.entry.path?.hasPrefix(directory.path + "/") == true }) {
                guard let before = plan.temporaryIdentities[directory.path], let live = directory.identity(),
                      before.deviceID == live.deviceID, before.fileID == live.fileID, before.kind == live.kind else {
                    return "临时目录身份或读取权限发生变化，已暂停处理，请重新查看预览"
                }
            }
            return nil
        }
        if let message = temporaryRootFailure() { throw refusal(message) }
        let associationIDs = plan.candidates.filter { ids.contains($0.entry.id) && $0.entry.path != plan.app.path }.map { $0.entry.id }
        if let message = ownershipFailure(associationIDs: associationIDs) { throw refusal(message) }
        // Re-read persistent protection at the execution boundary; stale checkboxes cannot bypass it.
        let current = try plan.applying(store)
        var environment = env
        environment.roots = appRoots + [plan.home] + plan.temporaryDirectories.filter { plan.temporaryIdentities[$0.path] != nil }.map { $0.path }
        environment.minimumDepth = 1
        let selected = Set(ids)
        let ordered = current.candidates.filter { selected.contains($0.entry.id) }.sorted {
            ($0.entry.path == plan.app.path ? 1 : 0) < ($1.entry.path == plan.app.path ? 1 : 0)
        }
        let before = env.diskFree()
        var outcomes: [CleanupOutcome] = [], trashed: UInt64 = 0
        var stopped: String?
        for candidate in ordered {
            var blocker: String? = stopped
            do {
                if blocker == nil {
                if let message = temporaryRootFailure() { blocker = message }
                else if ApplicationCatalog.isRunning(plan.app.path, processes: try runningPaths()) { blocker = "应用在处理期间启动了，已暂停后续项目" }
                else if CleanupIdentity.capture(path: plan.app.path) != expected { blocker = "应用在处理期间发生变化，已暂停后续项目" }
                else { blocker = ownershipFailure(associationIDs: candidate.entry.path != plan.app.path ? [candidate.entry.id] : []) }
                }
            } catch { blocker = "无法复核运行状态，已暂停此项目；之前完成的项目仍可查看和恢复" }
            if let message = blocker {
                stopped = message
                let outcome = CleanupOutcome(id: candidate.entry.id, ok: false, message: message, bytes: 0)
                outcomes.append(outcome)
                env.log(["at": ISO8601DateFormatter().string(from: Date()), "title": candidate.entry.title,
                         "ok": false, "message": message, "source": "uninstall"])
                continue
            }
            let result = CleanupRunner.run(ids: [candidate.entry.id], list: CleanupList(candidates: [candidate]), env: environment, progress: { _ in })
            outcomes += result.outcomes; trashed += result.trashedBytes
        }
        let after = env.diskFree()
        return CleanupRunSummary(outcomes: outcomes, freedBytes: after > before ? after - before : 0, trashedBytes: trashed)
    }
}
