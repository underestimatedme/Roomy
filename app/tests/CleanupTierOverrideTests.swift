// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func check(_ value: Bool, _ message: String = "", line: UInt = #line) {
    precondition(value, "line \(line): \(message)")
}

@main struct CleanupTierOverrideTests {
    static func tempStore() throws -> (CleanupPreferenceStore, URL) {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("roomy-tier-overrides-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (CleanupPreferenceStore(directory: root), root)
    }

    static func entry(_ id: String, key: CleanupPreferenceKey?, tier: CleanupTier) -> CleanupEntry {
        let selectable = tier != .locked
        var e = CleanupEntry(id: id, title: id, size: 10, estimateIsApprox: false, evidence: "fixture", actionLabel: "进废纸篓",
            reversible: true, risk: .amber, selectable: selectable, defaultChecked: tier == .obsolete && selectable, source: "rule")
        e.tier = tier; e.tierReason = "出厂"; e.preferenceKey = key
        return e
    }

    static func main() throws {
        let key = CleanupPreferenceKey(owner: "Maven 仓库", kind: "path", scope: CleanupPreferenceKey.digest("/fixture/.m2"))
        let other = CleanupPreferenceKey(owner: "Maven 仓库", kind: "path", scope: CleanupPreferenceKey.digest("/fixture/other"))
        let now = Date()

        // manualOverrideApplies
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "我自己定的", now: now)
            let snap = try store.snapshot(now: now)
            check(snap.schema == 2 && snap.overrides.count == 1 && snap.tierHistory.count == 1)
            let out = CleanupTierOverrides.apply([entry("a", key: key, tier: .review), entry("b", key: other, tier: .review),
                                                  entry("c", key: nil, tier: .review)], overrides: snap.overrides)
            check(out[0].tier == .obsolete && out[0].defaultChecked && out[0].tierReason == "你调整过")
            check(out[1].tier == .review && !out[1].defaultChecked && out[1].tierReason == "出厂", "other key untouched")
            check(out[2].tier == .review, "keyless untouched")
            var protected = entry("p", key: key, tier: .review); protected.userProtected = true
            check(CleanupTierOverrides.apply([protected], overrides: snap.overrides)[0].defaultChecked == false, "protected is never default-checked")
            var unselectable = entry("u", key: key, tier: .review); unselectable.selectable = false
            check(CleanupTierOverrides.apply([unselectable], overrides: snap.overrides)[0].defaultChecked == false)
            // moving to B/C never checks
            try store.setTier(key: key, tier: .rebuildable, from: .review, origin: .manual, reason: "x", now: now)
            let b = CleanupTierOverrides.apply([entry("a", key: key, tier: .obsolete)], overrides: try store.snapshot(now: now).overrides)[0]
            check(b.tier == .rebuildable && !b.defaultChecked)
            // learned wording
            try store.setTier(key: other, tier: .rebuildable, from: .review, origin: .learned, reason: "你清过 3 次", now: now)
            let l = CleanupTierOverrides.apply([entry("b", key: other, tier: .review)], overrides: try store.snapshot(now: now).overrides)[0]
            check(l.tierReason == "Roomy 按你的习惯调整：你清过 3 次", l.tierReason ?? "nil")
        }

