// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

/// 一次采集的来源：普通扫描，或实际清理完成后重新测得的一次快照。
/// 只标记真实测量，不接受按删除字节推算出来的结果。
enum SpaceGrowthEvent: String, Codable, Sendable {
    case scan, cleanup
}

struct SpaceGrowthRow: Codable, Sendable {
    let path: String
    /// added/removed describe observed paths, not actions performed by Roomy.
    let kind: String
    let currentAllocatedBytes: UInt64?
    let previousAllocatedBytes: UInt64?
    let deltaBytes: Int64
}

struct SpaceGrowthReport: Codable, Sendable {
    let status: String
    let reason: String?
    let rootPath: String
    let capturedAt: Date
    let previousCapturedAt: Date?
    let currentAllocatedBytes: UInt64
    let previousAllocatedBytes: UInt64?
    let deltaBytes: Int64?
    let rows: [SpaceGrowthRow]
    let shouldRemind: Bool
    let snapshotCount: Int
    /// 产生当前这份数据的采集类型；旧历史缺省按 scan 显示。
    var event: SpaceGrowthEvent? = nil
    /// 当前对比基线的采集类型；没有基线时为 nil。
    var previousEvent: SpaceGrowthEvent? = nil
}

/// Chart data always comes from complete measurements, never reconstructed deletion estimates.
struct SpaceGrowthPoint: Codable, Sendable {
    let capturedAt: Date
    let bytes: UInt64
}
struct SpaceGrowthTrend: Codable, Sendable {
    let path: String
    let rootPath: String
    let points: [SpaceGrowthPoint]
}
struct SpaceDiskObservation: Codable, Sendable {
    let volumeID: String
    let capturedAt: Date
    let total: UInt64
    let free: UInt64
    let captureID: String?
    var used: UInt64 { total - free }

    static func measure(capturedAt: Date = Date(), captureID: String? = nil) -> Self? {
        for path in ["/System/Volumes/Data", "/"] {
            var info = statfs()
            guard statfs(path, &info) == 0, info.f_blocks > 0, info.f_bsize > 0,
                  let id = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                  !id.isEmpty else { continue }
            let total = UInt64(info.f_blocks).multipliedReportingOverflow(by: UInt64(info.f_bsize))
            let free = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
            guard !total.overflow, !free.overflow, free.partialValue <= total.partialValue else { continue }
            return Self(volumeID: id, capturedAt: capturedAt, total: total.partialValue,
                        free: free.partialValue, captureID: captureID)
        }
        return nil
    }
}
struct SpaceGrowthDashboard: Codable, Sendable {
    let reports: [SpaceGrowthReport]
    let trends: [SpaceGrowthTrend]
    let diskHistory: [SpaceDiskObservation]
    let diskCurrent: SpaceDiskObservation?
}

/// Local, bounded observations of complete scan roots and their direct children.
/// These are allocated bytes charged by ScanIndex, never reclaimable or free bytes.
/// No paginated presentation data is accepted. Failed/incomplete scans leave history intact.
struct SpaceGrowthStore: Sendable {
    static let reminderThreshold: Int64 = 1_073_741_824
    /// 最近 30 次不同采集；不再按时间合并，几秒内的连续扫描也各留一份。
    private static let maxSnapshots = 30
    private static let maxScopes = 16
    private static let maxChildren = 512
    private static let maxFileBytes = 8 * 1_024 * 1_024
    private static let maxCaptureIDBytes = 128
    let directory: URL

