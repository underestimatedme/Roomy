// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

struct PermissionLocation: Codable {
    let appID: String
    let title: String
    let path: String
    let state: String
    let detail: String
}

enum PermissionDiagnostics {
    static func directoryState(_ path: String) -> String {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return "unsafe" }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return "error" }
        for part in path.split(separator: "/") {
            var st = stat()
            if fstatat(fd, String(part), &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT != S_IFDIR {
                close(fd); return "unsafe"
            }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else {
                switch code {
                case EACCES, EPERM: return "denied"
                case ENOENT: return "missing"
                case ELOOP, ENOTDIR: return "unsafe"
                default: return "error"
                }
            }
            fd = next
        }
        close(fd); return "readable"
    }
    static func inspect(home: String, installedIDs: Set<String>) -> [PermissionLocation] {
        let apps = [("com.tencent.xinWeChat", "微信"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.microsoft.teams2", "Microsoft Teams")]
        let details = ["readable": "可以读取此目录；缓存内部的完整性仍在扫描时核查。",
                       "denied": "macOS 尚未允许读取。请检查应用数据访问或完全磁盘访问权限，重新打开 Roomy 后再检查。",
                       "missing": "未发现这个标准目录；不代表应用占用为零。",
                       "unsafe": "路径包含符号链接或类型不符，保留其内容。", "error": "读取失败，请重试；未统计不代表零占用。"]
        return apps.filter { installedIDs.contains($0.0) }.flatMap { id, title in
            var paths = [home + "/Library/Containers/" + id + "/Data/Library/Caches"]
            if id == "com.microsoft.teams2" {
                paths += [home + "/Library/Containers/" + id + "/Data/Library/Application Support/Microsoft/MSTeams/EBWebView",
                          home + "/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library"]
            }
            return paths.map { path in
                let state = directoryState(path)
                return PermissionLocation(appID: id, title: title, path: path, state: state, detail: details[state]!)
            }
        }
    }
}
