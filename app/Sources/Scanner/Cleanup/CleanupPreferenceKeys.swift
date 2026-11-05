// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit tool/content mapping. Unknown evidence never becomes a learning category.
enum CleanupPreferenceKeys {
    static func forRule(_ item: ScanItem) -> CleanupPreferenceKey? {
        guard item.risk != .lock else { return nil }
        // 同一个对象不管工具在不在、走哪种动作，都用同一个键
        if let command = OwnerCachePolicy.command(for: item) { return forTool(command, scope: item.path) }
        let owner: String
        let scope: String
        let kind: String
        switch item.rule {
        case "npm 下载缓存":
            owner = "npm"; kind = "npmCache"
            guard let range = item.path.range(of: "/content-v2/sha512/", options: .backwards) else { return nil }
            scope = String(item.path[..<range.lowerBound])
        case "Go 构建缓存", "Go 生成缓存":
            owner = "go"; kind = "goBuildCache"
            scope = item.rule == "Go 生成缓存" ? URL(fileURLWithPath: item.path).deletingLastPathComponent().path : item.path
        case "Gradle 下载缓存":
            guard let range = item.path.range(of: "/modules-2/files-2.1/", options: .backwards) else { return nil }
            owner = "gradle"; kind = "gradleDownload"
            scope = String(item.path[..<range.lowerBound])
        case "Flutter 编译快照":
            owner = "flutter"; kind = "flutterKernel"
            guard let range = item.path.range(of: "/.dart_tool/flutter_build/", options: .backwards) else { return nil }
            scope = String(item.path[..<range.lowerBound])
        case "Rust 增量缓存":
            owner = "rust"; kind = "rustIncremental"
            guard let range = item.path.range(of: "/target/", options: .backwards) else { return nil }
            scope = String(item.path[..<range.lowerBound])
        case "Xcode 生成缓存":
            owner = "xcode"; kind = "xcodeGenerated"
            guard let range = item.path.range(of: "/Build/Intermediates.noindex", options: .backwards) else { return nil }
            scope = String(item.path[..<range.lowerBound])
        default: return nil
        }
        return CleanupPreferenceKey(owner: owner, kind: kind, scope: CleanupPreferenceKey.digest(scope))
    }

    /// Rules whose trash rows are caches or temporary leftovers that tools recreate.
    private static let cacheRules: Set<String> = [
        "Xcode DerivedData", "XcodeBuildMCP 工作区", "Gradle 缓存", "安装临时目录", "项目缓存目录",
        "Playwright 旧版本浏览器", OwnerCachePolicy.npxRule, GradleWrapperProbe.rule,
        "包管理器缓存", "pnpm 元数据缓存", "Python 字节码缓存",
    ]

    static func forTool(_ command: ToolCleanCommand, scope: String) -> CleanupPreferenceKey {
        CleanupPreferenceKey(owner: "tool:" + command.rawValue, kind: "tool-cache", scope: CleanupPreferenceKey.digest(scope))
    }

    /// Key used to move a category between tiers. Rows without a stable identity (and locked rows, which
    /// have no action) stay keyless and cannot be overridden.
    static func forCandidate(_ c: CleanupCandidate) -> CleanupPreferenceKey? {
        func key(_ owner: String, _ kind: String, _ scope: String) -> CleanupPreferenceKey {
            CleanupPreferenceKey(owner: owner, kind: kind, scope: CleanupPreferenceKey.digest(scope))
        }
        switch c.action {
        case .toolClean(let command, let scope)?:
            return forTool(command, scope: scope)
        case .dockerRemove(let kind, let id, let expectedID)?:
            switch kind {
            case .volume: return key("docker", "volume", id)
            case .image: return key("docker", "image", imageRepository(ref: id, expectedID: expectedID))
            // DockerProbe sets the container key from the container name; the id is only a fallback.
            case .container: return key("docker", "container", id)
            }
        case .trash(let item)?:
            if let command = OwnerCachePolicy.command(for: item) { return forTool(command, scope: item.path) }
            if ProjectArtifactPolicy.rules.contains(item.rule) {
                return key(item.rule, "project-artifact", ProjectArtifactPolicy.projectDirectory(of: item.path))
            }
            if cacheRules.contains(item.rule) { return key(item.rule, "cache", item.path) }
            if c.entry.tier == .review { return key(item.rule, "path", item.path) }
            return nil
        default:
            return nil
        }
    }

    /// `repo:tag` → `repo` (a registry port such as `host:5000/app` is not a tag); an image id → `<none>`.
    static func imageRepository(ref: String, expectedID: String?) -> String {
        let bare = ref.hasPrefix("sha256:") ? String(ref.dropFirst(7)) : ref
        let isID = ref == expectedID || (bare.count >= 12 && bare.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        if isID { return "<none>" }
        var name = ref
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.lastIndex(of: ":"), !name[colon...].contains("/") { name = String(name[..<colon]) }
        return name
    }
}
