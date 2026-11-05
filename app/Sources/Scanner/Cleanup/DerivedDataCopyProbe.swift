// SPDX-License-Identifier: GPL-3.0-only
// xcodebuild -derivedDataPath 指到标准位置之外的构建缓存（info.plist + ModuleCache.noindex + Build 或 Index.noindex）。
// 项目旁边的由 WorkspaceArtifacts 管；这里只看 ~/.local/share、~/.cache 这类工具数据目录。下次构建会重新生成：
// 最近还在构建进 B，30 天没构建进 A；Xcode 或 xcodebuild 在运行时由 RunningOwners 锁定。

import Darwin
import Foundation

enum DerivedDataCopyProbe {
    static let rule = "自定义位置的 DerivedData"
    static let defaultRoots = [HOME + "/.local/share", HOME + "/.cache"]
    static let quietDays = 30
    private static let maxDepth = 3
    private static let directoryLimit = 20_000
    private static let skipped: Set<String> = ["node_modules", ".git"]

    static func candidates(searchRoots: [String] = defaultRoots, now: Date = Date(),
                           sizeOf: ((String) -> UInt64?)? = nil) -> [CleanupCandidate] {
        var found: [String] = [], visited = 0
        for root in searchRoots {
            var stack = [(root, 0)]
            while let (dir, depth) = stack.popLast() {
                guard visited < directoryLimit else { break }
                visited += 1
                if hasLayout(dir) { found.append(dir); continue }
                guard depth < maxDepth, let children = try? readDir(dir) else { continue }
                for child in children where child.isDir && !skipped.contains(child.name) {
                    stack.append((dir + "/" + child.name, depth + 1))
                }
            }
        }
        found.sort()
        let sizes = sizeOf == nil ? BulkWalker().measureTargets(found) : [:]
        return found.map { path in
            let size = sizeOf?(path) ?? sizes[path] ?? 0
            let days = newestModification(path).map { max(0, Int(now.timeIntervalSince1970 - $0) / 86_400) } ?? 0
            let item = ScanItem.trashTarget(path: path, name: (path as NSString).lastPathComponent, size: size, rule: rule,
                                            evidence: "Xcode 构建缓存（自定义位置），下次构建会重新生成", risk: .amber)
            let shown = path.hasPrefix(HOME + "/") ? "~" + path.dropFirst(HOME.count) : path
            let candidate = OwnerCachePolicy.ownedCandidate(item, title: rule + " · " + shown, role: "derived-data")
            return days >= quietDays
                ? candidate.retiered(.obsolete, reason: "\(days) 天没有构建过；下次构建会重新生成，也可从废纸篓找回")
                : candidate.retiered(.rebuildable, reason: "最近还在构建；删了下次构建要从头编译")
        }
    }

    /// DerivedData 的布局：info.plist、ModuleCache.noindex，再加 Build 或 Index.noindex 之一
    static func hasLayout(_ dir: String) -> Bool {
        isFile(dir + "/info.plist") && isDirectory(dir + "/ModuleCache.noindex")
            && (isDirectory(dir + "/Build") || isDirectory(dir + "/Index.noindex"))
    }

    /// 构建会写到的位置里最新的修改时间：目录本身、直接子项，以及 Build、Logs 的直接子项（目录 mtime 只随直接子项变）
    private static func newestModification(_ path: String) -> TimeInterval? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var newest = TimeInterval(st.st_mtimespec.tv_sec)
        for dir in [path, path + "/Build", path + "/Logs"] {
            for child in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where lstat(dir + "/" + child, &st) == 0 {
                newest = max(newest, TimeInterval(st.st_mtimespec.tv_sec))
            }
        }
        return newest
    }

    private static func isFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