    private struct Item: Codable { let path: String; let bytes: UInt64 }
    private struct Observation: Codable {
        let capturedAt: Date
        let total: UInt64
        let items: [Item]
        let reason: String?
        /// 旧历史没有这个字段：解码为 nil，展示时按 .scan 处理，不回写旧记录。
        var event: SpaceGrowthEvent? = nil
        /// 采集幂等标识；旧历史没有这个字段。同一 root 的同一 id 重复投递不追加。
        var captureID: String? = nil
    }
    private struct Scope: Codable {
        let rootPath: String
        let deviceID: UInt64
        let rootFileID: UInt64
        let coverageID: String
        var observations: [Observation]
    }
    private struct History: Codable {
        var version = 1
        var scopes: [Scope] = []
        var disk: [SpaceDiskObservation]? = nil
    }
    enum StoreError: Error, LocalizedError {
        case unsafe, unavailable, corrupt, limit
        var errorDescription: String? {
            switch self {
            case .unsafe: return "增长历史路径或权限不安全，未读取或修改历史。"
            case .unavailable: return "无法读取或保存本机增长历史，请检查目录权限。"
            case .corrupt: return "本机增长历史格式损坏或不兼容，原记录已保留。"
            case .limit: return "增长历史超过本机存储上限，未保存此次记录。"
            }
        }
    }

    /// event 默认 .scan；.cleanup 只应由实际清理后重新测量得到的快照传入。
    /// captureID 是可选幂等标识：同一 root 重复投递同一个 id 不会追加或改写历史。
    func record(index: ScanIndex, diagnostics: [ScanDiagnostic], completed: Bool = true,
                coverageID: String = "full-tree-v1", capturedAt: Date = Date(),
                event: SpaceGrowthEvent = .scan, captureID: String? = nil) throws -> SpaceGrowthReport {
        let total = index.entries.isEmpty ? 0 : index.totalAllocated(of: 0)
        guard completed, !index.entries.isEmpty, diagnostics.isEmpty else {
            return Self.incomparable("此次扫描未完整完成或存在权限/读取缺口，不能比较增长；已有完整记录保留。",
                root: index.rootPath, total: total, capturedAt: capturedAt)
        }
        guard index.entries[0].kind == .directory, Self.validPath(index.rootPath), !coverageID.isEmpty, coverageID.utf8.count <= 128,
              capturedAt.timeIntervalSince1970.isFinite, total <= UInt64(Int64.max) else {
            return Self.incomparable("扫描范围、时间或占用数据无效，不能比较增长。",
                root: index.rootPath, total: total, capturedAt: capturedAt)
        }
        let children = index.children(of: 0)
        guard children.count <= Self.maxChildren else {
            return Self.incomparable("此范围的直接子项超过 512 个；为限制本机历史大小，此次不保存或比较，请扫描更小的目录。",
                root: index.rootPath, total: total, capturedAt: capturedAt)
        }
        let items = children.map { Item(path: index.path(for: $0), bytes: index.totalAllocated(of: $0)) }
        let rootEntry = index.entries[0]
        return try commit(root: index.rootPath, deviceID: rootEntry.deviceID, rootFileID: rootEntry.fileID, total: total,
                          items: items, coverageID: coverageID, capturedAt: capturedAt,
                          event: event, captureID: captureID)
    }

    /// 清理扫描的后台遍历给出的统计：根的总占用，加上它的直接子目录（增长对比保留全部一级目录）。
    /// 覆盖策略固定为 cleanup-walk-v2：一级目录不再按 200 MB 门槛截断，和旧策略的记录只能重新基线；
    /// 与完整树扫描（record(index:)）的历史也互不比较。根的设备号和文件号取自当前文件系统。
    static let walkCoverageID = "cleanup-walk-v2"

    /// 遍历是否完整覆盖这个根：根或任意后代读不到时，缺失部分不在根总量里，
    /// 之后授权了会显示成假的增长，所以这样的根不记录、保留之前的历史。
    /// 深层缺口由 BulkWalker 记到所属并行任务路径（不逐个记 6 层以下路径），这里按路径边界判断：
    /// /h 只匹配 /h 和 /h/...，不会误匹配 /hh。skip 是固定的隐私保护策略，属于覆盖定义的一部分：
    /// 跳过的目录本来就不在总量里，不能因此声称已读全部卷。
    static func coverageComplete(root: String, unreadable: [String]) -> Bool {
        !unreadable.contains { path in
            if path == root { return true }
            return root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/")
        }
    }

