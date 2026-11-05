// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

@main struct ApplicationAssociationTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temp.hasPrefix("/var/") ? "/private" + temp : temp).appendingPathComponent("roomy-associations-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let install = root.appendingPathComponent("Applications"), home = root.appendingPathComponent("Home")
        func directory(_ path: String) throws { try fm.createDirectory(atPath: path, withIntermediateDirectories: true) }
        func file(_ path: String, _ value: String = "sample") throws {
            try directory((path as NSString).deletingLastPathComponent)
            try Data(value.utf8).write(to: URL(fileURLWithPath: path))
        }
        func app(_ name: String, _ id: String, _ executable: String) throws -> String {
            let path = install.path + "/" + name + ".app"
            try directory(path + "/Contents")
            let info = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": executable, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
            return path
        }
        // Literal bundle IDs and on-disk names model ordinary installed bundles;
        // these are generated samples, not evidence of testing the vendor app.
        let samples: [(String, String, String)] = [
            ("Sublime Text", "com.sublimetext.4", "sublime_text"),
            ("Google Chrome", "com.google.Chrome", "Google Chrome"),
            ("Visual Studio Code", "com.microsoft.VSCode", "Electron"),
            ("Firefox", "org.mozilla.firefox", "firefox"),
            ("Slack", "com.tinyspeck.slackmacgap", "Slack"),
            ("Discord", "com.hnc.Discord", "Discord"),
            ("Notion", "notion.id", "Notion"),
            ("Obsidian", "md.obsidian", "Obsidian"),
            ("Zoom", "us.zoom.xos", "zoom.us"),
            ("Spotify", "com.spotify.client", "Spotify"),
            ("Microsoft Word", "com.microsoft.Word", "Microsoft Word"),
            ("Docker", "com.docker.docker", "Docker")
        ]
        for (name, id, executable) in samples { _ = try app(name, id, executable) }
        let library = home.path + "/Library"
        for (name, id, executable) in samples {
            try file(library + "/Caches/" + name + "/cache.bin")
            try file(library + "/Caches/" + id + "/cache.bin")
            try file(library + "/Caches/" + name + " Beta/keep.bin")
            try file(library + "/Application Support/CrashReporter/" + executable + "_7BF74FC8-74C9-5B85-98A6-82BC65226812.plist")
            try file(library + "/Logs/DiagnosticReports/" + executable + "_2026-10-05-120000.ips", "{\"bundleID\":\"" + id + "\"}\n{\"sample\":true}")
        }
        try file(library + "/Caches/Google/shared.bin")
        let inventory = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: ApplicationSession.measure)
        for (name, id, executable) in samples {
            let record = inventory.apps.first { $0.bundleID == id }!
            let plan = UninstallPlanner.preview(app: record, catalog: inventory.apps, home: home.path, sizeOf: ApplicationSession.measure)
            let named = plan.parts.first { $0.entry.path == library + "/Caches/" + name }
            expect(named != nil, "missing exact name cache: " + name)
            expect(named!.entry.selectable && !named!.entry.defaultChecked, "name cache must require explicit review: " + name)
            if executable != "Electron" {
                expect(plan.parts.contains { $0.entry.path == library + "/Application Support/CrashReporter/" + executable + "_7BF74FC8-74C9-5B85-98A6-82BC65226812.plist" && !$0.entry.defaultChecked }, "missing executable crash marker: " + name)
            } else {
                expect(!plan.parts.contains { $0.entry.path?.contains("CrashReporter/Electron_") == true }, "generic Electron marker must not be assigned to one app")
            }
            expect(plan.parts.contains { $0.entry.path == library + "/Logs/DiagnosticReports/" + executable + "_2026-10-05-120000.ips" && !$0.entry.defaultChecked }, "missing bundle ID diagnostic: " + name)
            expect(!plan.parts.contains { $0.entry.path == library + "/Caches/" + name + " Beta" || $0.entry.path == library + "/Caches/Google" }, "prefix/vendor folder must remain untouched")
        }
        // Conflicting diagnostic metadata overrides a plausible file name.
        try file(library + "/Logs/DiagnosticReports/sublime_text_2026-10-05-120001.ips", "{\"bundleID\":\"com.other.editor\"}")
        let sublime = inventory.apps.first { $0.bundleID == "com.sublimetext.4" }!
        var plan = UninstallPlanner.preview(app: sublime, catalog: inventory.apps, home: home.path, sizeOf: ApplicationSession.measure)
        expect(!plan.parts.contains { $0.entry.path?.hasSuffix("120001.ips") == true }, "conflicting diagnostic ID must not match by name")
        try file(library + "/Logs/DiagnosticReports/keep.txt", "{\"bundleID\":\"com.sublimetext.4\"}")
        let unreadableReport = library + "/Logs/DiagnosticReports/sublime_text_2026-10-05-120002.ips"
        try file(unreadableReport, "{\"bundleID\":\"com.other.editor\"}")
        expect(chmod(unreadableReport, 0) == 0, "sample report chmod must succeed")
        defer { _ = chmod(unreadableReport, 0o600) }
        plan = UninstallPlanner.preview(app: sublime, catalog: inventory.apps, home: home.path, sizeOf: ApplicationSession.measure)
        expect(!plan.parts.contains { $0.entry.path?.hasSuffix("keep.txt") == true }, "non-diagnostic extensions must never be included by identifier alone")
        expect(!plan.parts.contains { $0.entry.path == unreadableReport && $0.entry.selectable }, "unreadable diagnostic must never gain filename execution authority")
        _ = chmod(unreadableReport, 0o600)
        // Same display name, different ID: both could own a name cache/marker.
        let other = try app("Other", "com.other.editor", "sublime_text")
        let info = ["CFBundleIdentifier":"com.other.editor", "CFBundleName":"Sublime Text", "CFBundleExecutable":"sublime_text", "CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: other + "/Contents/Info.plist"))
        let conflicting = ApplicationCatalog.discover(roots: [install.path], runningPaths: [], sizeOf: ApplicationSession.measure)
        plan = UninstallPlanner.preview(app: sublime, catalog: conflicting.apps, home: home.path, sizeOf: ApplicationSession.measure)
        expect(plan.parts.contains { $0.entry.path == library + "/Caches/Sublime Text" && !$0.entry.selectable }, "shared name cache must be review only")
        expect(plan.parts.contains { $0.entry.path?.contains("CrashReporter/sublime_text_") == true && !$0.entry.selectable }, "shared executable crash marker must be review only")
        // Neither links nor category ancestors become new execution authority.
        try fm.removeItem(atPath: library + "/Caches/Sublime Text")
        try fm.createSymbolicLink(atPath: library + "/Caches/Sublime Text", withDestinationPath: root.path)
        plan = UninstallPlanner.preview(app: sublime, catalog: inventory.apps, home: home.path, sizeOf: ApplicationSession.measure)
        expect(!plan.parts.contains { $0.entry.path == library + "/Caches/Sublime Text" && $0.entry.selectable }, "symlink cache must not be selectable")
        print("ApplicationAssociationTests passed: 12 generated app formats, ownership conflicts and links")
    }
}
