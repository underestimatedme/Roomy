// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

struct NestedBundleAssociationResult {
    var associations: [ApplicationAssociation] = []
    var sourceIdentities: [String: CleanupIdentity] = [:]
}

/// Identifier evidence comes from installed bundle metadata, never from a data
/// directory prefix. Foreign frameworks and shared app groups grant no authority.
enum NestedBundleAssociations {
    private struct BundleDirectoryEntry { let name: String; let isDir: Bool; let isLink: Bool }
    private struct BundleEvidence {
        var identifiers = Set<String>()
        var sources: [String: CleanupIdentity] = [:]
        var complete = true
    }
    private static let locations = ["PlugIns", "Helpers", "MacOS", "XPCServices", "Frameworks", "Library/LoginItems", "Library/LaunchServices"]
    private static let bundleExtensions: Set<String> = ["app", "appex", "xpc"]

    private static func readBundle(_ app: ApplicationRecord, budget: inout Int) -> BundleEvidence {
        var evidence = BundleEvidence()
        guard budget > 0 else { evidence.complete = false; return evidence }
        budget -= 1
        guard let expected = app.identity, expected.kind == .directory,
              CleanupIdentity.capture(path: app.path) == expected,
              ApplicationAssociations.directoryIdentities(app.path) != nil else { evidence.complete = false; return evidence }
        evidence.sources[app.path] = expected
        var visited = Set<String>()
        func entries(_ path: String) -> [BundleDirectoryEntry] {
            guard budget > 0 else { evidence.complete = false; return [] }
            budget -= 1
            var st = stat()
            guard lstat(path, &st) == 0 else { if errno != ENOENT { evidence.complete = false }; return [] }
            guard let before = CleanupIdentity.capture(path: path), before.kind == .directory,
                  ApplicationAssociations.directoryIdentities(path) != nil else { evidence.complete = false; return [] }
            // Bound readdir before allocating names, and use descriptor-relative
            // metadata so a link cannot substitute a different helper directory.
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { evidence.complete = false; return [] }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_ino == before.fileID,
                  UInt64(UInt32(bitPattern: opened.st_dev)) == before.deviceID,
                  let stream = fdopendir(fd) else { close(fd); evidence.complete = false; return [] }
            defer { closedir(stream) }
            var result: [BundleDirectoryEntry] = []
            var count = 0
            errno = 0
            while let raw = readdir(stream) {
                let name = withUnsafePointer(to: &raw.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(raw.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard count < 256 else { evidence.complete = false; break }
                count += 1
                var child = stat()
                if fstatat(fd, name, &child, AT_SYMLINK_NOFOLLOW) == 0 {
                    result.append(BundleDirectoryEntry(name: name, isDir: (child.st_mode & S_IFMT) == S_IFDIR,
                        isLink: (child.st_mode & S_IFMT) == S_IFLNK))
                } else { evidence.complete = false }
                errno = 0
            }
            if errno != 0 { evidence.complete = false }
            guard CleanupIdentity.capture(path: path) == before else { evidence.complete = false; return [] }
            evidence.sources[path] = before
            return result
        }
        func metadata(_ bundle: String) -> (String, MaintenanceFileSnapshot)? {
            for parent in [bundle + "/Contents", bundle] {
                let path = parent + "/Info.plist"
                if let snapshot = MaintenanceFileSnapshot.read(path: path, maximumBytes: 131_072) {
                    guard let dirs = ApplicationAssociations.directoryIdentities(parent) else { return nil }
                    for (name, identity) in dirs where name == app.path || name.hasPrefix(app.path + "/") { evidence.sources[name] = identity }
                    evidence.sources[path] = snapshot.identity
                    return (parent, snapshot)
                }
            }
            return nil
        }
        func visit(_ bundle: String, depth: Int, primary: Bool = false) {
            guard budget > 0, depth <= 3, visited.insert(bundle).inserted else { evidence.complete = false; return }
            budget -= 1
            guard let identity = CleanupIdentity.capture(path: bundle), identity.kind == .directory,
                  let (content, info) = metadata(bundle),
                  let identifier = info.plist["CFBundleIdentifier"] as? String, ApplicationCatalog.validBundleID(identifier),
                  let package = info.plist["CFBundlePackageType"] as? String,
                  ["APPL", "XPC!", "BNDL"].contains(package),
                  !primary || identifier == app.bundleID else { evidence.complete = false; return }
            if !primary {
                guard let executable = info.plist["CFBundleExecutable"] as? String, !executable.isEmpty,
                      executable != ".", executable != "..", !executable.contains("/"), !executable.utf8.contains(0) else { evidence.complete = false; return }
                let executablePath = content + (content.hasSuffix("/Contents") ? "/MacOS/" : "/") + executable
                guard let executableIdentity = CleanupIdentity.capture(path: executablePath), executableIdentity.kind == .file,
                      ApplicationAssociations.directoryIdentities(URL(fileURLWithPath: executablePath).deletingLastPathComponent().path) != nil else { evidence.complete = false; return }
                evidence.sources[executablePath] = executableIdentity
            }
            evidence.sources[bundle] = identity
            evidence.identifiers.insert(identifier)
            for location in locations {
                let parent = content + "/" + location
                for entry in entries(parent).sorted(by: { $0.name < $1.name }) {
                    let suffix = (entry.name as NSString).pathExtension.lowercased()
                    guard bundleExtensions.contains(suffix) else { continue }
                    guard entry.isDir && !entry.isLink else { evidence.complete = false; continue }
                    visit(parent + "/" + entry.name, depth: depth + 1)
                }
            }
        }
        if MaintenanceFileSnapshot.read(path: app.path + "/Contents/Info.plist", maximumBytes: 131_072) != nil ||
            MaintenanceFileSnapshot.read(path: app.path + "/Info.plist", maximumBytes: 131_072) != nil {
            visit(app.path, depth: 0, primary: true)
        } else {
            // Match ApplicationCatalog's single flat wrapped-app convention.
            let wrapped = entries(app.path + "/Wrapper").filter { $0.isDir && !$0.isLink && $0.name.hasSuffix(".app") }
            if wrapped.count == 1 { visit(app.path + "/Wrapper/" + wrapped[0].name, depth: 0, primary: true) }
            else { evidence.complete = false }
        }
        if !evidence.sources.allSatisfy({ CleanupIdentity.capture(path: $0.key) == $0.value }) { evidence.complete = false }
        return evidence
    }

    static func discover(app: ApplicationRecord, catalog: [ApplicationRecord], home: String,
                         temporaryDirectories: [ApplicationTemporaryDirectory], notices: inout [String]) -> NestedBundleAssociationResult {
        var budget = 8192
        // Read the selected installation first so an exhausted catalog budget can
        // still expose its known associations as protected review items.
        let own = readBundle(app, budget: &budget)
        guard own.identifiers.contains(app.bundleID), let identity = app.identity,
              CleanupIdentity.capture(path: app.path) == identity else {
            notices.append("应用及嵌套组件的来源身份无法确认，未扩展组件关联内容。")
            return NestedBundleAssociationResult()
        }
        var owners: [String: Set<String>] = [:], complete = own.complete && catalog.count <= 1024
        for identifier in own.identifiers { owners[identifier, default: []].insert(app.path) }
        for other in catalog.prefix(1024) where other.path != app.path {
            let evidence = readBundle(other, budget: &budget)
            complete = complete && evidence.complete
            // Even foreign identifiers count as another owner: they simply may
            // not grant that application's own cleanup authority.
            for identifier in evidence.identifiers { owners[identifier, default: []].insert(other.path) }
            owners[other.bundleID, default: []].insert(other.path)
        }
        if !complete { notices.append("部分安装的嵌套组件信息未能完整验证，新增组件关联仅供查看；范围限于标准组件目录。") }
        var result = NestedBundleAssociationResult(sourceIdentities: own.sources)
        let identifiers = own.identifiers.filter { $0 == app.bundleID || $0.hasPrefix(app.bundleID + ".") }.sorted()
        for identifier in identifiers {
            let unique = complete && owners[identifier]?.count == 1
            let sharedMessage = "同一标识可能被其他安装使用或组件清单不完整，仅供查看"
            let reason = unique ? "安装包内的组件元数据确认了此精确标识；可能包含脚本、配置或用户数据，需手动确认" : sharedMessage
            var candidates: [(String, String)] = [("Application Scripts", identifier)]
            if identifier != app.bundleID {
                candidates += [("Caches", identifier), ("Logs", identifier), ("Preferences", identifier + ".plist"),
                    ("HTTPStorages", identifier), ("WebKit", identifier), ("Saved Application State", identifier + ".savedState"),
                    ("Application Support", identifier), ("Containers", identifier)]
            }
            for (category, name) in candidates {
                let parent = home + "/Library/" + category, path = parent + "/" + name
                guard ApplicationAssociations.directoryIdentities(parent) != nil,
                      let identity = CleanupIdentity.capture(path: path), identity.kind == .file || identity.kind == .directory else { continue }
                result.associations.append(ApplicationAssociation(path: path, title: "组件关联 · " + category + " · " + identifier,
                    role: unique ? (category == "Caches" || category == "Logs" ? "cache" : "data") : "review", evidence: reason, executable: unique))
            }
            if identifier != app.bundleID {
                for directory in temporaryDirectories where directory.identity() != nil {
                    let path = directory.path + "/" + identifier
                    guard let identity = CleanupIdentity.capture(path: path), identity.kind == .directory || identity.kind == .file else { continue }
                    result.associations.append(ApplicationAssociation(path: path, title: "组件临时内容 · " + identifier,
                        role: unique ? (directory.kind == "cache" ? "cache" : "data") : "review", evidence: reason + "；临时内容也可能仍在使用", executable: unique))
                }
            }
        }
        return result
    }
}