    /// 系统区域的总量会随系统更新动几个 GB，照常记录和显示，但不触发增长提醒
    private static func reminds(_ scope: Scope) -> Bool {
        !(scope.coverageID == walkCoverageID && ScanPipeline.systemAreaRoots().contains(scope.rootPath))
    }
    /// 只接受真实遍历得到的根总量和一级子目录；children 只含一级目录，根总量包含根里的文件，
    /// 一级文件不要求出现在排行里。event 默认 .scan，清理后重新测量时传 .cleanup。
    func record(root: String, total: UInt64, children: [(path: String, bytes: UInt64)],
                capturedAt: Date = Date(), event: SpaceGrowthEvent = .scan,
                captureID: String? = nil) throws -> SpaceGrowthReport {
        guard Self.validPath(root), capturedAt.timeIntervalSince1970.isFinite, total <= UInt64(Int64.max) else {
            return Self.incomparable("扫描范围、时间或占用数据无效，不能比较增长。", root: root, total: total, capturedAt: capturedAt)
        }
        var metadata = stat()
        guard lstat(root, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            return Self.incomparable("无法确认扫描根目录的身份，不能比较增长。", root: root, total: total, capturedAt: capturedAt)
        }
        guard children.count <= Self.maxChildren else {
            return Self.incomparable("此范围的直接子项超过 512 个；为限制本机历史大小，此次不保存或比较，请扫描更小的目录。",
                root: root, total: total, capturedAt: capturedAt)
        }
        return try commit(root: root, deviceID: UInt64(UInt32(bitPattern: metadata.st_dev)), rootFileID: UInt64(metadata.st_ino),
                          total: total, items: children.map { Item(path: $0.path, bytes: $0.bytes) },
                          coverageID: Self.walkCoverageID, capturedAt: capturedAt,
                          event: event, captureID: captureID)
    }

    private static func incomparable(_ reason: String, root: String, total: UInt64, capturedAt: Date) -> SpaceGrowthReport {
        SpaceGrowthReport(status: "incomparable", reason: reason, rootPath: root,
            capturedAt: capturedAt, previousCapturedAt: nil, currentAllocatedBytes: total,
            previousAllocatedBytes: nil, deltaBytes: nil, rows: [], shouldRemind: false, snapshotCount: 0)
    }

    private func commit(root: String, deviceID: UInt64, rootFileID: UInt64, total: UInt64, items: [Item],
                        coverageID: String, capturedAt: Date, event: SpaceGrowthEvent,
                        captureID: String?) throws -> SpaceGrowthReport {
        guard Self.validItems(items, root: root, total: total) else {
            return Self.incomparable("扫描子项不完整、重复或大小无效，不能比较增长。", root: root, total: total, capturedAt: capturedAt)
        }
        guard Self.validCaptureID(captureID) else {
            return Self.incomparable("采集标识无效或过长，未保存此次记录。", root: root, total: total, capturedAt: capturedAt)
        }
        return try withDirectory(create: true) { fd in
            var history = try readHistory(fd)
            // 同一 root 的同一 captureID 重复投递：不追加、不改历史，直接返回该范围已有的报告。
            if let captureID,
               let duplicate = history.scopes.first(where: {
                   $0.rootPath == root && $0.observations.contains { $0.captureID == captureID }
               }) {
                return Self.report(duplicate)
            }
            let existing = history.scopes.firstIndex { $0.rootPath == root && $0.deviceID == deviceID && $0.rootFileID == rootFileID && $0.coverageID == coverageID }
            let sameRootChanged = existing == nil && history.scopes.contains { $0.rootPath == root }
            let reason = sameRootChanged ? "扫描设备、目录标识或范围策略已改变，已建立新基线；不能与旧范围比较。" : nil
            let observation = Observation(capturedAt: capturedAt, total: total, items: items, reason: reason,
                                          event: event, captureID: captureID)
            var scope = existing.map { history.scopes[$0] } ?? Scope(rootPath: root,
                deviceID: deviceID, rootFileID: rootFileID, coverageID: coverageID, observations: [])
            if let last = scope.observations.last, capturedAt <= last.capturedAt {
                return Self.incomparable("扫描时间不晚于已有记录，未覆盖历史；请重新扫描。", root: root, total: total, capturedAt: capturedAt)
            }
            if let existing { history.scopes.remove(at: existing) }
            // 每次不同采集都保留；不再按 1 小时窗口替换最近一次。
            scope.observations.append(observation)
            scope.observations = Array(scope.observations.suffix(Self.maxSnapshots))
            history.scopes.append(scope)
            history.scopes = Array(history.scopes.suffix(Self.maxScopes))
            try writeHistory(history, fd: fd)
            return Self.report(scope)
        }
    }

