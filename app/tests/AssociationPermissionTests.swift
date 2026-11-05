// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

@main struct AssociationPermissionTests {
    static func main() throws {
        let fm = FileManager.default, temp = FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp).appendingPathComponent("roomy-association-permissions-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("Home"), cache = home.appendingPathComponent("Library/Caches"), app = root.appendingPathComponent("Applications/Sample.app")
        try fm.createDirectory(at:app.appendingPathComponent("Contents"), withIntermediateDirectories:true)
        try fm.createDirectory(at:cache.appendingPathComponent("com.sample.editor"), withIntermediateDirectories:true)
        try fm.createDirectory(at:cache.appendingPathComponent("Sample"), withIntermediateDirectories:true)
        let info = ["CFBundleIdentifier":"com.sample.editor", "CFBundleName":"Sample", "CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList:info, format:.xml, options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let inventory = ApplicationCatalog.discover(roots:[root.appendingPathComponent("Applications").path], runningPaths:[], sizeOf:ApplicationSession.measure)
        func preview(_ location: String) -> UninstallPlan { UninstallPlanner.preview(app:inventory.apps[0], catalog:inventory.apps, home:location, sizeOf:ApplicationSession.measure) }
        let alias = root.appendingPathComponent("LinkHome")
        try fm.createSymbolicLink(at:alias, withDestinationURL:home)
        let linked = preview(alias.path)
        expect(linked.parts.count == 1, "an earlier symlink ancestor must not expose association candidates")
        expect(linked.notices.count > 2, "skipped unsafe ancestors must be disclosed")
        guard getuid() != 0 else { throw NSError(domain:"RoomyTests", code:1, userInfo:[NSLocalizedDescriptionKey:"permission test requires an unprivileged user"]) }
        expect(chmod(cache.path, 0) == 0, "fixture chmod must succeed")
        defer { _ = chmod(cache.path, 0o700) }
        let denied = preview(home.path)
        expect(!denied.parts.contains { $0.entry.path?.hasPrefix(cache.path + "/") == true }, "denied cache category must not be selectable or silently measured as empty")
        expect(denied.notices.count > 2, "permission denial must be disclosed")
        _ = chmod(cache.path, 0o700)
        let restored = preview(home.path)
        expect(restored.parts.contains { $0.entry.path == cache.path + "/Sample" && $0.entry.selectable }, "retry after restored permission must discover the cache")
        let legacy = "{\"id\":\"old\",\"title\":\"Sample\",\"version\":\"1\",\"bundleID\":\"com.sample.editor\",\"path\":\"/Applications/Sample.app\",\"size\":1,\"running\":false,\"system\":false}"
        let record = try JSONDecoder().decode(ApplicationRecord.self, from:Data(legacy.utf8))
        expect(record.associationNames == nil, "legacy app records without aliases must still decode")
        print("AssociationPermissionTests passed: symlink ancestor, actual EACCES/retry and legacy serialization")
    }
}