        // learnedACapsIrreversible
        do {
            let learnedA = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .rebuildable, origin: .learned,
                                               reason: "近 90 天你在 3 个不同日期清理过同类内容", at: now)
            let irreversible = entry("t", key: key, tier: .rebuildable)
            let toolRow = CleanupEntry(id: "t", title: "t", size: 10, estimateIsApprox: false, evidence: "fixture",
                actionLabel: "npm cache clean --force", reversible: false, risk: .amber, selectable: true, defaultChecked: false, source: "tool")
            var tool = toolRow; tool.tier = irreversible.tier; tool.preferenceKey = key
            let capped = CleanupTierOverrides.apply([tool], overrides: [learnedA])[0]
            check(capped.tier == .rebuildable && !capped.defaultChecked, "learned A never makes irreversible rows A")
            check(capped.tierReason?.contains("找不回的内容最多自动调到可选清") == true, capped.tierReason ?? "nil")
            let reversibleRow = CleanupTierOverrides.apply([entry("r", key: key, tier: .rebuildable)], overrides: [learnedA])[0]
            check(reversibleRow.tier == .obsolete && reversibleRow.defaultChecked)
            let manualA = CleanupTierOverride(key: key, tier: .obsolete, fromTier: .rebuildable, origin: .manual, reason: "r", at: now)
            let manual = CleanupTierOverrides.apply([tool], overrides: [manualA])[0]
            check(manual.tier == .obsolete && manual.defaultChecked && manual.tierReason == "你调整过", "manual A is the user's call")
        }

        // lockedBeatsOverride
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "r", now: now)
            var locked = entry("l", key: key, tier: .locked); locked.lockReason = "正在运行"
            let out = CleanupTierOverrides.apply([locked], overrides: try store.snapshot(now: now).overrides)[0]
            check(out == locked, "locked entry is unchanged")
            check(try store.snapshot(now: now).overrides.count == 1, "override record is kept")
            // and via decorate, with learning off
            try store.setEnabled(false)
            let learning = CleanupPreferenceLearning(store: store, source: .gui)
            let decorated = learning.decorate([locked, entry("a", key: key, tier: .review)])
            check(decorated[0].tier == .locked && decorated[1].tier == .obsolete && decorated[1].defaultChecked,
                  "overrides apply through decorate even when learning is off")
            check(learning.warnings.isEmpty)
        }

        // undoManualRestoresFactory
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "r", now: now)
            try store.undoOverride(keyID: key.id, now: now)
            let snap = try store.snapshot(now: now)
            check(snap.overrides.isEmpty && snap.tierHistory.count == 2)
            let e = entry("a", key: key, tier: .review)
            check(CleanupTierOverrides.apply([e], overrides: snap.overrides) == [e], "back to factory")
            try store.undoOverride(keyID: "missing", now: now)   // no-op
            check(try store.snapshot(now: now).tierHistory.count == 2)
        }

        // undoLearnedPinsFromTier
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try store.setTier(key: key, tier: .rebuildable, from: .review, origin: .learned, reason: "习惯", now: now)
            try store.undoOverride(keyID: key.id, now: now)
            let snap = try store.snapshot(now: now)
            check(snap.overrides.count == 1 && snap.overrides[0].origin == .manual && snap.overrides[0].tier == .review)
            let out = CleanupTierOverrides.apply([entry("a", key: key, tier: .review)], overrides: snap.overrides)[0]
            check(out.tier == .review && out.tierReason == "你调整过")
            // a later learned suggestion must not replace the manual pin
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .learned, reason: "again", now: now)
            check(try store.snapshot(now: now).overrides[0].origin == .manual)
        }

        // resetKeepsManual
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "m", now: now)
            try store.setTier(key: other, tier: .rebuildable, from: .review, origin: .learned, reason: "l", now: now)
            try store.reset()
            let snap = try store.snapshot(now: now)
            check(snap.overrides.map(\.keyID) == [key.id], "reset drops learned, keeps manual")
            check(snap.tierHistory.allSatisfy { $0.origin == .manual })
            try store.setTier(key: other, tier: .rebuildable, from: .review, origin: .learned, reason: "l", now: now)
            try store.resetManualOverrides()
            check(try store.snapshot(now: now).overrides.map(\.keyID) == [other.id], "resetManual drops manual only")
        }

        // history cap, locked is not a valid target
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            for i in 0..<520 {
                let k = CleanupPreferenceKey(owner: "o", kind: "k", scope: "s\(i)")
                try store.setTier(key: k, tier: .obsolete, from: .review, origin: .manual, reason: "r", now: now.addingTimeInterval(Double(i)))
            }
            let snap = try store.snapshot(now: now)
            check(snap.tierHistory.count == 500 && snap.overrides.count == 520)
            check(snap.tierHistory.last?.key.scope == "s519", "newest history is kept")
            var threw = false
            do { try store.setTier(key: key, tier: .locked, from: .review, origin: .manual, reason: "r") } catch { threw = true }
            check(threw, "cannot override into locked")
        }

        // schema1Reads
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("cleanup-preferences.json")
            try Data(#"{"schema":1,"generation":"g1","enabled":true,"events":[]}"#.utf8).write(to: file)
            let snap = try store.snapshot(now: now)
            check(snap.overrides.isEmpty && snap.tierHistory.isEmpty && snap.generation == "g1")
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "r", now: now)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            check(raw?["schema"] as? Int == 2, "next write upgrades to schema 2")
            check(try store.snapshot(now: now).generation == "g1")
            try Data(#"{"schema":3,"generation":"g","enabled":true,"events":[],"overrides":[],"tierHistory":[]}"#.utf8).write(to: file)
            var threw = false
            do { _ = try store.snapshot(now: now) } catch { threw = true }
            check(threw, "unknown newer schema still disables preferences")
        }

        // key derivation
        func volume(_ name: String) -> CleanupCandidate {
            CleanupCandidate(source: "docker", key: "volume:" + name, title: name, size: 1, evidence: "e", risk: .amber,
                             action: .dockerRemove(kind: .volume, id: name), tier: .review)
        }
        let v1 = CleanupPreferenceKeys.forCandidate(volume("pgdata")), v2 = CleanupPreferenceKeys.forCandidate(volume("redis"))
        check(v1 != nil && v2 != nil && v1?.id != v2?.id, "docker volume key is per name")
        check(v1?.owner == "docker" && v1?.kind == "volume" && v1?.scope == CleanupPreferenceKey.digest("pgdata"))
        func image(_ ref: String, expected: String? = nil) -> CleanupPreferenceKey? {
            CleanupPreferenceKeys.forCandidate(CleanupCandidate(source: "docker", key: ref, title: ref, size: 1, evidence: "e",
                risk: .amber, action: .dockerRemove(kind: .image, id: ref, expectedID: expected), tier: .review))
        }
        check(image("web:1")?.id == image("web:2")?.id, "tags of one repository share a key")
        check(image("web:1")?.scope == CleanupPreferenceKey.digest("web") && image("web:1")?.kind == "image")
        check(image("localhost:5000/team/web:9")?.scope == CleanupPreferenceKey.digest("localhost:5000/team/web"))
        check(image("web:1")?.id != image("api:1")?.id)
        let dangling = "sha256:" + String(repeating: "a", count: 64)
        check(image(dangling, expected: dangling)?.scope == CleanupPreferenceKey.digest("<none>"))
        let container = CleanupPreferenceKeys.forCandidate(CleanupCandidate(source: "docker", key: "container:abc", title: "c", size: 1,
            evidence: "e", risk: .amber, action: .dockerRemove(kind: .container, id: "abc"), tier: .review))
        check(container?.owner == "docker" && container?.kind == "container", "container falls back to the id when no name is known")
        let tool = CleanupPreferenceKeys.forCandidate(CleanupCandidate(source: "rule", key: "npm", title: "npm", size: 1, evidence: "e",
            risk: .amber, action: .toolClean(.npmCache, scope: "/fixture/.npm/_cacache"), tier: .obsolete))
        check(tool?.owner == "tool:npmCache" && tool?.kind == "tool-cache" && tool?.scope == CleanupPreferenceKey.digest("/fixture/.npm/_cacache"))
        func trash(_ rule: String, _ path: String, tier: CleanupTier) -> CleanupPreferenceKey? {
            let item = ScanItem.trashTarget(path: path, name: "x", size: 1, rule: rule, evidence: "e", risk: .amber)
            return CleanupPreferenceKeys.forCandidate(CleanupCandidate(source: "rule", key: path, title: rule, size: 1, evidence: "e",
                risk: .amber, action: .trash(item: item), tier: tier))
        }
        let cache = trash("Xcode DerivedData", "/fixture/DerivedData", tier: .obsolete)
        check(cache?.owner == "Xcode DerivedData" && cache?.kind == "cache" && cache?.scope == CleanupPreferenceKey.digest("/fixture/DerivedData"))
        check(trash("Maven 仓库", "/fixture/.m2/repository", tier: .review)?.kind == "path")
        check(trash("Android SDK 副本", "/fixture/sdk", tier: .review)?.kind == "path")
        let repo = URL(fileURLWithPath: "/private/tmp/roomy-tier-repo-\(UUID())")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let nm1 = trash("node_modules", repo.path + "/node_modules", tier: .rebuildable)
        let nm2 = trash("node_modules", repo.path + "/packages/a/node_modules", tier: .rebuildable)
        check(nm1?.kind == "project-artifact" && nm1?.scope == CleanupPreferenceKey.digest(repo.path))
        check(nm1?.id == nm2?.id, "artifacts of one repository share a key")
        let wt = CleanupPreferenceKeys.forCandidate(CleanupCandidate(source: "rule", key: "w", title: "w", size: 1, evidence: "e", risk: .amber,
            action: .ollamaRemove(model: "m"), tier: .review))
        check(wt == nil, "unmapped actions stay keyless")
        check(CleanupPreferenceKeys.forCandidate(CleanupCandidate(source: "x", key: "k", title: "t", size: 0, evidence: "e", risk: .amber,
            action: nil)) == nil)

        // CleanupListBuilder assigns keys to keyless candidates and keeps existing ones
        do {
            let maven = ScanItem.trashTarget(path: "/private/tmp/roomy-tier-m2/repository", name: "repository", size: 1000,
                rule: "Maven 仓库", evidence: "e", risk: .amber)
            let list = CleanupListBuilder.build(items: [maven], probes: [])
            let c = list.candidates.first { $0.entry.group == "Maven 仓库" }
            check(c?.entry.preferenceKey?.owner == "Maven 仓库" && c?.entry.preferenceKey?.kind == "path")
            var preset = CleanupCandidate(source: "docker", key: "volume:x", title: "x", size: 1, evidence: "e", risk: .amber,
                action: .dockerRemove(kind: .volume, id: "x"), tier: .review)
            let own = CleanupPreferenceKey(owner: "mine", kind: "k", scope: "s")
            preset.entry.preferenceKey = own
            let list2 = CleanupListBuilder.build(items: [], probes: [preset])
            check(list2.candidates.first?.entry.preferenceKey == own, "an existing key is not replaced")
        }

        // DockerProbe keys containers by name
        let inv = DockerInventory(volumes: [], images: [], containers: [
            .init(id: "c1", name: "db-1", state: "exited", size: 1, volumes: [])], buildCacheReclaimable: 0, builders: [])
        let dc = DockerProbe.candidates(inv).first
        check(dc?.entry.preferenceKey?.kind == "container" && dc?.entry.preferenceKey?.scope == CleanupPreferenceKey.digest("db-1"))

        // Fix 1: safety downgrades cannot be raised by an override (the record is kept)
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .manual, reason: "r", now: now)
            let overrides = try store.snapshot(now: now).overrides
            var base = CleanupCandidate(source: "rule", key: "k", title: "t", size: 10, evidence: "e", risk: .amber,
                action: .trash(item: .trashTarget(path: "/fixture/k", name: "k", size: 10, rule: "Maven 仓库", evidence: "e", risk: .amber)),
                tier: .review)
            base.entry.preferenceKey = key
            let plain = base.retiered(.rebuildable, reason: "出厂")
            let held = plain.requiringReview("被后台服务 X 使用")
            check(held.entry.tier == .review && held.entry.preferenceKey == key)
            let raised = CleanupTierOverrides.apply([plain.entry, held.entry], overrides: overrides)
            check(raised[0].tier == .obsolete && raised[0].defaultChecked, "without the downgrade the override applies")
            check(raised[1].tier == .review && !raised[1].defaultChecked && raised[1] == held.entry, "a safety-downgraded row stays C")
            check(held.retiered(.rebuildable, reason: "x").entry.safetyHold == true, "retiering keeps the hold")
            check(held.withSize(20).entry.safetyHold == true, "resizing keeps the hold")
            var list = CleanupList(); var xcode = base; xcode.entry.group = "Xcode DerivedData"; xcode.entry.tier = .obsolete; list.candidates = [xcode]
            let unverified = RunningOwners.markUnverified(list).candidates[0].entry
            check(unverified.safetyHold == true && unverified.tier == .review, "markUnverified marks the hold")
            check(CleanupTierOverrides.apply([unverified], overrides: overrides)[0].tier == .review)
        }

        // Fix 2: learned writes respect enabled and generation
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            let gen = try store.snapshot(now: now).generation
            try store.setTier(key: key, tier: .rebuildable, from: .review, origin: .learned, reason: "l", now: now, expectedGeneration: gen)
            check(try store.snapshot(now: now).overrides.count == 1)
            try store.setEnabled(false)
            let off = try store.snapshot(now: now).generation
            try store.setTier(key: other, tier: .rebuildable, from: .review, origin: .learned, reason: "l", now: now, expectedGeneration: off)
            check(try store.snapshot(now: now).overrides.count == 1, "disabled learning writes nothing")
            try store.setTier(key: other, tier: .rebuildable, from: .review, origin: .manual, reason: "m", now: now)
            check(try store.snapshot(now: now).overrides.count == 2, "manual writes work while learning is off")
            try store.setEnabled(true)
            try store.setTier(key: CleanupPreferenceKey(owner: "o", kind: "k", scope: "late"), tier: .obsolete, from: .review,
                              origin: .learned, reason: "l", now: now, expectedGeneration: off)
            check(try store.snapshot(now: now).overrides.count == 2, "a stale generation is dropped")
            try store.reset()
            try store.setTier(key: key, tier: .obsolete, from: .review, origin: .learned, reason: "l", now: now, expectedGeneration: gen)
            check(try store.snapshot(now: now).overrides.map(\.keyID) == [other.id], "a write racing reset is fenced")
        }

        // Fix 3: unreadable overrides fail closed
        do {
            let (store, root) = try tempStore(); defer { try? FileManager.default.removeItem(at: root) }
            try Data("broken".utf8).write(to: root.appendingPathComponent("cleanup-preferences.json"))
            let learning = CleanupPreferenceLearning(store: store, source: .gui)
            let a = entry("a", key: key, tier: .obsolete), b = entry("b", key: nil, tier: .obsolete)
            check(a.defaultChecked && b.defaultChecked)
            let out = learning.decorate([a, b])
            check(out.map(\.tier) == [.obsolete, .obsolete], "factory tiers are shown")
            check(out.allSatisfy { !$0.defaultChecked }, "nothing is default-checked when overrides cannot be read")
            check(learning.warnings.contains("档位调整记录暂时无法读取，本次不默认勾选"))
            // invalid override records get their own message
            let (bad, badRoot) = try tempStore(); defer { try? FileManager.default.removeItem(at: badRoot) }
            let dupe = #"{"key":{"owner":"o","kind":"k","scope":"s"},"tier":"obsolete","fromTier":"review","origin":"manual","reason":"r","at":0}"#
            try Data(#"{"schema":2,"generation":"g","enabled":true,"events":[],"overrides":[\#(dupe),\#(dupe)],"tierHistory":[]}"#.utf8)
                .write(to: badRoot.appendingPathComponent("cleanup-preferences.json"))
            do { _ = try bad.snapshot(); check(false, "duplicate overrides must be rejected") }
            catch { check(error.localizedDescription.contains("档位调整记录异常"), error.localizedDescription) }
            let healthy = CleanupPreferenceLearning(store: try tempStore().0, source: .gui)
            check(healthy.decorate([a])[0].defaultChecked && healthy.warnings.isEmpty)
        }

        // Fix 4: one key per object, with or without the tool
        do {
            let goPath = "/private/tmp/roomy-tier-go/go-build"
            let item = ScanItem.trashTarget(path: goPath, name: "go-build", size: 100, rule: "Go 构建缓存", evidence: "e", risk: .amber)
            let withTool = OwnerCachePolicy.candidates(for: item, context: .init(scopes: [.goBuildCache: goPath], running: RunningOwners(commands: []), now: now))!
            let without = OwnerCachePolicy.candidates(for: item, context: .init(scopes: [:], running: nil, now: now))!
            check(withTool[0].action.map { if case .toolClean = $0 { return true } else { return false } } == true)
            check(without[0].action.map { if case .trash = $0 { return true } else { return false } } == true)
            check(withTool[0].entry.preferenceKey != nil && withTool[0].entry.preferenceKey?.id == without[0].entry.preferenceKey?.id,
                  "toolClean row and trash fallback share one key")
            check(CleanupPreferenceKeys.forRule(item)?.id == withTool[0].entry.preferenceKey?.id, "legacy path agrees")
            check(withTool[0].entry.preferenceKey?.owner == "tool:goBuildCache" && withTool[0].entry.preferenceKey?.kind == "tool-cache")
        }

        // Cheap extras: learned evicted before manual; dangling vs tagged-elsewhere images
        do {
            func record(_ scope: String, _ origin: CleanupTierOverride.Origin) -> CleanupTierOverride {
                .init(key: .init(owner: "o", kind: "k", scope: scope), tier: .obsolete, fromTier: .review, origin: origin, reason: "r", at: now)
            }
            let trimmed = CleanupPreferenceStore.trimmed([record("m1", .manual), record("l1", .learned), record("m2", .manual), record("l2", .learned)], limit: 3)
            check(trimmed.map(\.key.scope) == ["m1", "m2", "l2"], "oldest learned goes first")
            check(CleanupPreferenceStore.trimmed([record("m1", .manual), record("m2", .manual), record("m3", .manual)], limit: 2).map(\.key.scope) == ["m2", "m3"])
            let shared = "sha256:" + String(repeating: "b", count: 64), gone = "sha256:" + String(repeating: "c", count: 64)
            let day = Date()
            let imgInv = DockerInventory(volumes: [], images: [
                .init(id: shared, repository: "web", tag: "1", size: 1, createdAt: day, usedBy: 0),
                .init(id: shared, repository: "<none>", tag: "<none>", size: 1, createdAt: day, usedBy: 0),
                .init(id: gone, repository: "<none>", tag: "<none>", size: 1, createdAt: day, usedBy: 0)],
                containers: [], buildCacheReclaimable: 0, builders: [])
            let rows = DockerProbe.candidates(imgInv)
            func scope(_ id: String) -> String? {
                rows.first { if case .dockerRemove(.image, let ref, _)? = $0.action { return ref == id }; return false }
                    .flatMap { $0.entry.preferenceKey ?? CleanupPreferenceKeys.forCandidate($0) }?.scope
            }
            check(scope(gone) == CleanupPreferenceKey.digest("<none>"))
            check(scope(shared) != nil && scope(shared) != scope(gone), "untagged-but-tagged-elsewhere images are keyed apart from dangling ones")
        }
        print("CleanupTierOverrideTests ok")
    }
}