    /// Read-only: a missing store is empty; malformed/unsafe/unreadable stores throw.
    /// Returns newest observation per retained scope, including its preceding comparison.
    func latestReports() throws -> [SpaceGrowthReport] {
        try withDirectory(create: false) { fd in
            guard fd >= 0 else { return [] }
            return try readHistory(fd).scopes.map(Self.report).sorted { $0.capturedAt > $1.capturedAt }
        }
    }

    /// Separate volume samples remain useful even when some directories cannot be read.
    func recordDisk(_ sample: SpaceDiskObservation) throws {
        guard Self.validDisk(sample) else { throw StoreError.corrupt }
        try withDirectory(create: true) { fd in
            var history = try readHistory(fd)
            var samples = history.disk ?? []
            if let id = sample.captureID, samples.contains(where: { $0.volumeID == sample.volumeID && $0.captureID == id }) { return }
            if let last = samples.last, sample.capturedAt <= last.capturedAt { return }
            samples.append(sample)
            history.disk = Array(samples.suffix(Self.maxSnapshots))
            try writeHistory(history, fd: fd)
        }
    }

    /// A read never creates records. Old files without disk samples continue to decode.
    func dashboard(currentDisk: SpaceDiskObservation? = nil) throws -> SpaceGrowthDashboard {
        try withDirectory(create: false) { fd in
            let history = fd >= 0 ? try readHistory(fd) : History()
            // Do not join histories from replaced devices, roots or coverage policies.
            var latest: [String: Scope] = [:]
            for scope in history.scopes {
                if let old = latest[scope.rootPath], old.observations.last!.capturedAt > scope.observations.last!.capturedAt { continue }
                latest[scope.rootPath] = scope
            }
            let scopes = latest.values.sorted { $0.rootPath < $1.rootPath }
            let reports = scopes.map(Self.report)
            var trends: [SpaceGrowthTrend] = []
            for scope in scopes {
                let observations = scope.observations
                trends.append(SpaceGrowthTrend(path: scope.rootPath, rootPath: scope.rootPath,
                    points: observations.map { SpaceGrowthPoint(capturedAt: $0.capturedAt, bytes: $0.total) }))
                let rows = Self.report(scope).rows
                let largest = rows.sorted { ($0.currentAllocatedBytes ?? 0) > ($1.currentAllocatedBytes ?? 0) }.prefix(8)
                let changed = rows.sorted { abs($0.deltaBytes) > abs($1.deltaBytes) }.prefix(8)
                let paths = Set(largest.map(\.path) + changed.map(\.path)).sorted()
                for path in paths {
                    trends.append(SpaceGrowthTrend(path: path, rootPath: scope.rootPath,
                        points: observations.map { observation in
                            // Each snapshot covers all direct children: absence is a measured zero.
                            SpaceGrowthPoint(capturedAt: observation.capturedAt,
                                             bytes: observation.items.first { $0.path == path }?.bytes ?? 0)
                        }))
                }
            }
            let disks = (history.disk ?? []).filter { currentDisk == nil || $0.volumeID == currentDisk!.volumeID }
            return SpaceGrowthDashboard(reports: reports, trends: trends,
                                        diskHistory: disks, diskCurrent: currentDisk)
        }
    }

    private static func validDisk(_ sample: SpaceDiskObservation) -> Bool {
        !sample.volumeID.isEmpty && sample.volumeID.utf8.count <= 128 &&
        sample.capturedAt.timeIntervalSince1970.isFinite && sample.total > 0 &&
        sample.total <= UInt64(Int64.max) && sample.free <= sample.total && validCaptureID(sample.captureID)
    }

    /// 对比基线：最近一份更早的完整快照。连续扫描即使只隔几秒也各自保留、逐一对比。
    private static func baseline(_ scope: Scope) -> Observation? {
        scope.observations.dropLast().last
    }

