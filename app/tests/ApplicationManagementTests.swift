// SPDX-License-Identifier: MPL-2.0
import Foundation

private func expect(_ condition: Bool) { precondition(condition) }

@main struct ApplicationManagementTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp).appendingPathComponent("roomy-apps-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let install = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        func makeApp(_ name: String, _ id: String) throws -> String {
            let app = install.appendingPathComponent(name + ".app")
            try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.2", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app.path
        }
        let appPath = try makeApp("Vendor/Example", "com.example.editor")
        _ = try makeApp("Apple", "com.apple.preview")
        _ = try makeApp("Roomy", "com.atlaspaces.roomy")
        try fm.createSymbolicLink(atPath: install.path + "/linked.app", withDestinationPath: appPath)
        let inventory = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        expect(inventory.apps.count == 3)
        let app = inventory.apps.first { $0.bundleID == "com.example.editor" }!
        expect(app.version == "1.2" && app.blockReason == nil)
        expect(inventory.apps.filter { $0.bundleID != "com.example.editor" }.allSatisfy { $0.blockReason != nil })
        let unreadable = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in nil })
        expect(unreadable.apps.first { $0.id == app.id }!.blockReason != nil)
        let session = ApplicationSession(); session.replace(inventory.apps)
        let latePreview = try session.preview(id: app.id, home: home.path, runningPaths: [appPath + "/Contents/MacOS/helper"])
        expect(latePreview.app.running && latePreview.parts.allSatisfy { !$0.entry.selectable })
        let running = ApplicationCatalog.discover(roots: [install.path], runningPaths: [appPath + "/Contents/MacOS/helper"], sizeOf: { _ in 100 })
        expect(running.apps.first { $0.id == app.id }!.running)
        func folder(_ suffix: String) throws { try fm.createDirectory(atPath: home.path + "/Library/" + suffix, withIntermediateDirectories: true) }
        try folder("Caches/com.example.editor")
        try folder("Application Support/com.example.editor")
        try folder("Application Support/com.example")
        try folder("Caches/com.example.editor2")
        try folder("Group Containers/group.com.example.editor")
        try folder("Containers")
        try fm.createSymbolicLink(atPath: home.path + "/Library/Containers/com.example.editor", withDestinationPath: root.path)
        var plan = UninstallPlanner.preview(app: app, catalog: inventory.apps, home: home.path, sizeOf: { _ in 100 })
        expect(plan.parts.filter { $0.role == "cache" }.count == 1)
        expect(plan.parts.contains { $0.entry.path == home.path + "/Library/Application Support/com.example.editor" && !$0.entry.defaultChecked })
        expect(!plan.candidates.contains { $0.targetPath?.hasSuffix("com.example.editor2") == true || $0.targetPath?.hasSuffix("Application Support/com.example") == true })
        expect(plan.parts.contains { $0.role == "review" && !$0.entry.selectable })
        expect(plan.parts.filter { $0.entry.defaultChecked }.count == 2)
        _ = try makeApp("Copy", "com.example.editor")
        let copies = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        plan = UninstallPlanner.preview(app: app, catalog: copies.apps, home: home.path, sizeOf: { _ in 100 })
        expect(plan.candidates.filter { $0.entry.selectable }.count == 1)
        let runningPlan = UninstallPlanner.preview(app: running.apps.first { $0.id == app.id }!, catalog: running.apps, home: home.path, sizeOf: { _ in 100 })
        expect(!runningPlan.parts.contains { $0.entry.selectable })
        // Dot components must never become category/Library traversal paths.
        for (offset, badID) in [".", "..", "com..example", ".example", "example."].enumerated() {
            let badPath = try makeApp("Malformed\(offset)", badID)
            let records = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
            let bad = records.apps.first { $0.path == badPath }!
            let malformedPlan = UninstallPlanner.preview(app: bad, catalog: records.apps, home: home.path, sizeOf: { _ in 100 })
            expect(malformedPlan.parts.count == 1 && malformedPlan.parts[0].role == "bundle")
            try fm.removeItem(atPath: badPath)
        }
        // Mac-installed iOS apps use Wrapper/*.app/Info.plist, not Contents.
        let ios = install.appendingPathComponent("Wrapped.app")
        let inner = ios.appendingPathComponent("Wrapper/Phone.app")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let iosInfo: [String: Any] = ["CFBundleIdentifier": "com.example.phone", "CFBundleName": "Phone", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: iosInfo, format: .xml, options: 0).write(to: inner.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(atPath: ios.path + "/WrappedBundle", withDestinationPath: "Wrapper/Phone.app")
        var wrapped = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        let phone = wrapped.apps.first { $0.path == ios.path }!
        expect(phone.bundleID == "com.example.phone" && phone.blockReason == nil)
        expect(!wrapped.warnings.contains { $0.contains(ios.path) })
        let secondInner = ios.appendingPathComponent("Wrapper/Other.app")
        try fm.copyItem(at: inner, to: secondInner)
        wrapped = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        expect(wrapped.apps.first { $0.path == ios.path }!.bundleID.isEmpty)
        try fm.removeItem(at: secondInner)
        let innerInfo = inner.appendingPathComponent("Info.plist"), heldInfo = root.appendingPathComponent("HeldInfo.plist")
        try fm.moveItem(at: innerInfo, to: heldInfo)
        try fm.createSymbolicLink(at: innerInfo, withDestinationURL: heldInfo)
        wrapped = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        expect(wrapped.apps.first { $0.path == ios.path }!.bundleID.isEmpty)
        try fm.removeItem(at: innerInfo); try fm.moveItem(at: heldInfo, to: innerInfo)
        // Never read wrapper metadata through a directory or plist symlink.
        try fm.moveItem(at: ios.appendingPathComponent("Wrapper"), to: root.appendingPathComponent("HeldWrapper"))
        try fm.createSymbolicLink(at: ios.appendingPathComponent("Wrapper"), withDestinationURL: root.appendingPathComponent("HeldWrapper"))
        wrapped = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        expect(wrapped.apps.first { $0.path == ios.path }!.bundleID.isEmpty)
        expect(wrapped.warnings.contains { $0.contains(ios.path) })
        try fm.removeItem(at: ios)
        // Non-APPL system packages with a known ID aren't unknown owners.
        let systemInfo = install.appendingPathComponent("Apple.app/Contents/Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"com.apple.preview", "CFBundlePackageType":"XPC!"], format: .xml, options: 0).write(to: systemInfo)
        let knownSystem = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: { _ in 100 })
        expect(!knownSystem.warnings.contains { $0.contains("Apple.app") })
        print("ApplicationManagementTests passed")
    }
}
