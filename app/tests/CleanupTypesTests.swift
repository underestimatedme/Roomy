// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct CleanupTypesTests {
    static func main() throws {
        precondition(Humanize.span(days: 0) == nil)
        precondition(Humanize.span(days: 1) == "1 天")
        precondition(Humanize.span(days: 29) == "29 天")
        precondition(Humanize.span(days: 30) == "1 个月")
        precondition(Humanize.span(days: 200) == "6 个月")
        precondition(Humanize.span(days: 365) == "1 年")
        precondition(Humanize.span(days: 800) == "2 年")

        let a = CleanupCandidate.stableID("sim", "X"), b = CleanupCandidate.stableID("sim", "X")
        precondition(a == b && a.count == 16)
        precondition(CleanupCandidate.stableID("sim", "Y") != a)
        precondition(CleanupCandidate.stableID("simX", "") != CleanupCandidate.stableID("sim", "X"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-types-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = CleanupIdentity.capture(path: dir.path)
        precondition(identity?.kind == .directory && identity?.logicalSize != nil && identity?.modifiedNanoseconds != nil)
        precondition(CleanupIdentity.capture(path: dir.path + "/missing") == nil)

        let item = ScanItem.trashTarget(path: dir.path, name: "x", size: 10, rule: "r", evidence: "e", risk: .green)
        precondition(item.undo && item.identity == identity)

        let green = CleanupCandidate(source: "rule", key: dir.path, title: "t", size: 10,
            evidence: "e", risk: .green, action: .trash(item: item), tier: .obsolete)
        precondition(green.entry.defaultChecked && green.entry.reversible && green.entry.selectable)
        precondition(green.entry.actionLabel == "进废纸篓")

        let device = CleanupCandidate(source: "sim", key: "u", title: "t", size: 10, evidence: "e",
            risk: .green, action: .simctlDeleteDevice(udid: "u"))
        precondition(!device.entry.defaultChecked && !device.entry.reversible, "irreversible is never pre-checked")

        let hint = CleanupCandidate(source: "docker", key: "down", title: "Docker 未运行", size: 0,
            evidence: "e", risk: .amber, action: nil)
        precondition(!hint.entry.selectable && !hint.entry.defaultChecked)

        let locked = CleanupCandidate(source: "rule", key: "l", title: "t", size: 1, evidence: "e",
            risk: .lock, action: .trash(item: item))
        precondition(!locked.entry.selectable)

        let json = try JSONEncoder().encode(green.entry)
        let decoded = try JSONDecoder().decode(CleanupEntry.self, from: json)
        precondition(decoded == green.entry)
        // 派生同一项时不丢字段：每个 helper 都保留与它无关的元数据
        var rich = green
        rich.entry.category = "cat"; rich.entry.group = "grp"; rich.entry.userProtected = true
        rich.entry.preferenceKey = CleanupPreferenceKey(owner: "o", kind: "path", scope: "s")
        rich.entry.lockReason = "lr"; rich.entry.safetyHold = true; rich.entry.tierReason = "tr"
        for derived in [rich.retiered(.rebuildable, reason: "r").entry, rich.withSize(7).entry,
                        rich.requiringReview("why").entry, rich.locked("lk").entry] {
            precondition(derived.category == "cat" && derived.group == "grp" && derived.userProtected == true
                && derived.preferenceKey == rich.entry.preferenceKey && derived.safetyHold == true
                && derived.path == rich.entry.path && derived.id == rich.entry.id, "\(derived)")
        }
        print("CleanupTypesTests passed")
    }
}
