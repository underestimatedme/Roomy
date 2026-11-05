// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

struct ApplicationRecord: Codable {
    let id: String
    let title: String
    let version: String
    let bundleID: String
    let path: String
    let size: UInt64
    let running: Bool
    let system: Bool
    let blockReason: String?
    let identity: CleanupIdentity?
    var associationNames: [String]? = nil
}

struct ApplicationInventory: Codable { let apps: [ApplicationRecord]; let warnings: [String] }

enum ApplicationCatalog {
    static let helperBlockReason = "包含特权辅助程序，请使用厂商卸载方式"
    static let runningBlockReason = "应用或它的辅助进程正在运行，请先自行退出"
    static func isRunning(_ path: String, processes: [String]) -> Bool {
        processes.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    static func validBundleID(_ id: String) -> Bool {
        !id.isEmpty && id.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
        }
    }

    private static func metadata(at path: String) -> [String: Any]? {
        func read(_ file: String, parents: [String]) -> [String: Any]? {
            let snapshots = parents.compactMap { CleanupIdentity.capture(path: $0) }
            guard snapshots.count == parents.count, snapshots.allSatisfy({ $0.kind == .directory }),
                  let before = CleanupIdentity.capture(path: file), before.kind == .file,
                  let data = FileManager.default.contents(atPath: file),
                  CleanupIdentity.capture(path: file) == before,
                  zip(parents, snapshots).allSatisfy({ CleanupIdentity.capture(path: $0.0) == $0.1 }) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        if let info = read(path + "/Contents/Info.plist", parents: [path, path + "/Contents"]) { return info }
        if let info = read(path + "/Info.plist", parents: [path]) { return info }
        // iPhone/iPad apps installed on Mac wrap a single flat bundle. Read its
        // regular metadata directly; never follow the WrappedBundle symlink.
        let wrapper = path + "/Wrapper"
        guard CleanupIdentity.capture(path: wrapper)?.kind == .directory,
              let entries = try? readDir(wrapper) else { return nil }
        let bundles = entries.filter { $0.isDir && !$0.isLink && $0.name.lowercased().hasSuffix(".app") }
        guard bundles.count == 1 else { return nil }
        let inner = wrapper + "/" + bundles[0].name
        return read(inner + "/Info.plist", parents: [path, wrapper, inner])
    }

    static func discover(roots: [String], runningPaths: [String],
                         sizeOf: (String) -> UInt64? = { BulkWalker().size(of: $0) }) -> ApplicationInventory {
        var apps: [ApplicationRecord] = [], warnings: [String] = [], visited = Set<String>()
        func visit(_ directory: String, depth: Int) {
            guard depth <= 4 else {
                warnings.append("应用目录层级超过扫描范围，归属信息不完整：\(directory)")
                return
            }
            let entries: [DirEntry]
            do { entries = try readDir(directory) }
            catch {
                // A user Applications directory is optional; other read failures
                // make ownership evidence incomplete rather than silently safe.
                if depth == 0, case BulkError.notFound = error { return }
                warnings.append("无法读取应用目录：\(directory)"); return
            }
            for entry in entries.sorted(by: { $0.name < $1.name }) where entry.isDir && !entry.isLink {
                let path = directory + "/" + entry.name
                guard visited.insert(path).inserted else { continue }
                guard entry.name.lowercased().hasSuffix(".app") else { visit(path, depth: depth + 1); continue }
                let plist = metadata(at: path) ?? [:]
                let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
                let title = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? String(entry.name.dropLast(4))
                let system = path.hasPrefix("/System/") || bundleID.hasPrefix("com.apple.")
                let running = isRunning(path, processes: runningPaths)
                let size = sizeOf(path)
                let identity = CleanupIdentity.capture(path: path)
                let reason: String?
                if bundleID == "com.atlaspaces.roomy" { reason = "Roomy 自身不能在这里卸载" }
                else if system { reason = "系统和 Apple 应用仅供查看" }
                else if running { reason = runningBlockReason }
                else if !validBundleID(bundleID) || plist["CFBundlePackageType"] as? String != "APPL" || identity == nil { reason = "应用信息不完整，无法安全卸载" }
                else if plist["SMPrivilegedExecutables"] != nil { reason = helperBlockReason }
                else if size == nil { reason = "应用大小未能完整读取，请检查读取权限后刷新" }
                else { reason = nil }
                if !validBundleID(bundleID) {
                    warnings.append("应用标识未能完整读取：\(path)")
                }
                if size == nil { warnings.append("大小未能读取：\(path)") }
                apps.append(ApplicationRecord(id: CleanupCandidate.stableID("application", path), title: title,
                    version: plist["CFBundleShortVersionString"] as? String ?? "", bundleID: bundleID, path: path,
                    size: size ?? 0, running: running, system: system, blockReason: reason, identity: identity,
                    associationNames: [title, String(entry.name.dropLast(4))] + ["CFBundleName", "CFBundleExecutable"].compactMap { plist[$0] as? String }))
            }
        }
        for root in roots { visit(root, depth: 0) }
        return ApplicationInventory(apps: apps.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, warnings: warnings)
    }
}
