// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

struct CleanupPreferenceKey: Codable, Equatable, Hashable {
    let owner: String
    let kind: String
    let scope: String
    var id: String { Self.digest(owner + "\u{0}" + kind + "\u{0}" + scope) }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CleanupPreferenceBatch {
    let id: String
    let generation: String
}

struct CleanupPreferenceEvent: Codable, Equatable {
    /// `.declined`: a default-checked A row the user unticked while cleaning other rows (GUI only).
    enum Kind: String, Codable { case deletion, protection, declined }
    let id: String
    let batchID: String
    let candidateID: String
    let title: String
    let path: String?
    let key: CleanupPreferenceKey?
    let kind: Kind
    let at: Date
    let localDay: String
    var revokedAt: Date? = nil
    var restoredAt: Date? = nil
    /// Tier the user saw when acting. Events recorded before tiers existed have none and never move tiers.
    var tier: CleanupTier? = nil
    /// Whether the action could be undone (Trash) or not (tool/Docker removal).
    var reversible: Bool? = nil
    var lastActivityAt: Date { max(at, restoredAt ?? at) }

    static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func deletion(batch: CleanupPreferenceBatch, candidateID: String, title: String,
                         path: String?, key: CleanupPreferenceKey?, at: Date,
                         tier: CleanupTier? = nil, reversible: Bool? = nil) -> Self {
        Self(id: CleanupPreferenceKey.digest(batch.id + "\u{0}" + candidateID), batchID: batch.id,
             candidateID: candidateID, title: title, path: path, key: key, kind: .deletion,
             at: at, localDay: localDay(at), tier: tier, reversible: reversible)
    }

    /// One per key per batch, so several unticked rows of one category count once.
    static func declined(batch: CleanupPreferenceBatch, key: CleanupPreferenceKey, title: String,
                         path: String?, at: Date, candidateID: String = "") -> Self {
        Self(id: CleanupPreferenceKey.digest(batch.id + "\u{0}declined\u{0}" + key.id), batchID: batch.id,
             candidateID: candidateID, title: title, path: path, key: key, kind: .declined,
             at: at, localDay: localDay(at), tier: .obsolete)
    }
}

struct CleanupPreferenceSnapshot: Codable {
    static let currentSchema = 2
    static let historyLimit = 500
    var schema = CleanupPreferenceSnapshot.currentSchema
    var generation = "initial-v1"
    var enabled = true
    var events: [CleanupPreferenceEvent] = []
    var overrides: [CleanupTierOverride] = []
    /// Every set and undo, newest last, capped at `historyLimit`.
    var tierHistory: [CleanupTierOverride] = []

    init() {}

    /// Schema 1 files have no override fields; they read as empty and are upgraded on the next write.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generation = try c.decode(String.self, forKey: .generation)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        events = try c.decode([CleanupPreferenceEvent].self, forKey: .events)
        overrides = try c.decodeIfPresent([CleanupTierOverride].self, forKey: .overrides) ?? []
        tierHistory = try c.decodeIfPresent([CleanupTierOverride].self, forKey: .tierHistory) ?? []
    }
}

struct CleanupPreferenceHint: Codable, Equatable {
    let score: Int
    let reason: String
}

struct CleanupPreferenceRow: Codable {
    let id: String
    let title: String
    let path: String?
    let owner: String?
    let kind: String?
    let cleanupDays: Int
    let lastAt: Date
    let reason: String
}

enum CleanupPreferencePolicy {
    static let retention: TimeInterval = 90 * 86400

    static func current(_ events: [CleanupPreferenceEvent], now: Date) -> [CleanupPreferenceEvent] {
        events.filter { $0.at <= now && $0.lastActivityAt <= now && now.timeIntervalSince($0.lastActivityAt) <= retention }
    }

    private static func summary(_ events: [CleanupPreferenceEvent]) -> (days: Int, kept: Bool) {
        let revokedBatches = Set(events.filter { $0.kind == .deletion && $0.revokedAt != nil }.map(\.batchID))
        let eligible = events.filter { $0.kind == .deletion && $0.revokedAt == nil && !revokedBatches.contains($0.batchID) }
        let batches = Dictionary(grouping: eligible, by: \.batchID)
        let days = Set(batches.values.compactMap { $0.min(by: { $0.at < $1.at })?.localDay }).count
        return (days, events.contains { $0.restoredAt != nil || ($0.kind == .protection && $0.revokedAt == nil) })
    }

    static func hint(key: CleanupPreferenceKey?, snapshot: CleanupPreferenceSnapshot, now: Date = Date()) -> CleanupPreferenceHint? {
        guard snapshot.enabled, let key else { return nil }
        let stats = summary(current(snapshot.events, now: now).filter { $0.key == key })
        if stats.kept { return .init(score: -1, reason: "你曾保留或恢复过同类内容") }
        if stats.days >= 3 { return .init(score: 1, reason: "近 90 天，你在 \(stats.days) 个不同日期清理过同类缓存") }
        return nil
    }

    static func rows(snapshot: CleanupPreferenceSnapshot, now: Date = Date()) -> [CleanupPreferenceRow] {
        // Declined rows are tier signals, not cleanup history.
        let grouped = Dictionary(grouping: current(snapshot.events, now: now).filter { $0.kind != .declined }) { $0.key?.id ?? $0.id }
        return grouped.compactMap { id, events in
            guard let last = events.max(by: { $0.lastActivityAt < $1.lastActivityAt }) else { return nil }
            let stats = summary(events)
            return CleanupPreferenceRow(id: id, title: last.title, path: last.path, owner: last.key?.owner,
                kind: last.key?.kind, cleanupDays: stats.days, lastAt: last.lastActivityAt,
                reason: last.key == nil ? "已记录，暂无同类建议" : !snapshot.enabled ? "学习已关闭，未应用历史偏好" :
                    hint(key: last.key, snapshot: snapshot, now: now)?.reason ?? "样本不足，保持原有建议")
        }.sorted { $0.lastAt == $1.lastAt ? $0.id < $1.id : $0.lastAt > $1.lastAt }
    }
}
