// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Literal container IDs and cache leaves only; never recurse through account,
/// messaging, media or website storage to search for cache-like names.
enum SandboxCachePaths {
    static let supportedIDs: Set<String> = ["com.tencent.xinWeChat", "net.whatsapp.WhatsApp", "com.microsoft.teams2"]
    static let permissionHint = "请在系统设置 → 隐私与安全性中检查应用数据访问或完全磁盘访问权限：界面使用腾地儿（Roomy），命令行使用启动 roomy 的终端；授权并重新打开后再扫描。"

    static func discover(library: String, id: String, notices: inout [String]) -> [(path: String, profile: String)] {
        guard supportedIDs.contains(id) else { return [] }
        let container = library + "/Containers/" + id + "/Data/Library"
        let roots = id == "com.microsoft.teams2"
            ? [container, library + "/Group Containers/UBF8T346G9.com.microsoft.teams/Library"] : [container]
        var targets: [(path: String, profile: String)] = []
        func entries(_ path: String) -> [DirEntry] {
            let start = notices.count
            let result = ApplicationAssociations.entries(path, notices: &notices)
            if notices.count > start {
                // A failed read is not an empty directory or a zero-size cache.
                notices.replaceSubrange(start..., with: ["沙盒缓存未能完整扫描，目录不可安全读取或权限不足：\(path)。" + permissionHint])
            }
            return result
        }
        func leaf(_ parent: String, _ name: String, _ label: String) {
            guard let entry = entries(parent).first(where: { $0.name == name }) else { return }
            guard entry.isDir && !entry.isLink else { notices.append("缓存目录类型不符或为符号链接，已保留：\(parent)/\(name)"); return }
            targets.append((parent + "/" + name, label))
        }
        for (index, root) in roots.enumerated() {
            let label = index == 0 ? "应用沙盒" : "Teams 专用组"
            let caches = root + "/Caches", children = entries(caches)
            if let named = children.first(where: { $0.name == id }) {
                let path = caches + "/" + id
                if named.isDir && !named.isLink {
                    let family = entries(path)
                    let files: Set<String> = ["Cache.db", "Cache.db-wal", "Cache.db-shm", "Cache.db-journal"]
                    let recognized = family.contains { $0.name == "Cache.db" && $0.isFile && !$0.isLink } &&
                        family.allSatisfy { !$0.isLink && (files.contains($0.name) ? $0.isFile : ($0.name == "fsCachedData" && $0.isDir)) }
                    if recognized { targets.append((path, label + " · 网络响应缓存")) }
                    else if !family.isEmpty { notices.append("网络缓存目录包含未确认的内容或结构，整组保留：\(path)") }
                } else { notices.append("网络缓存目录类型不符或为符号链接，已保留：\(path)") }
            }
            // WebKit's default sandbox cache path. ServiceWorkers, MediaCache,
            // HSTS and all WebsiteData are intentionally outside this scope.
            if children.contains(where: { $0.name == "WebKit" && $0.isDir && !$0.isLink }) {
                leaf(caches + "/WebKit", "NetworkCache", label + " · WebKit 网络缓存")
            } else if children.contains(where: { $0.name == "WebKit" }) {
                notices.append("WebKit 缓存父目录类型不符或为符号链接，已保留：\(caches)/WebKit")
            }
            let other = children.filter { ![id, "WebKit"].contains($0.name) }
            if !other.isEmpty { notices.append("其他沙盒缓存尚未确认用途，已保留；聊天附件与离线内容不计入可处理空间：\(caches)") }
            if id == "com.microsoft.teams2" {
                let webview = root + "/Application Support/Microsoft/MSTeams/EBWebView"
                for profile in entries(webview) {
                    let standard = ["Default", "WV2Profile_tfw", "Guest Profile", "System Profile"].contains(profile.name) ||
                        profile.name.range(of: #"^Profile [0-9]+$"#, options: .regularExpression) != nil
                    guard profile.isDir, !profile.isLink, standard else {
                        if profile.isDir || profile.isLink { notices.append("未识别或链接的 Teams WebView 配置未扫描，已保留：\(webview)/\(profile.name)") }
                        continue
                    }
                    let parent = webview + "/" + profile.name
                    let children = entries(parent)
                    for entry in children where ["Cache", "Code Cache", "GPUCache"].contains(entry.name) {
                        guard entry.isDir && !entry.isLink else { notices.append("Teams 缓存类型不符或为符号链接，已保留：\(parent)/\(entry.name)"); continue }
                        targets.append((parent + "/" + entry.name, label + " · WebView2 " + profile.name))
                    }
                }
            }
        }
        if targets.isEmpty && notices.isEmpty {
            notices.append("已检查支持的沙盒缓存位置，未发现可列出的标准缓存；这不代表应用总占用为零。聊天记录、附件及未确认的缓存保留。")
        }
        return targets
    }

    static func externalHelperRunning(id: String, paths: [String]) -> Bool {
        id == "com.microsoft.teams2" && paths.contains {
            $0.hasPrefix("/Library/Application Support/Microsoft/WebView2/Microsoft Teams WebView.app/")
        }
    }
}
