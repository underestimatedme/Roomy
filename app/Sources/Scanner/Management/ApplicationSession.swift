// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class ApplicationSession: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var apps: [ApplicationRecord] = []
    private var plan: UninstallPlan?

    func replace(_ value: [ApplicationRecord]) {
        lock.lock(); defer { lock.unlock() }
        generation += 1; apps = value; plan = nil
    }
    func preview(id: String, home: String, runningPaths: [String] = []) throws -> UninstallPlan {
        lock.lock()
        generation += 1; let ticket = generation; plan = nil
        let catalog = apps; let app = apps.first { $0.id == id }
        lock.unlock()
        guard var app else { throw failure("应用不在当前列表中，请刷新") }
        if ApplicationCatalog.isRunning(app.path, processes: runningPaths), !app.running {
            app = ApplicationRecord(id: app.id, title: app.title, version: app.version, bundleID: app.bundleID,
                path: app.path, size: app.size, running: true, system: app.system,
                blockReason: "应用或它的辅助进程正在运行，请先自行退出", identity: app.identity, associationNames: app.associationNames)
        }
        let next = UninstallPlanner.preview(app: app, catalog: catalog, home: home, temporaryDirectories: ApplicationTemporaryDirectory.current(), sizeOf: Self.measure)
        lock.lock(); defer { lock.unlock() }
        guard ticket == generation else { throw failure("已有更新的应用预览，请重新查看") }
        plan = next; return next
    }
    func current(token: String) throws -> UninstallPlan {
        lock.lock(); defer { lock.unlock() }
        guard let plan, plan.token == token else { throw failure("卸载预览已过期，请重新查看") }
        return plan
    }
    func invalidate() { lock.lock(); plan = nil; generation += 1; lock.unlock() }
    static func measure(_ path: String) -> UInt64? {
        let walker = BulkWalker(), bytes = walker.size(of: path)
        return walker.incompleteReads ? nil : bytes
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "RoomyApplications", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
