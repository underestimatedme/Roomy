// SPDX-License-Identifier: MPL-2.0
import Foundation

/// 纯 fixture：只验证首屏缓存的 scannedAt 不会被后续报告字段刷新；不扫描 HOME，不读写真实用户目录。
@main struct CleanupCacheTimestampTests {
    static func main() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-cache-time-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let given = "2026-11-05T08:00:00Z"

        // 1. 初始清单时间：保存后原样读回
        CleanupCache.save(["entries": [], "disk": ["total": 1, "free": 2], "scannedAt": given], to: tmp)
        var loaded = CleanupCache.load(from: tmp)!
        precondition(loaded["scannedAt"] as? String == given, "a supplied timestamp must survive the first save")

        // 2. 深度统计晚到，只更新 overview/health 字段：清单时间不能被刷成统计完成时间
        CleanupCache.save(["entries": [], "disk": ["total": 1, "free": 2], "overview": ["dataUsed": 10],
                           "scannedAt": given], to: tmp)
        loaded = CleanupCache.load(from: tmp)!
        precondition(loaded["scannedAt"] as? String == given, "report fields must not refresh the list timestamp")
        precondition((loaded["overview"] as? [String: Any])?["dataUsed"] as? Int == 10,
                     "the new report field is still written")

        // 3. ReportCache 在内存里只 stamp 一次；再次 stamp 保留原值
        let stamped = CleanupCache.stamped(["entries": []], now: Date(timeIntervalSince1970: 0))
        let again = CleanupCache.stamped(stamped, now: Date(timeIntervalSince1970: 1_000))
        precondition(stamped["scannedAt"] as? String == "1970-01-01T00:00:00Z")
        precondition(again["scannedAt"] as? String == stamped["scannedAt"] as? String,
                     "stamping a valid cache again must keep its original time")

        // 4. 缺失或无效时间才生成；不会留下空值或坏字符串
        let invalid = CleanupCache.stamped(["scannedAt": "not a date"], now: Date(timeIntervalSince1970: 0))
        precondition(invalid["scannedAt"] as? String == "1970-01-01T00:00:00Z")
        let missing = CleanupCache.stamped(["entries": []], now: Date(timeIntervalSince1970: 0))
        precondition(ISO8601DateFormatter().date(from: missing["scannedAt"] as? String ?? "") != nil)

        // 5. 旧版本写下的有效时间原样保留
        CleanupCache.save(["scannedAt": "2026-11-05T09:30:00Z", "version": CleanupCache.version], to: tmp)
        precondition(CleanupCache.load(from: tmp)?["scannedAt"] as? String == "2026-11-05T09:30:00Z")

        print("CleanupCacheTimestampTests passed: supplied list time survives report updates, stamping is idempotent, missing/invalid times are generated")
    }
}