    private static func report(_ scope: Scope) -> SpaceGrowthReport {
        let current = scope.observations.last!
        let previous = baseline(scope)
        var rows: [SpaceGrowthRow] = []
        // 首次记录也要能看出空间去了哪：只列当前最大的直接子项，delta 记 0 且 kind 为 current，
        // 表示"现在的占用"而不是"变化"，不会伪造任何释放或增长的结论。
        if previous == nil {
            rows = current.items.map { SpaceGrowthRow(path: $0.path, kind: "current",
                currentAllocatedBytes: $0.bytes, previousAllocatedBytes: nil, deltaBytes: 0) }
                .sorted { ($0.currentAllocatedBytes ?? 0) == ($1.currentAllocatedBytes ?? 0)
                    ? $0.path < $1.path : ($0.currentAllocatedBytes ?? 0) > ($1.currentAllocatedBytes ?? 0) }
        }
        if let previous {
            let before = Dictionary(uniqueKeysWithValues: previous.items.map { ($0.path, $0.bytes) })
            let after = Dictionary(uniqueKeysWithValues: current.items.map { ($0.path, $0.bytes) })
            rows = Set(before.keys).union(after.keys).map { path in
                let old = before[path], new = after[path]
                let delta = Int64(new ?? 0) - Int64(old ?? 0)
                return SpaceGrowthRow(path: path, kind: old == nil ? "added" : new == nil ? "removed" : delta == 0 ? "unchanged" : "changed",
                    currentAllocatedBytes: new, previousAllocatedBytes: old, deltaBytes: delta)
            }.sorted { $0.deltaBytes == $1.deltaBytes ? $0.path < $1.path : $0.deltaBytes > $1.deltaBytes }
        }
        let delta = previous.map { Int64(current.total) - Int64($0.total) }
        // 旧历史没有 event 字段：按 scan 展示，不把缺失当成 cleanup，也不回写旧记录。
        let event = current.event ?? .scan
        let previousEvent = previous.map { $0.event ?? .scan }
        return SpaceGrowthReport(status: previous != nil ? "compared" : current.reason == nil ? "baseline" : "incomparable",
            reason: previous == nil ? current.reason : nil, rootPath: scope.rootPath, capturedAt: current.capturedAt,
            previousCapturedAt: previous?.capturedAt, currentAllocatedBytes: current.total,
            previousAllocatedBytes: previous?.total, deltaBytes: delta, rows: rows,
            shouldRemind: reminds(scope) && (delta ?? 0) >= reminderThreshold, snapshotCount: scope.observations.count,
            event: event, previousEvent: previousEvent)
    }

