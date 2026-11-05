// SPDX-License-Identifier: MPL-2.0
// 清单的数据模型。CleanupEntry 只给界面看；CleanupAction 只留在 Swift 端，网页永远拿不到。

import CryptoKit
import Darwin
import Foundation

enum DockerObjectKind: String, Codable { case volume, image, container }

enum CleanupAction {
    case trash(item: ScanItem)
    case simctlDeleteDevice(udid: String)
    case simctlDeleteRuntime(id: String)
    case ollamaRemove(model: String)
    /// 按预览列出的对象逐个删，不可撤回。expectedID：预览时这个镜像引用指向的镜像 ID，执行前比对
    case dockerRemove(kind: DockerObjectKind, id: String, expectedID: String? = nil)
    case toolClean(ToolCleanCommand, scope: String)   // 让包管理器自己清空整个缓存，不可撤回
    case worktreeRemove(item: ScanItem, repo: String, branch: String?, base: String)
    case launchAgentRemove(label: String, item: ScanItem)   // launchctl bootout + plist 进废纸篓

    var reversible: Bool {
        switch self {
        case .trash, .worktreeRemove, .launchAgentRemove: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .trash: return "进废纸篓"
        case .simctlDeleteDevice, .simctlDeleteRuntime: return "用 simctl 删除"
        case .ollamaRemove: return "用 ollama rm 删除"
        case .dockerRemove(let kind, _, _): return "用 docker \(kind.rawValue) rm 删除"
        case .toolClean(let c, _): return c.actionLabel
        case .worktreeRemove: return "移到废纸篓（放回原处即恢复）"
        case .launchAgentRemove: return "停用并把启动项移到废纸篓"
        }
    }
}

/// 派生同一项的新版本（降级、换档、锁定、换大小、CLI 绑定 ID）一律"整份复制再改个别字段"，
/// 不要逐字段重建：新增字段（如 safetyHold）会在手写的拷贝里悄悄丢掉
struct CleanupEntry: Codable, Equatable {
    var id: String
    let title: String
    var size: UInt64
    let estimateIsApprox: Bool
    var evidence: String
    var actionLabel: String
    var reversible: Bool
    var risk: Risk
    var selectable: Bool
    var defaultChecked: Bool
    let source: String
    var category = ""   // CleanupCategories 的 key
    var group = ""      // 同一规则 / 同一仓库的多项合成一行
    var path: String? = nil
    var userProtected: Bool? = nil
    var tier: CleanupTier? = nil
    var tierReason: String? = nil
    var preferenceKey: CleanupPreferenceKey? = nil
    var preference: CleanupPreferenceHint? = nil
    var lockReason: String? = nil   // tier == .locked 时给用户看的原因
    /// 因安全原因（无法检查运行状态、被后台服务使用等）被降到 C：任何档位覆盖都不能把它再抬上去
    var safetyHold: Bool? = nil
}

struct CleanupCandidate {
    var entry: CleanupEntry
    let action: CleanupAction?   // nil = 只是提示行，比如"Docker 未运行"

    init(source: String, key: String, title: String, size: UInt64, evidence: String,
         risk: Risk, action: CleanupAction?, estimateIsApprox: Bool = false,
         tier: CleanupTier = .review, tierReason: String? = nil) {
        let selectable = action != nil && risk != .lock
        let reversible = action?.reversible ?? false
        entry = CleanupEntry(id: CleanupCandidate.stableID(source, key), title: title, size: size,
            estimateIsApprox: estimateIsApprox, evidence: evidence, actionLabel: action?.label ?? "",
            reversible: reversible, risk: risk, selectable: selectable,
            defaultChecked: tier == .obsolete && selectable, source: source)
        entry.tier = tier; entry.tierReason = tierReason
        self.action = action
        self.entry.path = targetPath
    }

    init(entry: CleanupEntry, action: CleanupAction?) {
        self.entry = entry
        self.action = action
        if self.entry.path == nil { self.entry.path = targetPath }
    }

    /// 同一项，但不再默认勾选，依据前面加上原因
    func requiringReview(_ reason: String) -> CleanupCandidate {
        // 整份复制（路径、分组、保护、锁定原因等都保留），只改降级相关的字段
        var reviewed = entry
        reviewed.evidence = reason + " · " + entry.evidence
        reviewed.risk = entry.risk == .lock ? .lock : .amber
        reviewed.defaultChecked = false
        reviewed.tier = .review; reviewed.tierReason = reason
        reviewed.safetyHold = true
        return CleanupCandidate(entry: reviewed, action: action)
    }

