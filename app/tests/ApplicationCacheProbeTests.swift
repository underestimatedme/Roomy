// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

private final class CacheProcesses: CommandRunning {
    var result = CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        precondition(executable == "/bin/ps" && arguments == ["-axo", "comm="], "cache inspection must use the process-list command")
        return result
    }
}

@main struct ApplicationCacheProbeTests {
    static func main() throws {
        let fm = FileManager.default, temporary = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporary.hasPrefix("/var/") ? "/private" + temporary : temporary)
            .appendingPathComponent("roomy-app-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("Home"), installs = root.appendingPathComponent("Applications")
        func file(_ path: String, _ bytes: Data = Data("fixture bytes".utf8)) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try bytes.write(to: URL(fileURLWithPath: path))
        }
        func app(_ name: String, _ id: String, helper: Bool = false) throws -> String {
            let path = installs.path + "/" + name + ".app"
            var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL"]
            if helper { info["SMPrivilegedExecutables"] = ["com.sample.helper": "sample"] }
            try file(path + "/Contents/Info.plist", PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
            return path
        }
        let chrome = try app("Google Chrome", "com.google.Chrome", helper: true)
        _ = try app("Firefox", "org.mozilla.firefox", helper: true)
        _ = try app("Microsoft Edge", "com.microsoft.edgemac", helper: true)
        _ = try app("Brave Browser", "com.brave.Browser", helper: true)
        for (name, id) in [("Notion", "notion.id"), ("Slack", "com.tinyspeck.slackmacgap"),
                           ("Discord", "com.hnc.Discord"), ("Obsidian", "md.obsidian"),
                           ("WeChat", "com.tencent.xinWeChat"), ("WhatsApp", "net.whatsapp.WhatsApp"), ("Teams", "com.microsoft.teams2")] {
            _ = try app(name, id)
        }
        let library = home.path + "/Library"
        let wanted = ["Caches/Google/Chrome/Default/Cache", "Caches/Google/Chrome/Default/Code Cache",
                      "Caches/Google/Chrome/Profile 1/Cache", "Caches/Microsoft Edge/Default/Cache",
                      "Caches/com.microsoft.edgemac/Profile 1/Code Cache", "Caches/BraveSoftware/Brave-Browser/Default/Cache",
                      "Caches/Firefox/Profiles/abcd1234.default-release/cache2",
                      "Caches/Firefox/Profiles/abcd1234.default-release/startupCache", "Caches/Firefox/Profiles/abcd1234.default-release/thumbnails"] +
            ["Notion", "Slack", "discord", "obsidian"].flatMap { name in ["Cache", "Code Cache", "GPUCache"].map { "Application Support/" + name + "/" + $0 } }
        let keep = ["Caches/Google/Chrome/Default/Storage", "Caches/Google/Chrome/Other Product/Cache",
                    "Caches/Google/Chrome/Profile 1/Local Storage", "Caches/Firefox/Profiles/abcd1234.default-release/settings",
                    "Application Support/Google/Chrome/Default/Cookies", "Application Support/Firefox/Profiles/abcd1234.default-release/cookies.sqlite"] +
            ["Notion", "Slack", "discord", "obsidian"].flatMap { name in ["Cookies", "Local Storage", "IndexedDB", "Service Worker", "Session Storage", "blob_storage"].map { "Application Support/" + name + "/" + $0 } }
        for relative in wanted + keep { try file(library + "/" + relative + "/sample.bin") }
        let unreadableChild = library + "/Caches/Google/Chrome/Default/Cache/Cache_Data/permission-test"
        try file(unreadableChild + "/sample.bin")
        let runner = CacheProcesses(), tools = ToolLocator(isExecutable: { $0 == "/bin/ps" })
        func preview() -> [CleanupCandidate] {
            ApplicationCacheProbe.probe(home: home.path, catalogRoots: [installs.path], runner: runner, tools: tools, sizeOf: ApplicationSession.measure)
        }
        let initial = preview(), executable = initial.filter { $0.entry.selectable }
        precondition(Set(executable.compactMap(\.targetPath)) == Set(wanted.map { library + "/" + $0 }), "only reviewed cache leaves may be executable")
        precondition(executable.allSatisfy { $0.entry.tier == .obsolete && $0.entry.defaultChecked && $0.entry.reversible }, "unblocked app caches are A (default-checked) and recoverable")
        precondition(initial.contains { $0.entry.title.contains("WeChat") && $0.action == nil }, "an absent supported sandbox cache must remain an explicit notice")
        let list = CleanupListBuilder.build(items: [], probes: initial)
        precondition(list.candidates.filter { $0.entry.selectable }.allSatisfy { $0.entry.category == "leftover" && !$0.entry.group.isEmpty }, "GUI/CLI list must retain app grouping")
        let cachePath = library + "/Caches/Google/Chrome/Default/Cache"
        let selected = list.candidates.first { $0.targetPath == cachePath }!
        var env = CleanupEnvironment(); env.roots = [home.path]; env.applicationRoots = [installs.path]
        env.runner = runner; env.tools = tools; env.diskFree = { 0 }
        let trash = root.appendingPathComponent("PrivateTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        env.trash = { path in
            let destination = trash.appendingPathComponent(UUID().uuidString)
            try fm.moveItem(atPath: path, toPath: destination.path); return destination.path
        }
        func execute() -> CleanupRunSummary { CleanupRunner.run(ids: [selected.entry.id], list: list, env: env, progress: { _ in }) }
        runner.result = CommandResult(status: 0, stdout: chrome + "/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper\n", stderr: "", timedOut: false)
        precondition(!preview().contains { $0.targetPath == cachePath && $0.entry.selectable }, "running helper must protect browser caches at discovery")
        precondition(preview().contains { $0.entry.path == cachePath && $0.entry.tier == .locked && $0.action == nil
            && $0.entry.lockReason == ApplicationCatalog.runningBlockReason }, "a running owner puts its caches in 不能删 for this scan")
        precondition(execute().outcomes.first?.ok == false && fm.fileExists(atPath: cachePath), "a late-starting helper must prevent cache mutation")
        runner.result = CommandResult(status: 1, stdout: "", stderr: "denied", timedOut: false)
        precondition(!preview().contains { $0.entry.selectable }, "process inspection failure must not authorize app caches")
        let unverified = preview().filter { $0.entry.path != nil && $0.entry.size > 0 }
        precondition(!unverified.isEmpty && unverified.allSatisfy { $0.entry.tier == .review }, "non-running blockers stay in C")
        let discovered = ApplicationCacheProbe.probe(home: home.path, catalogRoots: [installs.path], runner: runner, tools: tools,
            sizeOf: { _ in ToolProbes.placeholder })
        let discoveredPaths = Set(discovered.compactMap(\.targetPath))
        var sizeIndex = SizeIndex()
        sizeIndex.targets = Dictionary(uniqueKeysWithValues: discoveredPaths.map { ($0, UInt64(4096)) })
        let measured = ToolProbes.sized(discovered, sizePaths: discoveredPaths, index: sizeIndex)
        precondition(!measured.contains { $0.entry.size == ToolProbes.placeholder } && !measured.contains { $0.entry.selectable }, "locked caches must still replace discovery placeholders with measured sizes")
        sizeIndex.targets.removeValue(forKey: cachePath)
        let missingSize = ToolProbes.sized(discovered, sizePaths: discoveredPaths, index: sizeIndex)
        precondition(missingSize.contains { $0.entry.path == cachePath && $0.entry.size == 0 && $0.action == nil && !$0.entry.selectable }, "unmeasured cache must remain an explicit notice")
        precondition(execute().outcomes.first?.ok == false && fm.fileExists(atPath: cachePath), "late process failure must preserve cache bytes")
        runner.result = CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
        let pendingMeasure = ApplicationCacheProbe.probe(home: home.path, catalogRoots: [installs.path], runner: runner, tools: tools,
            sizeOf: { _ in ToolProbes.placeholder })
        precondition(chmod(unreadableChild, 0) == 0, "private sample permission change must succeed")
        defer { _ = chmod(unreadableChild, 0o755) }
        precondition(!preview().contains { $0.targetPath == cachePath && $0.entry.selectable }, "partially unreadable cache must not be authorized")
        sizeIndex.targets[cachePath] = 4096 // Bulk sizing can return a partial total despite an unreadable descendant.
        let partial = ToolProbes.sized(pendingMeasure, sizePaths: Set(pendingMeasure.compactMap(\.targetPath)), index: sizeIndex)
        precondition(partial.contains { $0.entry.path == cachePath && $0.action == nil && !$0.entry.selectable }, "partial cache measurement must stay an explicit notice, never a complete actionable size")
        precondition(execute().outcomes.first?.ok == false && fm.fileExists(atPath: cachePath), "late unreadable descendant must prevent cache mutation")
        precondition(chmod(unreadableChild, 0o755) == 0, "sample permissions must restore before normal execution")
        let copy = try app("Chrome Copy", "com.google.Chrome")
        precondition(execute().outcomes.first?.ok == false && fm.fileExists(atPath: cachePath), "new shared app copy must invalidate a cache selection")
        try fm.removeItem(atPath: copy)
        let result = execute()
        precondition(result.outcomes.count == 1 && result.outcomes[0].ok && !fm.fileExists(atPath: cachePath), "closed browser cache must move via the real runner")
        for relative in keep { precondition(fm.fileExists(atPath: library + "/" + relative + "/sample.bin"), "user storage must remain: " + relative) }
        precondition(fm.fileExists(atPath: chrome), "cache processing must leave privileged-helper app installed")
        let ledgerURL = root.appendingPathComponent("ledger.json"), ledger = TrashLedger(url: ledgerURL, trashRoots: [trash.path])
        ledger.record(result.outcomes.map { TrashedItem(path: $0.trashedTo!, bytes: $0.bytes, title: "Browser cache", originalPath: cachePath) })
        let reloaded = TrashLedger(url: ledgerURL, trashRoots: [trash.path])
        for record in reloaded.pending() { _ = try reloaded.restore(id: record.recoveryID) }
        let restored = try Data(contentsOf: URL(fileURLWithPath: cachePath + "/sample.bin"))
        precondition(restored == Data("fixture bytes".utf8), "restoration must preserve cache bytes after ledger reload")
        let notionRoot = library + "/Application Support/Notion", held = root.appendingPathComponent("HeldNotion").path
        try fm.moveItem(atPath: notionRoot, toPath: held)
        try fm.createSymbolicLink(atPath: notionRoot, withDestinationPath: held)
        precondition(!preview().contains { $0.entry.selectable && $0.targetPath?.hasPrefix(notionRoot + "/") == true }, "linked app storage must not be scanned as executable caches")
        let profiles = library + "/Caches/Firefox/Profiles", heldProfiles = root.appendingPathComponent("HeldProfiles").path
        try fm.moveItem(atPath: profiles, toPath: heldProfiles)
        try fm.createSymbolicLink(atPath: profiles, withDestinationPath: heldProfiles)
        precondition(!preview().contains { $0.entry.selectable && $0.targetPath?.hasPrefix(profiles + "/") == true }, "linked browser profile ancestor must be refused")
        print("ApplicationCacheProbeTests passed: browser/chat cache leaves, helper/permission/shared-owner guards, private Trash and reload/restore")
    }
}
