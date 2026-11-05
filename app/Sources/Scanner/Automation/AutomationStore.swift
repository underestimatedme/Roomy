// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

struct AutomationItem: Codable {
    var id: String
    var scope: AutomationScope
    var item: ScanItem
    var fingerprint: String
    var parents: String
    static func capture(_ candidate: CleanupCandidate, scope: AutomationScope) throws -> AutomationItem {
        guard candidate.entry.selectable, candidate.entry.userProtected != true,
              case .trash(let item)? = candidate.action, item.path == scope.path,
              (scope.kind == .appCache && candidate.entry.source == "appcache" && item.rule == "应用可重建缓存") ||
              (scope.kind == .derivedObjects && item.rule == "Xcode 生成缓存" && item.cleanupEvidence != nil),
              let tree = CleanupEvidence.inventory(item.path), let parents = parentKey(item.path) else {
            throw automationError("无法完整验证清理范围：\(scope.title)")
        }
        return .init(id: candidate.entry.id, scope: scope, item: item, fingerprint: tree.fingerprint, parents: parents)
    }
    static func parentKey(_ path: String) -> String? {
        ApplicationAssociations.directoryIdentities((path as NSString).deletingLastPathComponent)?.map {
            "\($0.0):\($0.1.deviceID):\($0.1.fileID)"
        }.sorted().joined(separator: "\n")
    }
    func unchanged() -> Bool {
        CleanupIdentity.capture(path: item.path) == item.identity && Self.parentKey(item.path) == parents &&
        CleanupEvidence.inventory(item.path)?.fingerprint == fingerprint
    }
    var candidate: CleanupCandidate {
        CleanupCandidate(source: scope.kind == .appCache ? "appcache" : "rule", key: item.path,
            title: item.name, size: item.size, evidence: item.evidence, risk: .amber, action: .trash(item: item))
    }
}
/// Display-only result of a read-only scan. It carries no cleanup action, token, or replayable authorization.
struct AutomationScanSummary: Codable, Equatable {
    struct Preview: Codable, Equatable {
        var title: String
        var bytes: UInt64
    }
    var scannedAt: Date
    var itemCount: Int
    var actionableCount: Int
    var estimatedBytes: UInt64
    var warnings: [String]
    var preview: [Preview]?
    func validate() throws {
        guard scannedAt.timeIntervalSince1970.isFinite,
              (0...1_000_000).contains(itemCount),
              (0...itemCount).contains(actionableCount),
              estimatedBytes <= 10_000_000_000_000,
              warnings.count <= 20,
              warnings.allSatisfy({ !$0.isEmpty && $0.count <= 300 }),
              (preview?.count ?? 0) <= 5 else { throw automationError("扫描摘要参数无效") }
        for entry in preview ?? [] {
            guard !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.title.count <= 120, entry.bytes <= 10_000_000_000_000 else {
                throw automationError("扫描摘要预览无效")
            }
        }
    }
}
enum AutomationRunStatus: String, Codable {
    case scanning, awaitingConfirmation, running, completed, partial, skipped, needsAttention
    var terminal: Bool { [.completed, .partial, .skipped, .needsAttention].contains(self) }
}
struct AutomationRun: Codable {
    var id = UUID().uuidString
    var ruleID: String
    var revision: Int
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var status: AutomationRunStatus = .scanning
    var reasons: [String]
    var token = UUID().uuidString
    var items: [AutomationItem] = []
    var outcomes: [CleanupOutcome] = []
    var intentID: String?
    var acknowledgedAt: Date?
    var message = ""
    var notified = false
    var freedBytes: UInt64 = 0
    /// Optional so older records decode unchanged. Reminder runs never discover or delete anything.
    var reminderOnly: Bool?
    /// A read-only scan record. Optional so older JSON stays readable.
    var scanOnly: Bool?
    var scanSummary: AutomationScanSummary?
    var isReminder: Bool { reminderOnly == true }
    var isScanOnly: Bool { scanOnly == true }
}
struct AutomationDatabase: Codable {
    var schema = 1
    var paused = true
    var rules: [AutomationRule] = []
    var runtimes: [String: AutomationRuntime] = [:]
    var runs: [AutomationRun] = []
    mutating func invalidateRuns(ruleID: String, message: String) {
        for i in runs.indices where runs[i].ruleID == ruleID && !runs[i].status.terminal {
            if runs[i].reasons.contains("space"), runs[i].intentID == nil, !runs[i].outcomes.contains(where: \.ok) {
                runtimes[ruleID]?.spaceLatched = false
            }
            // Preserve an in-flight intent until the worker records its outcome. Never hide uncertain work.
            runs[i].status = runs[i].intentID == nil ? .skipped : .needsAttention
            runs[i].message = message; runs[i].token = UUID().uuidString
        }
    }
    func validate() throws {
        guard schema == 1, rules.count <= 100, Set(rules.map(\.id)).count == rules.count,
              Set(runs.map(\.id)).count == runs.count else { throw automationError("自动清理记录版本不兼容或数据损坏") }
        for rule in rules { try rule.validate() }
        for run in runs {
            guard UUID(uuidString: run.id) != nil, UUID(uuidString: run.token) != nil,
                  run.items.count <= 100, Set(run.items.map(\.id)).count == run.items.count else {
                throw automationError("自动清理任务记录损坏")
            }
            if run.scanOnly == true {
                // A scan record is display-only. It must never become a confirmation or execution entry.
                guard run.items.isEmpty, run.outcomes.isEmpty, run.intentID == nil, run.freedBytes == 0,
                      run.status != .awaitingConfirmation, run.status != .running else {
                    throw automationError("只读扫描记录不能包含清理授权或删除结果")
                }
            }
            try run.scanSummary?.validate()
        }
    }
}