    /// 已经是 C 档的同一项也标上安全降级（例如有进程正在使用该目录）
    func holdingForSafety() -> CleanupCandidate {
        var held = self
        held.entry.safetyHold = true
        return held
    }

    /// 同一项换到另一档，按新档重算勾选；.locked 一律不可选
    func retiered(_ tier: CleanupTier, reason: String) -> CleanupCandidate {
        var moved = entry
        moved.selectable = entry.selectable && tier != .locked
        moved.defaultChecked = tier == .obsolete && moved.selectable
        moved.tier = tier; moved.tierReason = reason
        if tier == .locked { moved.lockReason = reason }
        return CleanupCandidate(entry: moved, action: action)
    }

    /// 同一项锁定：不能删，不带动作，只留原因给用户看
    func locked(_ reason: String) -> CleanupCandidate {
        var lockedEntry = entry
        lockedEntry.actionLabel = ""; lockedEntry.reversible = false
        lockedEntry.selectable = false; lockedEntry.defaultChecked = false
        lockedEntry.tier = .locked; lockedEntry.tierReason = reason; lockedEntry.lockReason = reason
        return CleanupCandidate(entry: lockedEntry, action: nil)
    }

    /// 同一项换成真实大小（entry 和 action 里的 ScanItem 一起改），id 不变
    func withSize(_ size: UInt64) -> CleanupCandidate {
        var sized = entry
        sized.size = size
        let newAction: CleanupAction?
        switch action {
        case .trash(let item)?: newAction = .trash(item: item.withSize(size))
        case .worktreeRemove(let item, let repo, let branch, let base)?:
            newAction = .worktreeRemove(item: item.withSize(size), repo: repo, branch: branch, base: base)
        case .launchAgentRemove(let label, let item)?: newAction = .launchAgentRemove(label: label, item: item.withSize(size))
        default: newAction = action
        }
        return CleanupCandidate(entry: sized, action: newAction)
    }

    var targetPath: String? {
        switch action {
        case .trash(let item)?, .worktreeRemove(let item, _, _, _)?, .launchAgentRemove(_, let item)?: return item.path
        // 整块清理的范围也是路径：后台服务依赖、用户保护等按路径的检查要能看到它
        case .toolClean(_, let scope)?: return scope.hasPrefix("/") && scope != "/" ? scope : nil
        default: return nil
        }
    }

    static func stableID(_ source: String, _ key: String) -> String {
        SHA256.hash(data: Data("\(source)\u{0}\(key)".utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// 扫描批次：新扫描开始后，旧扫描晚到的结果一律丢掉
final class ScanGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt64 = 0
    func begin() -> UInt64 { lock.lock(); defer { lock.unlock() }; current += 1; return current }
    func isCurrent(_ g: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return g == current }
    /// 当前这一代（0 = 还没有扫描过）
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return current }
}

enum Humanize {
    static func span(days: Int) -> String? {
        if days < 1 { return nil }
        if days < 30 { return "\(days) 天" }
        if days < 365 { return "\(days / 30) 个月" }
        return "\(days / 365) 年"
    }
}

extension CleanupIdentity {
    static func capture(path: String) -> CleanupIdentity? {
        var value = stat()
        guard lstat(path, &value) == 0 else { return nil }
        let kind: EntryKind
        switch value.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        return CleanupIdentity(deviceID: UInt64(UInt32(bitPattern: value.st_dev)), fileID: value.st_ino,
            kind: kind, allocatedSize: UInt64(value.st_blocks) * 512,
            modifiedAt: Int64(value.st_mtimespec.tv_sec), logicalSize: UInt64(max(0, value.st_size)),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
}

extension ScanItem {
    func withSize(_ size: UInt64) -> ScanItem {
        ScanItem(name: name, path: path, size: size, atimeDays: atimeDays, mtimeDays: mtimeDays, usedDays: usedDays,
                 rule: rule, evidence: evidence, risk: risk, gentle: gentle, hard: hard, undo: undo, note: note,
                 rebuild: rebuild, identity: identity, reclaimEstimate: reclaimEstimate, cleanupEvidence: cleanupEvidence)
    }

    /// 探测器发现的、要进废纸篓的目录。身份在发现时记录，执行前由 CleanupValidator 比对。
    static func trashTarget(path: String, name: String, size: UInt64, rule: String,
                            evidence: String, risk: Risk) -> ScanItem {
        ScanItem(name: name, path: path, size: size, atimeDays: nil, mtimeDays: nil,
            rule: rule, evidence: evidence, risk: risk, gentle: nil, hard: "移到废纸篓",
            undo: true, note: "", rebuild: .costly, identity: CleanupIdentity.capture(path: path))
    }
}
