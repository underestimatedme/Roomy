// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Content usefulness is independent of execution risk and recoverability.
enum CleanupTier: String, Codable, CaseIterable {
    case obsolete, rebuildable, review, locked

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CleanupTier(rawValue: raw) ?? .review
    }

    var title: String {
        switch self {
        case .obsolete: return "放心清"
        case .rebuildable: return "可选清"
        case .review: return "确认后清"
        case .locked: return "不能删"
        }
    }
}

struct CleanupTierDecision {
    let tier: CleanupTier
    let reason: String
}

enum CleanupTierPolicy {
    static func forRule(_ item: ScanItem, now: Date = Date()) -> CleanupTierDecision {
        guard item.undo, item.risk != .lock else {
            return .init(tier: .review, reason: item.evidence)
        }
        if item.rule == NpmDependencyEvidence.rule, item.cleanupEvidence?.version == 1, item.cleanupEvidence?.kind == "npmDependency" {
            return .init(tier: .rebuildable, reason: "安装包内容与锁定下载包一致；默认不选，项目使用前须重新安装依赖，可能需要联网与安装脚本")
        }
        if item.rule == "npm 下载缓存", item.cleanupEvidence?.version == 1, item.cleanupEvidence?.kind == "npmCache" {
            return .init(tier: .rebuildable, reason: "npm 内容哈希与完整清单已验证；默认不选，重新下载需要可用的原依赖源")
        }
        if item.rule == "Go 生成缓存", item.cleanupEvidence?.version == 1, item.cleanupEvidence?.kind == "goBuildCache" {
            return .init(tier: .rebuildable, reason: "构建索引格式与生成内容摘要已核验；默认不选，下次构建需要重新编译")
        }
        if item.rule == "Gradle 下载缓存", item.cleanupEvidence?.version == 1, item.cleanupEvidence?.kind == "gradleDownload" {
            return .init(tier: .rebuildable, reason: "Gradle 依赖下载内容与 SHA-1 校验码已核实；默认不选，离线或原仓库不可用时无法重新下载")
        }
        if item.rule == "Flutter 编译快照", item.cleanupEvidence?.version == 1, item.cleanupEvidence?.kind == "flutterKernel" {
            return .init(tier: .rebuildable, reason: "Flutter 编译输出记录、二进制类型与内容哈希已验证；下次运行或构建需要重新编译")
        }
        if item.rule == "Rust 增量缓存", item.cleanupEvidence?.version == 1, item.cleanupEvidence?.kind == "rustIncremental" {
            return .init(tier: .rebuildable, reason: "Cargo 增量缓存布局与全部内容类型已验证；下次构建可能明显变慢")
        }
        if let proof = item.cleanupEvidence, proof.version == 1, proof.kind == "xcodeGenerated",
           let modified = proof.newestModifiedAt {
            if now.timeIntervalSince1970 - Double(modified) > 90 * 86_400 {
                return .init(tier: .obsolete, reason: "已完整核验生成产物，所有内容超过 90 天未修改；执行前仍会复核")
            }
            return .init(tier: .rebuildable, reason: "已完整核验生成产物；再次构建时会生成，可能增加构建时间")
        }
        if item.rule == "Roomy 旧扫描快照" {
            return .init(tier: .obsolete, reason: "当前版本不再读取的旧版扫描索引")
        }
        if item.rule == "iOS DeviceSupport" || item.rule == "XCTest 设备克隆" {
            return .init(tier: .review, reason: "尚未核实设备/版本引用及测试状态；目录修改时间不能证明已长期停用")
        }
        return .init(tier: .review, reason: "尚未验证全部内容已过时或可重新生成；请结合扫描依据核实")
    }
}