    private static func validPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// nil 合法；非 nil 必须有界且不含控制字符。空串、超长和坏字符都拒绝，避免写进历史。
    private static func validCaptureID(_ id: String?) -> Bool {
        guard let id else { return true }
        guard !id.isEmpty, id.utf8.count <= maxCaptureIDBytes else { return false }
        return !id.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func validItems(_ items: [Item], root: String, total: UInt64) -> Bool {
        guard items.count <= maxChildren, Set(items.map(\.path)).count == items.count else { return false }
        var sum: UInt64 = 0
        for item in items {
            guard validPath(item.path), item.path != root,
                  URL(fileURLWithPath: item.path).deletingLastPathComponent().path == root,
                  item.bytes <= UInt64(Int64.max) else { return false }
            let addition = sum.addingReportingOverflow(item.bytes)
            guard !addition.overflow else { return false }
            sum = addition.partialValue
        }
        return sum <= total
    }

    private func validate(_ history: History) throws {
        guard history.version == 1, history.scopes.count <= Self.maxScopes else { throw StoreError.corrupt }
        let disks = history.disk ?? []
        guard disks.count <= Self.maxSnapshots else { throw StoreError.corrupt }
        var diskTime: Date?
        var diskIDs = Set<String>()
        for sample in disks {
            guard Self.validDisk(sample), diskTime == nil || sample.capturedAt > diskTime! else { throw StoreError.corrupt }
            if let id = sample.captureID {
                guard diskIDs.insert(sample.volumeID + "\u{0}" + id).inserted else { throw StoreError.corrupt }
            }
            diskTime = sample.capturedAt
        }
        var keys = Set<String>()
        var captureKeys = Set<String>()
        for scope in history.scopes {
            let key = "\(scope.rootPath)\u{0}\(scope.deviceID)\u{0}\(scope.rootFileID)\u{0}\(scope.coverageID)"
            guard keys.insert(key).inserted, Self.validPath(scope.rootPath), !scope.coverageID.isEmpty,
                  scope.coverageID.utf8.count <= 128, !scope.observations.isEmpty,
                  scope.observations.count <= Self.maxSnapshots else { throw StoreError.corrupt }
            var previous: Date?
            for observation in scope.observations {
                guard observation.capturedAt.timeIntervalSince1970.isFinite,
                      previous == nil || observation.capturedAt > previous!,
                      observation.total <= UInt64(Int64.max), (observation.reason?.utf8.count ?? 0) <= 1024,
                      Self.validCaptureID(observation.captureID),
                      Self.validItems(observation.items, root: scope.rootPath, total: observation.total) else { throw StoreError.corrupt }
                if let id = observation.captureID {
                    guard captureKeys.insert(scope.rootPath + "\u{0}" + id).inserted else { throw StoreError.corrupt }
                }
                previous = observation.capturedAt
            }
        }
    }

    // Directory descriptors and O_NOFOLLOW prevent store paths from traversing links.
    // A fixed advisory lock serializes writers across independent GUI/CLI processes.
    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        guard directory.isFileURL, Self.validPath(directory.path), directory.path != "/" else { throw StoreError.unsafe }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError.unavailable }
        defer { if fd >= 0 { close(fd) } }
        for part in directory.path.split(separator: "/") {
            var next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                if !create { return try body(-1) }
                guard mkdirat(fd, String(part), 0o700) == 0 || errno == EEXIST else { throw StoreError.unavailable }
                next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else { throw StoreError.unsafe }
            close(fd); fd = next
        }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_mode & 0o500 == 0o500, !create || metadata.st_mode & 0o200 != 0 else { throw StoreError.unsafe }
        // Readers need no lock: atomic replacement exposes either complete file version.
        if !create { return try body(fd) }
        let lockFD = openat(fd, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw StoreError.unsafe }
        defer { close(lockFD) }
        try checkFile(lockFD)
        guard flock(lockFD, LOCK_EX) == 0 else { throw StoreError.unavailable }
        defer { _ = flock(lockFD, LOCK_UN) }
        return try body(fd)
    }

    private func checkFile(_ fd: Int32) throws {
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0 else { throw StoreError.unsafe }
    }

    private func readHistory(_ directoryFD: Int32) throws -> History {
        let fd = openat(directoryFD, "history.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return History() }
        guard fd >= 0 else { throw StoreError.unsafe }
        defer { close(fd) }
        try checkFile(fd)
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_size <= Self.maxFileBytes else { throw StoreError.corrupt }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw StoreError.unavailable }
            if count == 0 { break }
            guard data.count + count <= Self.maxFileBytes else { throw StoreError.corrupt }
            data.append(contentsOf: buffer.prefix(count))
        }
        let history: History
        do { history = try JSONDecoder().decode(History.self, from: data) } catch { throw StoreError.corrupt }
        try validate(history)
        return history
    }

    private func writeHistory(_ history: History, fd: Int32) throws {
        let data = try JSONEncoder().encode(history)
        guard data.count <= Self.maxFileBytes else { throw StoreError.limit }
        // The writer lock makes a fixed temporary name safe and bounds crash leftovers.
        let name = ".history.tmp"
        if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw StoreError.unsafe }
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw StoreError.unavailable }
        defer { close(output); _ = unlinkat(fd, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw StoreError.unavailable }
                offset += count
            }
        }
        guard fsync(output) == 0, renameat(fd, name, fd, "history.json") == 0 else { throw StoreError.unavailable }
        _ = fsync(fd)
    }
}
