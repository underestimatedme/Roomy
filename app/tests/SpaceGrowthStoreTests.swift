// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

@main struct SpaceGrowthStoreTests {
    static func main() throws {
        let fm = FileManager.default
        let temporaryPath = fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath).appendingPathComponent("roomy-growth-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let location = root.appendingPathComponent("history")
        let store = SpaceGrowthStore(directory: location)
        expect(try store.latestReports().isEmpty, "missing history is an empty read")
        expect(!fm.fileExists(atPath: location.path), "reading absent history must not create files")
        func index(_ items: [(String, UInt64)], path: String = "/fixture", device: UInt64 = 1) -> ScanIndex {
            var value = ScanIndex(rootPath: path)
            value.append(parentID: 0, fileID: 100, deviceID: device, name: "fixture", kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 0, flags: [])
            for (name, bytes) in items {
                value.append(parentID: 0, fileID: UInt64(value.entries.count), deviceID: device, name: name, kind: .file, logicalSize: bytes * 2, allocatedSize: bytes, modifiedAt: 0, flags: [])
            }
            value.finalizeAggregates(); return value
        }
        // 时间以"天"为单位；基线就是最近一份快照（基线/间隔几秒的用例见文件末尾）
        let day: TimeInterval = 86_400
        func at(_ days: TimeInterval) -> Date { Date(timeIntervalSince1970: days * day) }
        var time: TimeInterval = 1_000
        func record(_ value: ScanIndex, diagnostics: [ScanDiagnostic] = [], completed: Bool = true, coverage: String = "full-tree-v1") throws -> SpaceGrowthReport {
            time += 1
            return try store.record(index: value, diagnostics: diagnostics, completed: completed, coverageID: coverage, capturedAt: at(time))
        }
        try fm.createDirectory(at: location, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("interrupted write".utf8).write(to: location.appendingPathComponent(".history.tmp"))
        let first = try record(index([("old", 100), ("same", 200)]))
        expect(first.status == "baseline" && first.deltaBytes == nil && !first.shouldRemind, "first scan must establish baseline")
        // 首次记录也要能看出空间去了哪：rows 是当前最大的直接子项，带真实字节，delta 为 0（是现状，不是变化）
        expect(first.rows.map(\.path) == ["/fixture/same", "/fixture/old"], "a first record lists its largest children: \(first.rows.map(\.path))")
        expect(first.rows.map(\.currentAllocatedBytes) == [200, 100], "a first record carries the real child bytes")
        expect(first.rows.allSatisfy { $0.kind == "current" && $0.deltaBytes == 0 && $0.previousAllocatedBytes == nil },
               "a first record's rows are current sizes, never a change")
        expect(!fm.fileExists(atPath: location.appendingPathComponent(".history.tmp").path), "interrupted writes are replaced without accumulating files")
        let restarted = SpaceGrowthStore(directory: location)
        let second = try restarted.record(index: index([("same", 250), ("new", 70)]), diagnostics: [], capturedAt: at(1_002))
        expect(second.status == "compared" && second.previousAllocatedBytes == 300 && second.currentAllocatedBytes == 320 && second.deltaBytes == 20, "restart must retain allocated totals")
        expect(second.rows.first { $0.path == "/fixture/old" }?.kind == "removed", "complete observations detect removed paths")
        expect(second.rows.first { $0.path == "/fixture/old" }?.currentAllocatedBytes == nil, "removed path has no current observation")
        expect(second.rows.first { $0.path == "/fixture/new" }?.kind == "added", "new path must be marked added")
        expect(second.rows.first { $0.path == "/fixture/same" }?.deltaBytes == 50, "exact path comparison")
        let savedReports = try SpaceGrowthStore(directory: location).latestReports()
        expect(savedReports.count == 1 && savedReports[0].deltaBytes == 20 && savedReports[0].rows.count == 3, "restart report must retain comparison without a new scan")
        let chart = try restarted.dashboard()
        expect(chart.reports.count == 1 && chart.diskHistory.isEmpty && chart.diskCurrent == nil, "old histories decode without disk samples")
        let rootTrend = chart.trends.first { $0.path == "/fixture" }!
        expect(rootTrend.points.map(\.bytes) == [300, 320], "root chart uses exact historic totals")
        expect(rootTrend.points.map(\.capturedAt) == [at(1_001), at(1_002)], "chart dates preserve real intervals")
        expect(chart.trends.first { $0.path == "/fixture/new" }!.points.map(\.bytes) == [0, 70], "new child has a confirmed absent first sample")
        expect(chart.trends.first { $0.path == "/fixture/old" }!.points.map(\.bytes) == [100, 0], "removed child keeps its history")
        let disk1 = SpaceDiskObservation(volumeID: "volume-a", capturedAt: at(1_001), total: 1000, free: 400, captureID: "disk-1")
        let disk2 = SpaceDiskObservation(volumeID: "volume-a", capturedAt: at(1_002), total: 1000, free: 300, captureID: "disk-2")
        try restarted.recordDisk(disk1); try restarted.recordDisk(disk2); try restarted.recordDisk(disk2)
        let diskChart = try restarted.dashboard(currentDisk: disk2)
        expect(diskChart.diskHistory.map(\.used) == [600, 700], "disk samples persist and duplicate delivery is idempotent")
        expect(diskChart.reports.count == 1, "volume writes preserve directory observations")
        let otherDisk = SpaceDiskObservation(volumeID: "volume-b", capturedAt: at(1_003), total: 2000, free: 1000, captureID: nil)
        expect(try restarted.dashboard(currentDisk: otherDisk).diskHistory.isEmpty, "different volumes are never joined into one chart")
        let invalidDisk = SpaceDiskObservation(volumeID: "volume-a", capturedAt: at(1_003), total: 100, free: 101, captureID: nil)
        do { try restarted.recordDisk(invalidDisk); preconditionFailure("invalid disk sample accepted") } catch SpaceGrowthStore.StoreError.corrupt {}
        expect(try restarted.dashboard().diskHistory.count == 2, "invalid sample leaves history intact")
        let stale = try restarted.record(index: index([]), diagnostics: [], capturedAt: at(1_001))
        expect(stale.status == "incomparable", "stale observation cannot replace latest scan")
        time = 1_002
        let partial = try record(index([("same", 5)]), completed: false)
        expect(partial.status == "incomparable" && partial.rows.isEmpty && partial.deltaBytes == nil, "partial page cannot imply deletions")
        let denied = try record(index([]), diagnostics: [ScanDiagnostic(path: "/fixture/private", kind: .permissionDenied, errorNumber: EACCES)])
        expect(denied.status == "incomparable" && !denied.shouldRemind, "permission gaps cannot imply shrinkage")
        let afterGap = try record(index([("same", 250), ("new", 70)]))
        expect(afterGap.deltaBytes == 0 && afterGap.previousCapturedAt == at(1_002), "incomplete scans must not replace successful baseline")
        let shrink = try record(index([("same", 1)]))
        expect(shrink.deltaBytes == -319 && !shrink.shouldRemind, "negative growth is signed")
        let growth = try record(index([("same", 1_073_741_825)]))
        expect(growth.deltaBytes == 1_073_741_824 && growth.shouldRemind, "threshold includes exactly one GiB")
        // 清理遍历的目录统计：同一根两次记录，差值等于两次总量之差；与完整树扫描的历史互不比较
        let walkRoot = root.appendingPathComponent("walk-root")
        try fm.createDirectory(at: walkRoot, withIntermediateDirectories: false)
        let walkPath = walkRoot.path
        func walk(_ total: UInt64, _ children: [(path: String, bytes: UInt64)], at date: TimeInterval, path: String = walkPath) throws -> SpaceGrowthReport {
            try store.record(root: path, total: total, children: children, capturedAt: at(date))
        }
        let treeFirst = try store.record(index: index([("old", 1)], path: walkPath), diagnostics: [], capturedAt: at(5_000))
        expect(treeFirst.status == "baseline", "tree scan baseline for the walk root path")
        let w1 = try walk(300, [(walkPath + "/a", 200), (walkPath + "/b", 50)], at: 5_001)
        expect(w1.status == "incomparable" && w1.deltaBytes == nil, "walk history is not compared with full-tree history: \(w1.status)")
        let w2 = try walk(500, [(walkPath + "/a", 400), (walkPath + "/c", 60)], at: 5_002)
        expect(w2.status == "compared" && w2.deltaBytes == 200 && w2.previousAllocatedBytes == 300 && w2.currentAllocatedBytes == 500, "delta equals the totals difference")
        expect(w2.rows.first { $0.path == walkPath + "/a" }?.deltaBytes == 200 && w2.rows.first { $0.path == walkPath + "/b" }?.kind == "removed"
               && w2.rows.first { $0.path == walkPath + "/c" }?.kind == "added", "walk rows compare exact children")
        let policyChart = try store.dashboard().trends.first { $0.path == walkPath && $0.rootPath == walkPath }!
        expect(policyChart.points.count == 2 && policyChart.points.map(\.bytes) == [300, 500], "charts do not join incompatible coverage policies")
        let latest = try store.latestReports().filter { $0.rootPath == walkPath }
        expect(latest.count == 2 && Set(latest.map(\.snapshotCount)) == [1, 2], "walk and full-tree scopes are kept apart")
        let w3 = try walk(100, [(walkPath + "/a", 100)], at: 5_003)
        expect(w3.deltaBytes == -400 && !w3.shouldRemind, "negative walk delta is signed")
        expect(try walk(100, [], at: 5_003).status == "incomparable", "non-increasing time does not overwrite walk history")
        expect(try walk(100, [(walkPath + "/a", 80), (walkPath + "/a", 10)], at: 5_004).status == "incomparable", "duplicate children rejected")
        expect(try walk(100, [(walkPath + "/a", 200)], at: 5_005).status == "incomparable", "children larger than the total rejected")
        expect(try walk(100, [(walkPath + "/../x", 1)], at: 5_006).status == "incomparable", "children must be direct and well-formed")
        expect(try walk(100, [(walkPath + "/a/deeper", 1)], at: 5_007).status == "incomparable", "only direct children are accepted")
        expect(try walk(10, [], at: 5_008, path: root.appendingPathComponent("does-not-exist").path).status == "incomparable", "missing roots cannot be identified, so they are not recorded")
        expect(try walk(10, [], at: 5_009, path: "relative").status == "incomparable", "relative roots rejected")
        expect(try walk(100, [], at: 5_010).deltaBytes == 0, "rejected inputs leave the walk history intact")
        // cleanup 事件只来自真实清理后的重新测量：先量一次，删掉大文件再量一次，两次都是真实遍历
        let cleanupRoot = root.appendingPathComponent("cleanup-root")
        try fm.createDirectory(at: cleanupRoot.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cleanupRoot.appendingPathComponent("drop"), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 8_000).write(to: cleanupRoot.appendingPathComponent("keep/keep.bin"))
        try Data(repeating: 0x42, count: 16_000).write(to: cleanupRoot.appendingPathComponent("drop/drop.bin"))
        func measuredCleanupSnapshot(at date: TimeInterval, event: SpaceGrowthEvent) throws -> SpaceGrowthReport {
            let measured = BulkWalker().measure(roots: [cleanupRoot.path], targets: [], dirDepth: 1, dirThreshold: 0,
                                                skip: [], includeAllRootChildren: true)
            guard let total = measured.roots[cleanupRoot.path] else { preconditionFailure("cleanup root must be measured") }
            let children = measured.dirs
                .filter { URL(fileURLWithPath: $0.key).deletingLastPathComponent().path == cleanupRoot.path }
                .map { (path: $0.key, bytes: $0.value) }
            return try store.record(root: cleanupRoot.path, total: total, children: children,
                                    capturedAt: at(date), event: event)
        }
        let beforeCleanup = try measuredCleanupSnapshot(at: 5_100, event: .scan)
        expect(beforeCleanup.status == "baseline", "the cleanup fixture starts with a scan baseline")
        try fm.removeItem(at: cleanupRoot.appendingPathComponent("drop/drop.bin"))
        let afterCleanup = try measuredCleanupSnapshot(at: 5_110, event: .cleanup)
        expect(afterCleanup.status == "compared" && afterCleanup.event == .cleanup
               && afterCleanup.previousEvent == .scan && (afterCleanup.deltaBytes ?? 0) < 0,
               "cleanup is recorded only after a real re-measure, with its typed event")
        expect((afterCleanup.rows.first { $0.path == cleanupRoot.path + "/drop" }?.deltaBytes ?? 0) < 0,
               "the re-measured first-level directory shows the real shrink")
        expect(try store.latestReports().first { $0.rootPath == cleanupRoot.path }?.event == .cleanup,
               "stored cleanup reports keep the typed event")
        // 根或任意后代读不到的根不记录：缺失部分不在根总量里，之后授权会显示成假的增长
        expect(SpaceGrowthStore.coverageComplete(root: "/h", unreadable: []), "no gaps is complete")
        expect(!SpaceGrowthStore.coverageComplete(root: "/h", unreadable: ["/h/.Trash"]), "unreadable direct child is a gap")
        expect(!SpaceGrowthStore.coverageComplete(root: "/h", unreadable: ["/h"]), "unreadable root is a gap")
        expect(!SpaceGrowthStore.coverageComplete(root: "/h", unreadable: ["/h/a/b"]), "a deep descendant gap rejects the root")
        expect(SpaceGrowthStore.coverageComplete(root: "/h", unreadable: ["/other/x", "/hh/x"]), "other roots and prefix siblings are not gaps")
        expect(!SpaceGrowthStore.coverageComplete(root: "/", unreadable: ["/anything"]), "any unreadable descendant rejects the volume root")
        // 系统区域（OS 更新常动几个 GB）照常记录和显示，但不提醒；家目录和代码根照常提醒
        let GiB: UInt64 = 1_073_741_824
        let userRoot = root.appendingPathComponent("remind-root").path
        try fm.createDirectory(atPath: userRoot, withIntermediateDirectories: false)
        _ = try walk(GiB, [], at: 6_001, path: userRoot); let userGrowth = try walk(4 * GiB, [], at: 6_002, path: userRoot)
        expect(userGrowth.deltaBytes == Int64(3 * GiB) && userGrowth.shouldRemind, "user roots keep the reminder")
        _ = try walk(GiB, [], at: 6_001, path: "/Library"); let systemGrowth = try walk(4 * GiB, [], at: 6_002, path: "/Library")
        expect(systemGrowth.status == "compared" && systemGrowth.deltaBytes == Int64(3 * GiB) && !systemGrowth.shouldRemind, "system roots are recorded without a reminder")
        expect(try store.latestReports().first { $0.rootPath == "/Library" }?.shouldRemind == false, "stored reads agree")
        let device = try record(index([("same", 5)], device: 2))
        expect(device.status == "incomparable" && device.deltaBytes == nil, "different device must not compare")
        let coverage = try record(index([("same", 5)], device: 2), coverage: "other-policy")
        expect(coverage.status == "incomparable", "different scope policy must not compare")
        let unsafeInput = try record(index([], path: "/fixture/../escape"))
        expect(unsafeInput.status == "incomparable", "dot path components cannot enter history")
        let otherRoot = try record(index([], path: "/other"))
        expect(otherRoot.status == "baseline", "different roots have separate history")
        var hardlinks = index([("one", 100), ("two", 100)], path: "/links")
        hardlinks.append(parentID: 0, fileID: 1, deviceID: 1, name: "hardlink", kind: .file, logicalSize: 200, allocatedSize: 100, modifiedAt: 0, flags: [])
        hardlinks.recomputeHardLinkAccounting()
        let hardlinkReport = try record(hardlinks)
        expect(hardlinkReport.currentAllocatedBytes == 200, "do not recharge hardlinks from logical or physical size")
        let wide = try record(index((0..<513).map { ("item\($0)", UInt64(1)) }))
        expect(wide.status == "incomparable" && wide.rows.isEmpty, "bound storage without mistaking truncated entries for deletions")
        for number in 0..<35 { _ = try record(index([("file", UInt64(number))], path: "/bounded")) }
        let bounded = try record(index([], path: "/bounded"))
        expect(bounded.snapshotCount == 30, "history retention must be bounded")
        for number in 0..<20 { _ = try record(index([], path: "/scope\(number)")) }
        let evicted = try record(index([], path: "/bounded"))
        expect(evicted.status == "baseline", "old scopes must be evicted")
        let permissions = try fm.attributesOfItem(atPath: location.appendingPathComponent("history.json").path)
        expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600, "personal history must be private")
        let unsafe = root.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: unsafe, withDestinationURL: location)
        do { _ = try SpaceGrowthStore(directory: unsafe).record(index: index([]), diagnostics: []); preconditionFailure("symlink store accepted") } catch {}
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: location.appendingPathComponent("history.json").path)
        do { _ = try store.latestReports(); preconditionFailure("public-readable history accepted") } catch {}
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.appendingPathComponent("history.json").path)
        let encoded = try Data(contentsOf: location.appendingPathComponent("history.json"))
        var malformedObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var scopes = malformedObject["scopes"] as! [[String: Any]]
        scopes.append(scopes[0]); malformedObject["scopes"] = scopes
        try JSONSerialization.data(withJSONObject: malformedObject).write(to: location.appendingPathComponent("history.json"))
        do { _ = try store.latestReports(); preconditionFailure("oversized/duplicate scopes accepted") } catch {}
        try Data("malformed".utf8).write(to: location.appendingPathComponent("history.json"))
        do { _ = try record(index([])); preconditionFailure("malformed store accepted") } catch {}
        expect(try String(contentsOf: location.appendingPathComponent("history.json"), encoding: .utf8) == "malformed", "corrupt history must not be silently overwritten")
        try fm.removeItem(at: location.appendingPathComponent("history.json"))
        try fm.createSymbolicLink(at: location.appendingPathComponent("history.json"), withDestinationURL: root.appendingPathComponent("outside"))
        do { _ = try record(index([])); preconditionFailure("symlink history accepted") } catch {}
        expect(!fm.fileExists(atPath: root.appendingPathComponent("outside").path), "symlink target must remain untouched")
        let privateDir = root.appendingPathComponent("denied")
        try fm.createDirectory(at: privateDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateDir.path) }
        do { _ = try SpaceGrowthStore(directory: privateDir).record(index: index([]), diagnostics: []); preconditionFailure("read-only store accepted") } catch {}
        // ---- 基线 = 最近一份完整快照；不再有 24 小时门槛或 1 小时合并 ----
        let baseStore = SpaceGrowthStore(directory: root.appendingPathComponent("baseline-history"))
        let baseRoot = root.appendingPathComponent("baseline-root").path
        try fm.createDirectory(atPath: baseRoot, withIntermediateDirectories: false)
        let t0: TimeInterval = 20_000 * day
        func snap(_ total: UInt64, _ seconds: TimeInterval, path: String = baseRoot,
                  event: SpaceGrowthEvent = .scan, captureID: String? = nil) throws -> SpaceGrowthReport {
            try baseStore.record(root: path, total: total, children: [],
                                 capturedAt: Date(timeIntervalSince1970: t0 + seconds),
                                 event: event, captureID: captureID)
        }
        _ = try snap(100, 0)
        let tenSeconds = try snap(150, 10)
        expect(tenSeconds.status == "compared" && tenSeconds.deltaBytes == 50
               && tenSeconds.previousCapturedAt == Date(timeIntervalSince1970: t0)
               && tenSeconds.event == .scan && tenSeconds.previousEvent == .scan,
               "two scans ten seconds apart still compare: \(String(describing: tenSeconds.previousCapturedAt))")
        expect(tenSeconds.snapshotCount == 2, "a distinct scan is retained even seconds after the previous one")
        let tenSecondsLater = try snap(170, 20)
        expect(tenSecondsLater.snapshotCount == 3 && tenSecondsLater.deltaBytes == 20
               && tenSecondsLater.previousCapturedAt == Date(timeIntervalSince1970: t0 + 10),
               "every distinct scan is appended, never coalesced")
        expect(try snap(180, 20).status == "incomparable", "non-increasing capture time is still rejected")
        // cleanup 只标记真实清理后重新测得的那次快照；这里用真实遍历得到的数值，不接受按删除量推算
        let cleanup = try snap(120, 30, event: .cleanup)
        expect(cleanup.status == "compared" && cleanup.event == .cleanup && cleanup.previousEvent == .scan
               && cleanup.deltaBytes == -50, "cleanup is a real re-measured snapshot with its own event")
        expect(try baseStore.latestReports().first { $0.rootPath == baseRoot }?.event == .cleanup,
               "stored reports keep the typed event")
        // 幂等：同一 root 同一 captureID 重复投递不追加、不改历史
        let captureTime = Date(timeIntervalSince1970: t0 + 40)
        _ = try baseStore.record(root: baseRoot, total: 130, children: [], capturedAt: captureTime,
                                 event: .cleanup, captureID: "cap-1")
        let beforeDuplicate = try baseStore.latestReports().first { $0.rootPath == baseRoot }!
        let duplicate = try baseStore.record(root: baseRoot, total: 999, children: [],
                                             capturedAt: captureTime.addingTimeInterval(5),
                                             event: .cleanup, captureID: "cap-1")
        let afterDuplicate = try baseStore.latestReports().first { $0.rootPath == baseRoot }!
        expect(duplicate.snapshotCount == beforeDuplicate.snapshotCount
               && afterDuplicate.snapshotCount == beforeDuplicate.snapshotCount
               && afterDuplicate.currentAllocatedBytes == beforeDuplicate.currentAllocatedBytes
               && afterDuplicate.capturedAt == beforeDuplicate.capturedAt,
               "a repeated captureID must be idempotent, not a new snapshot")
        let newCapture = try baseStore.record(root: baseRoot, total: 140, children: [],
                                              capturedAt: captureTime.addingTimeInterval(10),
                                              event: .cleanup, captureID: "cap-2")
        expect(newCapture.snapshotCount == beforeDuplicate.snapshotCount + 1 && newCapture.deltaBytes == 10,
               "a new captureID appends a new snapshot")
        // 跨重启仍幂等
        let restartedBase = SpaceGrowthStore(directory: root.appendingPathComponent("baseline-history"))
        let afterRestart = try restartedBase.record(root: baseRoot, total: 500, children: [],
                                                    capturedAt: captureTime.addingTimeInterval(20),
                                                    event: .cleanup, captureID: "cap-1")
        expect(afterRestart.snapshotCount == newCapture.snapshotCount
               && afterRestart.currentAllocatedBytes == 140,
               "captureID idempotency survives a store restart")
        // 完整树入口同样支持事件和幂等 ID
        let indexRoot = "/index-root"
        let indexCapture = try baseStore.record(index: index([("same", 10)], path: indexRoot), diagnostics: [],
                                                capturedAt: Date(timeIntervalSince1970: t0 + 200),
                                                event: .scan, captureID: "index-cap")
        expect(indexCapture.status == "baseline" && indexCapture.event == .scan && indexCapture.previousEvent == nil,
               "the full-tree entry carries the typed event")
        let indexDuplicate = try baseStore.record(index: index([("same", 999)], path: indexRoot), diagnostics: [],
                                                  capturedAt: Date(timeIntervalSince1970: t0 + 205),
                                                  event: .scan, captureID: "index-cap")
        expect(indexDuplicate.snapshotCount == 1 && indexDuplicate.currentAllocatedBytes == 10,
               "the full-tree entry is idempotent by captureID")
        // 坏 captureID 拒绝，历史不变
        expect(try snap(150, 50, captureID: "").status == "incomparable", "empty captureID rejected")
        expect(try snap(150, 51, captureID: String(repeating: "x", count: 129)).status == "incomparable", "oversized captureID rejected")
        expect(try snap(150, 52, captureID: "bad\u{0}id").status == "incomparable", "control character captureID rejected")
        expect(try baseStore.latestReports().first { $0.rootPath == baseRoot }?.currentAllocatedBytes == 140,
               "rejected capture IDs leave history intact")
        // 旧历史没有 event/captureID：解码后按 scan 显示，新记录继续追加，不重写旧数据
        let legacyURL = root.appendingPathComponent("baseline-history").appendingPathComponent("history.json")
        var legacyObject = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        var legacyScopes = legacyObject["scopes"] as! [[String: Any]]
        for index in legacyScopes.indices {
            var observations = legacyScopes[index]["observations"] as! [[String: Any]]
            for observationIndex in observations.indices {
                observations[observationIndex].removeValue(forKey: "event")
                observations[observationIndex].removeValue(forKey: "captureID")
            }
            legacyScopes[index]["observations"] = observations
        }
        legacyObject["scopes"] = legacyScopes
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL)
        let legacyRead = try SpaceGrowthStore(directory: root.appendingPathComponent("baseline-history")).latestReports()
        let legacyReport = legacyRead.first { $0.rootPath == baseRoot }!
        expect(legacyReport.event == .scan && legacyReport.previousEvent == .scan,
               "old history without event decodes as scan, not a rewrite")
        let legacySnapshotCount = legacyReport.snapshotCount
        let afterLegacy = try SpaceGrowthStore(directory: root.appendingPathComponent("baseline-history"))
            .record(root: baseRoot, total: 150, children: [], capturedAt: captureTime.addingTimeInterval(60), event: .scan)
        expect(afterLegacy.snapshotCount == legacySnapshotCount + 1 && afterLegacy.deltaBytes == 10,
               "new records append to legacy history without rewriting it")
        // 提醒按最近一次真实快照：单次增长超过 1 GiB 就提醒
        let remindRoot = root.appendingPathComponent("baseline-remind").path
        try fm.createDirectory(atPath: remindRoot, withIntermediateDirectories: false)
        _ = try snap(GiB, 0, path: remindRoot)
        let smallStep = try snap(GiB + GiB / 3, 10, path: remindRoot)
        expect(!smallStep.shouldRemind, "a small step over the latest snapshot does not remind")
        let bigTotal = 3 * GiB + GiB / 10
        let bigStep = try snap(bigTotal, 20, path: remindRoot)
        expect(bigStep.deltaBytes == Int64(bigTotal - (GiB + GiB / 3)) && bigStep.shouldRemind,
               "a single step over the latest snapshot can remind")
        // 保留上限：每 61 分钟扫一次连扫三天，只留最近 30 次，基线是上一次
        let busyRoot = root.appendingPathComponent("baseline-busy").path
        try fm.createDirectory(atPath: busyRoot, withIntermediateDirectories: false)
        var busy: SpaceGrowthReport?
        for step in 0..<72 { busy = try snap(UInt64(1_000 + step), Double(step) * 61 * 60, path: busyRoot) }
        let window = busy!.capturedAt.timeIntervalSince(busy!.previousCapturedAt!)
        expect(busy!.snapshotCount == 30 && window == 61 * 60,
               "retention keeps the latest 30 scans and compares with the immediately previous one")
        print("SpaceGrowthStoreTests passed: latest-snapshot baseline, 10 s adjacent scans, cleanup re-measure event, captureID idempotency/restart/legacy history, reminder per latest snapshot, retention, first-record top children, signed/add/remove deltas, incomplete/permission/device/scope isolation, deep gap rejection, hardlinks, threshold, bounded retention, corrupt/symlink/read-only storage")
    }
}