/// State transactions never hold the deletion lease. Worker uses operation -> state lock order.
final class AutomationStore {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func read() throws -> AutomationDatabase { try update(write: false) { $0 } }
    @discardableResult func update<T>(write: Bool = true, _ body: (inout AutomationDatabase) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard ApplicationAssociations.directoryIdentities(directory.path) != nil else { throw automationError("自动清理记录目录不可安全读取") }
        let lease = try OperationLease.acquire(path: directory.appendingPathComponent("automation-state.lock").path)
        return try withExtendedLifetime(lease) {
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw automationError("自动清理记录目录无法打开") }; defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == getuid() else { throw automationError("记录目录所有者异常") }
            var db = AutomationDatabase()
            let input = openat(fd, "automation.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if input >= 0 {
                defer { close(input) }
                guard fstat(input, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_nlink == 1,
                      st.st_size >= 0, st.st_size <= 32*1024*1024 else { throw automationError("自动清理记录类型或大小异常") }
                let handle = FileHandle(fileDescriptor: input, closeOnDealloc: false)
                guard let data = try handle.readToEnd() else { throw automationError("自动清理记录不可读取") }
                do { db = try JSONDecoder().decode(AutomationDatabase.self, from: data) }
                catch { throw automationError("自动清理记录损坏，已停止执行：\(error.localizedDescription)") }
            } else if errno != ENOENT { throw automationError("自动清理记录不可读取") }
            try db.validate()
            let result = try body(&db)
            if write {
                try db.validate()
                let data = try JSONEncoder().encode(db)
                guard data.count <= 32*1024*1024 else { throw automationError("自动清理记录过大") }
                let temporary = ".automation-" + UUID().uuidString
                let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw automationError("无法保存自动清理记录") }
                defer { close(output); unlinkat(fd, temporary, 0) }
                let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
                try handle.write(contentsOf: data)
                guard fsync(output) == 0, renameat(fd, temporary, fd, "automation.json") == 0, fsync(fd) == 0 else {
                    throw automationError("自动清理记录未能持久保存，已停止执行")
                }
            }
            return result
        }
    }
}
