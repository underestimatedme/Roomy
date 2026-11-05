// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

@main struct CLIMaintenanceTests {
    static func main() throws {
        let fm = FileManager.default, temporary = FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporary.hasPrefix("/var/") ? "/private" + temporary : temporary).appendingPathComponent("roomy-cli-maintenance-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let state = root.appendingPathComponent("State"), home = root.appendingPathComponent("Home"), apps = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        var mutations = 0
        func run(_ options: CLIOptions) throws -> CLIResponse {
            var lease: OperationLease?
            defer { withExtendedLifetime(lease) {} }
            return try CLIMaintenance.run(options, home: home.path, stateDirectory: state, applicationRoots: [apps.path], prepareMutation: {
                mutations += 1
                try fm.createDirectory(at: state, withIntermediateDirectories: true)
                lease = try OperationLease.acquire(path: state.appendingPathComponent("operation.lock").path)
            })
        }
        // 已删除的命令不再被解析，帮助里也不再出现
        for removed in ["updates", "startup", "archive"] {
            do { _ = try CLIOptions.parse([removed]); preconditionFailure("\(removed) must be gone") } catch {}
            precondition(!cliHelp.contains("roomy \(removed)"), removed)
        }
        // tier 命令：解析
        let setOptions = try CLIOptions.parse(["tier", "set", "abc", "B", "--apply"])
        expect(setOptions.command == "tier" && setOptions.tierAction == "set" && setOptions.subject == "abc"
               && setOptions.tier == .rebuildable && setOptions.apply, "tier set parses id, tier and apply")
        expect(try CLIOptions.parse(["tier", "set", "abc", "a"]).tier == .obsolete, "tier letters are case-insensitive")
        expect(try CLIOptions.parse(["tier", "set", "abc", "C"]).tier == .review, "C maps to review")
        do { _ = try CLIOptions.parse(["tier", "set", "abc", "D"]); preconditionFailure("tier D accepted") }
        catch { expect(error.localizedDescription == "档位只能是 A、B、C", "tier D reports the allowed letters") }
        do { _ = try CLIOptions.parse(["tier", "set", "abc", "locked"]); preconditionFailure("locked accepted") } catch {}
        let listOptions = try CLIOptions.parse(["tier", "list", "--json"])
        expect(listOptions.tierAction == "list" && listOptions.json == "-" && !listOptions.apply, "tier list parses")
        expect(try CLIOptions.parse(["tier", "undo", "key1", "--apply", "--yes"]).tierAction == "undo", "tier undo parses")
        expect(try CLIOptions.parse(["tier", "reset", "--apply"]).tierAction == "reset", "tier reset parses")
        for bad in [["tier"], ["tier", "list", "--apply"], ["tier", "set", "abc"], ["tier", "undo"], ["tier", "reset", "x"], ["tier", "nope"]] {
            do { _ = try CLIOptions.parse(bad); preconditionFailure("accepted \(bad)") } catch {}
        }

        // tier 命令：列出、预览、撤销、重置（只用临时偏好目录）
        let tierState = root.appendingPathComponent("TierState")
        try fm.createDirectory(at: tierState, withIntermediateDirectories: true)
        let tierStore = CleanupPreferenceStore(directory: tierState)
        let manualKey = CleanupPreferenceKey(owner: "tool:npm", kind: "tool-cache", scope: "a")
        let learnedKey = CleanupPreferenceKey(owner: "go", kind: "goBuildCache", scope: "b")
        try tierStore.setTier(key: manualKey, tier: .obsolete, from: .rebuildable, origin: .manual, reason: "你调整过")
        try tierStore.setTier(key: learnedKey, tier: .rebuildable, from: .review, origin: .learned, reason: "连续清理")
        var prepared = 0, confirmed: [String] = []
        let prepare = { prepared += 1 }, ask: (String) throws -> Void = { confirmed.append($0) }
        let listed = try CLITier.list(store: tierStore)
        let overridesJSON = listed.data["overrides"] as! [[String: Any]]
        expect(overridesJSON.count == 2 && (listed.data["history"] as! [[String: Any]]).count == 2, "list returns overrides and history")
        expect(listed.text.contains(manualKey.id) && listed.text.contains("放心清") && listed.text.contains("Roomy 按你的习惯调整"), "list text shows key, tiers and origin")
        let previewUndo = try CLITier.undo(keyID: manualKey.id, apply: false, store: tierStore, prepare: prepare, confirm: ask)
        expect(previewUndo.data["executionAuthorized"] as? Bool == false && prepared == 0 && confirmed.isEmpty, "undo without apply is preview only")
        expect(try tierStore.snapshot().overrides.count == 2, "preview keeps overrides")
        do { _ = try CLITier.undo(keyID: "missing", apply: true, store: tierStore, prepare: prepare, confirm: ask); preconditionFailure("unknown key undone") } catch {}
        _ = try CLITier.undo(keyID: manualKey.id, apply: true, store: tierStore, prepare: prepare, confirm: ask)
        let afterUndo = try tierStore.snapshot().overrides.map(\.keyID)
        expect(prepared == 1 && confirmed.count == 1 && afterUndo == [learnedKey.id], "undo removes a manual override after confirmation")
        _ = try CLITier.undo(keyID: learnedKey.id, apply: true, store: tierStore, prepare: prepare, confirm: ask)
        let pinned = try tierStore.snapshot().overrides
        expect(pinned.count == 1 && pinned[0].origin == .manual && pinned[0].tier == .review, "undoing a learned override pins the previous tier")
        let previewReset = try CLITier.reset(apply: false, store: tierStore, prepare: prepare, confirm: ask)
        let afterPreviewReset = try tierStore.snapshot().overrides.count
        expect(previewReset.data["executionAuthorized"] as? Bool == false && afterPreviewReset == 1, "reset without apply is preview only")
        _ = try CLITier.reset(apply: true, store: tierStore, prepare: prepare, confirm: ask)
        expect(try tierStore.snapshot().overrides.isEmpty, "reset removes manual overrides")
        let cancelled = CleanupPreferenceStore(directory: tierState)
        try cancelled.setTier(key: manualKey, tier: .obsolete, from: .review, origin: .manual, reason: "你调整过")
        do { _ = try CLITier.reset(apply: true, store: cancelled, prepare: {}, confirm: { _ in throw cliError("已取消") }); preconditionFailure("cancel ignored") } catch {}
        expect(try cancelled.snapshot().overrides.count == 1, "declined confirmation leaves overrides untouched")

        // tier set：只对有键、非锁定的条目生效
        func entry(key: CleanupPreferenceKey?, tier: CleanupTier) -> CleanupEntry {
            var e = CleanupEntry(id: "0123456789abcdef", title: "cache", size: 1, estimateIsApprox: false, evidence: "", actionLabel: "",
                                 reversible: true, risk: .green, selectable: tier != .locked, defaultChecked: false, source: "test")
            e.tier = tier; e.preferenceKey = key; return e
        }
        var held = entry(key: manualKey, tier: .review); held.safetyHold = true
        do { _ = try CLITier.set(entry: held, tier: .obsolete, apply: true, store: CleanupPreferenceStore(directory: root.appendingPathComponent("SetState")), prepare: { preconditionFailure("prepared") }, confirm: { _ in }); preconditionFailure("held set") } catch {
            expect(error.localizedDescription == CleanupTierAdjustments.holdRefusal, "safety-held entry cannot move")
        }
        let setStore = CleanupPreferenceStore(directory: root.appendingPathComponent("SetState"))
        try fm.createDirectory(at: root.appendingPathComponent("SetState"), withIntermediateDirectories: true)
        do { _ = try CLITier.set(entry: entry(key: nil, tier: .review), tier: .obsolete, apply: true, store: setStore, prepare: {}, confirm: { _ in }); preconditionFailure("keyless set") } catch {
            expect(error.localizedDescription.contains("没有可记住的类别"), "keyless entry explains why")
        }
        do { _ = try CLITier.set(entry: entry(key: manualKey, tier: .locked), tier: .obsolete, apply: true, store: setStore, prepare: {}, confirm: { _ in }); preconditionFailure("locked set") } catch {
            expect(error.localizedDescription == "不能删的项目不能换档", "locked entry cannot move")
        }
        do { _ = try CLITier.set(entry: entry(key: manualKey, tier: .review), tier: .locked, apply: true, store: setStore, prepare: {}, confirm: { _ in }); preconditionFailure("locked target") } catch {
            expect(error.localizedDescription == "不能删的项目不能换档", "locked target refused")
        }
        let same = try CLITier.set(entry: entry(key: manualKey, tier: .review), tier: .review, apply: true, store: setStore, prepare: { preconditionFailure("prepared") }, confirm: { _ in preconditionFailure("asked") })
        let afterSame = try setStore.snapshot().overrides.isEmpty
        expect(same.text.contains("已经在这一档") && afterSame, "moving to the shown tier writes nothing")
        let setPreview = try CLITier.set(entry: entry(key: manualKey, tier: .review), tier: .rebuildable, apply: false, store: setStore, prepare: prepare, confirm: ask)
        let afterSetPreview = try setStore.snapshot().overrides.isEmpty
        expect(setPreview.data["executionAuthorized"] as? Bool == false && afterSetPreview, "set without apply is preview only")
        _ = try CLITier.set(entry: entry(key: manualKey, tier: .review), tier: .rebuildable, apply: true, store: setStore, prepare: {}, confirm: { _ in })
        let stored = try setStore.snapshot().overrides
        expect(stored.count == 1 && stored[0].tier == .rebuildable && stored[0].fromTier == .review && stored[0].origin == .manual && stored[0].reason == "你调整过", "set stores a manual override from the shown tier")

        var options = CLIOptions(); options.command = "growth"
        expect(try (run(options).data["reports"] as? [Any])?.isEmpty == true, "history read is empty before scan")
        expect(!fm.fileExists(atPath: state.path) && mutations == 0, "read-only history must not prepare mutation")
        options.command = "permissions"
        expect(try (run(options).data["locations"] as? [Any])?.isEmpty == true, "permission records restricted to installed fixture apps")
        let project = root.appendingPathComponent("Project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("fixture payload".utf8).write(to: project.appendingPathComponent("source.txt"))
        options = CLIOptions(); options.command = "growth"; options.subject = project.path
        let baseline = try run(options)
        expect((baseline.data["report"] as? [String: Any])?["status"] as? String == "baseline", "growth path scans full fixture index")
        options.subject = nil
        expect(try (run(options).data["reports"] as? [Any])?.count == 1, "growth is persisted for later read")
        print("CLIMaintenanceTests passed: readonly inventories, tier commands, removed commands, growth full scan and restart")
    }
}
