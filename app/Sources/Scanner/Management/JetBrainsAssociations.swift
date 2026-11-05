// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// Only verified product metadata may name an IDE version directory. The
/// enclosing vendor directory and other editions/versions are never candidates.
enum JetBrainsAssociations {
    private static let products: [String: (code: String, prefix: String)] = [
        "com.jetbrains.intellij.ce": ("IC", "IdeaIC"),
        "com.jetbrains.intellij": ("IU", "IntelliJIdea")
    ]

    private static func directory(_ app: ApplicationRecord) -> String? {
        guard let product = products[app.bundleID],
              app.version.range(of: #"^[0-9]{4}\.[0-9]{1,2}(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else { return nil }
        let parent = app.path + "/Contents/Resources", path = parent + "/product-info.json"
        guard let parents = ApplicationAssociations.directoryIdentities(parent),
              let before = CleanupIdentity.capture(path: path), before.kind == .file,
              let size = before.logicalSize, size > 0, size <= 128 * 1024 else { return nil }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_ino == before.fileID,
              UInt64(UInt32(bitPattern: st.st_dev)) == before.deviceID, st.st_size == Int64(size) else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: Int(size)), data.count == Int(size),
              CleanupIdentity.capture(path: path) == before,
              parents.allSatisfy({ CleanupIdentity.capture(path: $0.0) == $0.1 }),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              info["productCode"] as? String == product.code,
              info["version"] as? String == app.version,
              let name = info["dataDirectoryName"] as? String else { return nil }
        let version = app.version.split(separator: ".").prefix(2).joined(separator: ".")
        return name == product.prefix + version ? name : nil
    }

    static func discover(app: ApplicationRecord, catalog: [ApplicationRecord], home: String,
                         notices: inout [String]) -> [ApplicationAssociation] {
        guard products[app.bundleID] != nil else { return [] }
        guard let name = directory(app) else {
            notices.append("IDE 产品目录信息未能确认，未按名称猜测版本缓存：\(app.title)")
            return []
        }
        // Unknown JetBrains installations could also share this directory.
        // A fresh catalog and metadata read repeats this check before mutation.
        let shared = catalog.contains { other in
            guard other.path != app.path && other.bundleID.hasPrefix("com.jetbrains.") else { return false }
            let otherDirectory = directory(other)
            return otherDirectory == nil || otherDirectory == name
        }
        if shared { notices.append("其他 IDE 安装可能共享此版本目录，关联内容仅供查看。") }
        var result: [ApplicationAssociation] = []
        for category in ["Caches", "Logs", "Application Support"] {
            let parent = home + "/Library/" + category + "/JetBrains"
            for entry in ApplicationAssociations.entries(parent, notices: &notices)
                where entry.name == name && entry.isDir && !entry.isLink {
                let settings = category == "Application Support", executable = !settings && !shared
                let title = settings ? "IDE 设置与插件" : category == "Caches" ? "IDE 可重建缓存" : "IDE 日志"
                let evidence = settings ? "应用产品信息确认了对应版本；包含设置、插件或用户状态，保留并仅供查看" :
                    shared ? "多个 IDE 安装可能使用此版本目录；只能查看" :
                    "应用标识、产品代码及版本目录精确匹配；" + (category == "Caches" ? "缓存可重建，下次索引或构建可能变慢，请手动确认" : "移除后会失去诊断日志，请手动确认")
                result.append(ApplicationAssociation(path: parent + "/" + name, title: title + " · " + name,
                    role: executable ? "cache" : "review", evidence: evidence, executable: executable))
            }
        }
        return result
    }
}
