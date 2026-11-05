// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

private final class SandboxProcesses: CommandRunning {
    var output = ""
    var status: Int32 = 0
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        precondition(executable == "/bin/ps" && arguments == ["-axo", "comm="])
        return CommandResult(status: status, stdout: output, stderr: "", timedOut: false)
    }
}

@main struct SandboxCacheProbeTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporary.hasPrefix("/var/") ? "/private" + temporary : temporary)
            .appendingPathComponent("roomy-sandbox-cache-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let home = root.path + "/Home", installs = root.path + "/Applications", library = home + "/Library"
        func file(_ path: String) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("private sample".utf8).write(to: URL(fileURLWithPath: path))
        }
        let ids = ["com.tencent.xinWeChat", "net.whatsapp.WhatsApp", "com.microsoft.teams2"]
        for (i, id) in ids.enumerated() {
            let path = installs + "/Sample\(i).app/Contents/Info.plist"
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": "Sample\(i)", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        }
        let roots = ids.map { library + "/Containers/" + $0 + "/Data/Library" }
        let group = library + "/Group Containers/UBF8T346G9.com.microsoft.teams/Library"
        var wanted: [String] = [], kept: [String] = []
        for (i, base) in roots.enumerated() {
            let urlCache = base + "/Caches/" + ids[i]
            for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData/sample"] { try file(urlCache + "/" + name) }
            wanted += [urlCache, base + "/Caches/WebKit/NetworkCache"]
            try file(base + "/Caches/WebKit/NetworkCache/Version 17/Records/sample")
            kept += [base + "/Application Support/ChatStorage.sqlite", base + "/Preferences/account.plist", base + "/Cookies/Cookies.binarycookies",
                     base + "/Caches/Media/offline.jpg", base + "/Caches/UnknownCache/sample", base + "/Caches/WebKit/ServiceWorkers/sample",
                     base + "/WebKit/WebsiteData/Default/IndexedDB/sample", base + "/WebKit/WebsiteData/Default/LocalStorage/sample",
                     (base as NSString).deletingLastPathComponent + "/Documents/Attachments/sample"]
        }
        for base in [roots[2], group] {
            let webview = base + "/Application Support/Microsoft/MSTeams/EBWebView"
            for profile in ["Default", "WV2Profile_tfw", "Profile 1"] {
                for leaf in ["Cache", "Code Cache", "GPUCache"] {
                    let path = webview + "/" + profile + "/" + leaf
                    wanted.append(path); try file(path + "/sample")
                }
                for leaf in ["IndexedDB", "Local Storage", "Service Worker", "Session Storage", "blob_storage"] { kept.append(webview + "/" + profile + "/" + leaf + "/sample") }
                kept.append(webview + "/" + profile + "/Cookies")
            }
            kept.append(webview + "/UnrecognizedProfile/Cache/sample")
        }
        kept += [library + "/Group Containers/UBF8T346G9.Office/Library/Caches/sample",
                 library + "/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/sample",
                 library + "/Containers/com.microsoft.teams/Data/Library/Caches/WebKit/NetworkCache/sample"]
        for path in kept { try file(path) }
        let runner = SandboxProcesses(), tools = ToolLocator(isExecutable: { $0 == "/bin/ps" })
        func preview() -> [CleanupCandidate] { ApplicationCacheProbe.probe(home: home, catalogRoots: [installs], runner: runner, tools: tools) }
        let initial = preview()
        precondition(Set(initial.filter { $0.entry.selectable }.compactMap(\.targetPath)) == Set(wanted), "sandbox scan must authorize only exact network/WebView cache leaves")
        precondition(initial.filter { $0.entry.selectable }.allSatisfy { $0.entry.tier == .obsolete && $0.entry.defaultChecked && $0.entry.reversible }, "unblocked sandbox caches are A (default-checked) and reversible")
        precondition(!initial.contains { $0.entry.evidence.contains("未进入本次自动扫描") }, "supported sandbox caches must replace deferred-only notices")
        let list = CleanupListBuilder.build(items: [], probes: initial)
        precondition(list.entries.filter { $0.selectable }.allSatisfy { $0.category == "leftover" && !$0.group.isEmpty })
        var env = CleanupEnvironment(); env.roots = [home]; env.applicationRoots = [installs]; env.runner = runner; env.tools = tools; env.diskFree = { 0 }
        let trash = root.path + "/PrivateTrash"
        try fm.createDirectory(atPath: trash, withIntermediateDirectories: true)
        env.trash = { path in
            let destination = trash + "/" + UUID().uuidString
            try fm.moveItem(atPath: path, toPath: destination); return destination
        }
        let wechat = list.candidates.first { $0.targetPath == wanted[0] }!
        func execute(_ candidate: CleanupCandidate) -> CleanupOutcome {
            CleanupRunner.run(ids: [candidate.entry.id], list: list, env: env, progress: { _ in }).outcomes[0]
        }
        // Unknown data added after preview must prevent moving the entire URL cache family.
        let unknown = wanted[0] + "/Messages.sqlite"
        try file(unknown)
        precondition(!preview().contains { $0.targetPath == wanted[0] && $0.entry.selectable }, "mixed URL cache contents must be retained")
        precondition(!execute(wechat).ok && fm.fileExists(atPath: unknown), "late mixed contents must be rechecked")
        try fm.removeItem(atPath: unknown)
        let unreadable = roots[1] + "/Caches"
        precondition(chmod(unreadable, 0) == 0)
        defer { _ = chmod(unreadable, 0o755) }
        let denied = preview()
        precondition(!denied.contains { $0.entry.selectable && $0.targetPath?.hasPrefix(roots[1] + "/Caches/") == true })
        precondition(denied.contains { $0.entry.group == "Sample1" && $0.action == nil && $0.entry.evidence.contains("权限") }, "denied sandbox must have actionable permission notice")
        let whatsapp = list.candidates.first { $0.targetPath == wanted[2] }!
        precondition(!execute(whatsapp).ok, "late permission denial must preserve cache")
        precondition(chmod(unreadable, 0o755) == 0)
        let team = list.candidates.first { $0.targetPath == roots[2] + "/Application Support/Microsoft/MSTeams/EBWebView/Default/Cache" }!
        runner.output = "/Library/Application Support/Microsoft/WebView2/Microsoft Teams WebView.app/Contents/MacOS/Microsoft Teams WebView\n"
        precondition(!execute(team).ok && !preview().contains { $0.entry.group == "Sample2" && $0.entry.selectable }, "external Teams WebView helper must block all Teams cache mutation")
        runner.output = ""; runner.status = 1
        precondition(!preview().contains { $0.entry.selectable }, "process inspection failure must lock sandbox caches")
        runner.status = 0
        // Fresh preview captures directory metadata after the deliberately introduced/removal changes.
        let fresh = CleanupListBuilder.build(items: [], probes: preview())
        let selectedPaths = [wanted[0], wanted[2], team.targetPath!]
        let selected = fresh.candidates.filter { selectedPaths.contains($0.targetPath ?? "") }
        let result = CleanupRunner.run(ids: selected.map { $0.entry.id }, list: fresh, env: env, progress: { _ in })
        precondition(result.outcomes.count == 3 && result.outcomes.allSatisfy(\.ok), "all three generated app cache families must move through real runner")
        for path in kept { precondition(fm.fileExists(atPath: path), "user and shared data must survive: " + path) }
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let ledger = TrashLedger(url: ledgerURL, trashRoots: [trash])
        ledger.record(result.outcomes.map { outcome in
            let path = selected.first { $0.entry.id == outcome.id }!.targetPath!
            return TrashedItem(path: outcome.trashedTo!, bytes: outcome.bytes, title: "Generated sandbox cache", originalPath: path)
        })
        let reloaded = TrashLedger(url: ledgerURL, trashRoots: [trash])
        for record in reloaded.pending() { _ = try reloaded.restore(id: record.recoveryID) }
        for path in [wanted[0] + "/Cache.db", wanted[2] + "/Cache.db-wal", team.targetPath! + "/sample"] {
            let restored = try Data(contentsOf: URL(fileURLWithPath: path))
            precondition(restored == Data("private sample".utf8), "restored sandbox cache bytes must match")
        }
        let nested = roots[1] + "/Caches/WebKit/NetworkCache/Version 17/Records"
        let network = CleanupListBuilder.build(items: [], probes: preview())
        let networkCandidate = network.candidates.first { $0.targetPath == roots[1] + "/Caches/WebKit/NetworkCache" }!
        precondition(chmod(nested, 0) == 0)
        defer { _ = chmod(nested, 0o755) }
        precondition(!preview().contains { $0.targetPath == networkCandidate.targetPath && $0.entry.selectable }, "partial sandbox cache readability must not authorize cleanup")
        let blocked = CleanupRunner.run(ids: [networkCandidate.entry.id], list: network, env: env, progress: { _ in })
        precondition(blocked.outcomes.first?.ok == false, "late unreadable cache descendant must block processing")
        precondition(chmod(nested, 0o755) == 0)
        let db = wanted[0] + "/Cache.db", heldDB = root.path + "/HeldDB"
        try fm.moveItem(atPath: db, toPath: heldDB); try fm.createSymbolicLink(atPath: db, withDestinationPath: heldDB)
        precondition(!preview().contains { $0.targetPath == wanted[0] && $0.entry.selectable }, "linked cache database must reject the family")
        let cacheRoot = roots[0] + "/Caches", held = root.path + "/HeldCaches"
        try fm.moveItem(atPath: cacheRoot, toPath: held); try fm.createSymbolicLink(atPath: cacheRoot, withDestinationPath: held)
        precondition(!preview().contains { $0.entry.selectable && $0.targetPath?.hasPrefix(cacheRoot + "/") == true }, "linked sandbox parent must never authorize caches")
        print("SandboxCacheProbeTests passed: three-app bounded coverage, data retention, late guards, private Trash and reload/restore")
    }
}
