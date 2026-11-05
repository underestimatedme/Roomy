// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

struct ApplicationAssociation {
    let path: String
    let title: String
    let role: String
    let evidence: String
    let executable: Bool
}

/// Matches only bounded, app-specific locations. A name is evidence for review,
/// never permission to remove a vendor directory or the enclosing category.
enum ApplicationAssociations {
    private static let sharedNames: Set<String> = ["apple", "google", "microsoft", "adobe", "jetbrains", "mozilla", "electron", "helper", "application", "caches", "logs", "crashreporter", "tmp"]
    static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
    static func names(_ app: ApplicationRecord) -> Set<String> {
        Set((app.associationNames ?? [app.title, URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent])
            .filter { $0.count >= 4 && $0.utf8.count < 256 && !$0.contains("/") && !$0.contains("\n") && !$0.contains("\r") && $0 != "." && $0 != ".." }
            .map(nameKey).filter { !sharedNames.contains($0) })
    }

    // Verify every ancestor: lstat(category) alone would miss an earlier link.
    static func directoryIdentities(_ path: String) -> [(String, CleanupIdentity)]? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        var current = "", result: [(String, CleanupIdentity)] = []
        for component in path.split(separator: "/") {
            current += "/" + component
            guard let identity = CleanupIdentity.capture(path: current), identity.kind == .directory else { return nil }
            result.append((current, identity))
        }
        return result
    }
    private static func unchanged(_ parents: [(String, CleanupIdentity)]) -> Bool {
        parents.allSatisfy { CleanupIdentity.capture(path: $0.0) == $0.1 }
    }
    static func entries(_ path: String, notices: inout [String]) -> [DirEntry] {
        var value = stat()
        if lstat(path, &value) != 0 && errno == ENOENT { return [] }
        guard let parents = directoryIdentities(path) else {
            notices.append("关联目录不可安全读取，已跳过：\(path)"); return []
        }
        do {
            let result = try readDir(path)
            guard unchanged(parents) else { notices.append("关联目录读取期间发生变化，已跳过：\(path)"); return [] }
            return result.sorted { $0.name < $1.name }
        } catch { notices.append("无法读取关联目录，已跳过：\(path)"); return [] }
    }
    private static func unique(_ key: String, app: ApplicationRecord, catalog: [ApplicationRecord]) -> Bool {
        let owners = catalog.filter { names($0).contains(key) }
        return owners.count == 1 && owners[0].path == app.path
    }

    /// Read only a bounded diagnostic header; never retain report contents.
    private static func diagnosticID(_ path: String) -> String? {
        guard let parents = directoryIdentities(URL(fileURLWithPath: path).deletingLastPathComponent().path),
              let before = CleanupIdentity.capture(path: path), before.kind == .file else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_ino == before.fileID, UInt64(UInt32(bitPattern: st.st_dev)) == before.deviceID else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, CleanupIdentity.capture(path: path) == before, unchanged(parents) else { return nil }
        let data = Data(bytes.prefix(count))
        if let first = data.split(separator: 10, maxSplits: 1).first,
           let dict = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
           let id = dict["bundleID"] as? String { return id }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").first { $0.hasPrefix("Identifier:") }
            .map { $0.dropFirst("Identifier:".count).trimmingCharacters(in: .whitespaces) }
    }
    private static func crashName(_ filename: String, keys: Set<String>, marker: Bool) -> String? {
        let file = URL(fileURLWithPath: filename)
        guard marker ? file.pathExtension.lowercased() == "plist" : ["ips", "crash", "hang"].contains(file.pathExtension.lowercased()) else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        return keys.sorted().first { key in
            let prefix = key + "_", lower = nameKey(stem)
            guard lower.hasPrefix(prefix) else { return false }
            let suffix = String(stem.dropFirst(prefix.count))
            if marker { return UUID(uuidString: suffix) != nil }
            return suffix.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}(?:_[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil
        }
    }
    static func discover(app: ApplicationRecord, catalog: [ApplicationRecord], home: String,
                         temporaryDirectories: [ApplicationTemporaryDirectory] = [], notices: inout [String]) -> [ApplicationAssociation] {
        let library = home + "/Library", keys = names(app)
        var result: [ApplicationAssociation] = []
        for category in ["Caches", "Logs"] {
            let parent = library + "/" + category
            for entry in entries(parent, notices: &notices) where !entry.isLink && (entry.isDir || entry.isFile) {
                let key = nameKey(entry.name)
                guard keys.contains(key) else { continue }
                let owned = unique(key, app: app, catalog: catalog)
                result.append(ApplicationAssociation(path: parent + "/" + entry.name,
                    title: category == "Caches" ? "名称缓存 · \(entry.name)" : "名称日志 · \(entry.name)", role: owned ? "cache" : "review",
                    evidence: owned ? "与本次安装清单中的应用名称精确匹配，仍需手动确认；缓存可能重新下载，日志会丢失" : "其他安装也使用此名称，归属可能共享；只能查看", executable: owned))
            }
        }
        for (category, marker) in [("Application Support/CrashReporter", true), ("Logs/DiagnosticReports", false)] {
            let parent = library + "/" + category
            for entry in entries(parent, notices: &notices) where entry.isFile && !entry.isLink {
                let path = parent + "/" + entry.name
                if !marker && !["ips", "crash", "hang"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) { continue }
                let id = marker ? nil : diagnosticID(path)
                // A conflicting identifier always outweighs the file's name.
                if let id, id != app.bundleID { continue }
                let key = crashName(entry.name, keys: keys, marker: marker)
                guard id == app.bundleID || key != nil else { continue }
                let owned = id == app.bundleID || (marker && key.map { unique($0, app: app, catalog: catalog) } == true)
                result.append(ApplicationAssociation(path: path, title: "崩溃记录 · \(entry.name)", role: owned ? "diagnostic" : "review",
                    evidence: owned ? (id == app.bundleID ? "诊断头中的应用标识精确匹配；移除后会失去排查崩溃的记录，请手动确认" : "应用名称或可执行程序名与标准崩溃记录文件名匹配；移除后会失去诊断记录，请手动确认") : (marker ? "多个应用使用相同名称或程序名，归属无法确认；只能查看" : "诊断头中的应用标识未能确认，只有文件名匹配；只能查看"), executable: owned))
            }
        }
        for root in temporaryDirectories {
            guard root.identity() != nil else {
                notices.append("当前用户临时目录不可安全读取，已跳过：\(root.path)"); continue
            }
            for entry in entries(root.path, notices: &notices) where !entry.isLink && (entry.isFile || entry.isDir) {
                let exact = entry.name == app.bundleID, key = nameKey(entry.name)
                guard exact || keys.contains(key) else { continue }
                let owned = exact || unique(key, app: app, catalog: catalog)
                let temporary = root.kind == "temporary"
                result.append(ApplicationAssociation(path: root.path + "/" + entry.name,
                    title: temporary ? "临时文件 · \(entry.name)" : "临时缓存 · \(entry.name)",
                    role: owned ? (temporary ? "data" : "cache") : "review",
                    evidence: owned ? ((exact ? "按精确应用标识匹配" : "按唯一应用名称匹配，归属仍需核查") + (temporary ? "；可能包含未保存内容或正在使用的临时文件，请手动确认" : "；仅检查当前用户的应用子目录，缓存可能重新生成，请手动确认")) : "其他安装也使用此名称，临时内容可能共享；只能查看", executable: owned))
            }
        }
        result += JetBrainsAssociations.discover(app: app, catalog: catalog, home: home, notices: &notices)
        return result
    }
}
