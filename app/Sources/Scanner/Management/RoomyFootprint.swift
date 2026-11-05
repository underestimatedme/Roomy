// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

/// Roomy 自身占用的只读统计。范围只有两处：App Bundle 本体，和 Roomy 自己的
/// 应用支持目录（~/Library/Application Support/Roomy）。不扫描整个用户目录。
///
/// 口径：
///   · 实际占用（st_blocks × 512），与扫描核心一致；不是逻辑大小
///   · 不跟随符号链接，不跨卷（根设备号限制 + BulkWalker 内部按根目录设备号限制）
///   · 硬链接按 (dev, inode) 只计一次，所有顶级子项共用一个 walker 的已见身份集合
///   · 读不到就是"未知"，绝不当成 0；不存在的路径才是"未发现"
struct FootprintCategory: Codable, Sendable {
    let id: String
    let title: String
    let detail: String
    /// nil 表示没有可用数值（未知/未发现），调用方必须显示"未知"而不是 0
    let bytes: UInt64?
    /// measured / partial / unknown / missing
    let status: String
    let fileCount: Int?
    /// 可以在 Finder 中定位的位置（只放已存在的路径）
    let paths: [String]
}

struct RoomyFootprint: Codable, Sendable {
    let capturedAt: Date
    let appSupportPath: String
    let categories: [FootprintCategory]
    let warnings: [String]
}

enum RoomyFootprintScanner {
    /// 扫描缓存与索引：上一次扫描/清理的结果缓存和完整索引，重新扫描就能再生成（这里不提供删除按钮）
    static let indexNames = ["last-scan.json", "last-cleanup.json"]
    /// 完整的扫描索引（scan-index-…roomyidx）：本机最大的一份 Roomy 文件通常就是它，重新扫描可再生成
    static let indexSuffixes = [".roomyidx"]
    /// 扫描历史：每次扫描后记下的占用快照。保存的是过去时点的数值，删掉不会重新生成。
    static let historyNames = ["SpaceGrowth"]
    /// 旧版扫描记录（*.roomyhist）：同样是过去时点的数据，保留
    static let historySuffixes = [".roomyhist"]
    /// 配置、偏好与许可：只读文件名和大小，绝不读取内容
    static let configNames = ["cleanup-preferences.json", "protected-cleanup.json", "code-roots.json",
                              "automation.json", "config.json", "settings.json", "state.json", "license.json"]
    /// 恢复与操作记录：找回清理过的文件要用（回收站账本与操作记录）
    static let recoveryNames = ["pending-trash.json", "operations.jsonl"]

    /// 一个分类桶的累加结果。known 表示至少有一项读到了数值，
    /// 只有 unknown 的桶不能把 0 当成合计（那是未知）。
    private struct Bucket {
        var bytes: UInt64 = 0
        var files = 0
        var known = false
        var partial = false
        var unknown = false
        var paths: [String] = []
    }

    /// 单个路径的只读测量。符号链接与非普通文件不统计。
    /// 读不到时 bytes 为 nil（未知），不是 0；只有 ENOENT 才算"未发现"。
    /// walker 由调用方共享，让跨子项的硬链接只算一次；rootDevice 用来拒绝挂在子项上的其他卷。
    /// 完整性只看产生这个数值的这一次遍历（sizeDetailed）：权限以外的 IO 失败同样让桶标成 partial，
    /// 不用共享 walker 的累计错误去污染后面正常的桶。
    private static func measure(_ path: String, walker: BulkWalker? = nil, rootDevice: UInt64? = nil)
        -> (bytes: UInt64?, status: String, files: Int?) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            // 只有 ENOENT 才是"不存在"；权限或其他错误是未知，不能写成 0 或"没有这项"
            return (nil, errno == ENOENT ? "missing" : "unknown", nil)
        }
        let mode = metadata.st_mode & S_IFMT
        guard mode == S_IFDIR || mode == S_IFREG else { return (nil, "unknown", nil) }
        // 根设备限制：挂在应用支持目录里的其他卷不属于 Roomy，跨卷测量会把整个卷算进来
        if let rootDevice, UInt64(UInt32(bitPattern: metadata.st_dev)) != rootDevice {
            return (nil, "excluded", nil)
        }
        // 普通文件和目录都交给同一个受限 walker：文件也走 (dev, inode) 去重，
        // 否则两个顶级文件互为硬链接时会被各算一遍（直接返回 st_blocks 就绕过了共享的已见集合）。
        // 不跟随链接（lstat 已确认是普通文件或目录），大小仍按块计算。
        let walker = walker ?? BulkWalker()
        let filesBefore = walker.files
        let measurement = walker.sizeDetailed(of: path)
        let files = walker.files - filesBefore
        guard let bytes = measurement.size else { return (nil, "unknown", nil) }
        // 一个目录里一项都没读到：是未知，不是 0 字节
        if bytes == 0 && measurement.completeness == .incomplete { return (nil, "partial", nil) }
        return (bytes, measurement.completeness == .complete ? "measured" : "partial", files)
    }

    static func classify(_ name: String) -> String {
        let lower = name.lowercased()
        if indexNames.contains(name) || indexSuffixes.contains(where: { lower.hasSuffix($0) }) { return "index" }
        if historyNames.contains(name) || historySuffixes.contains(where: { lower.hasSuffix($0) }) { return "history" }
        if configNames.contains(name) { return "config" }
        if recoveryNames.contains(name) { return "recovery" }
        return "other"
    }

    static let titles = ["index": "扫描缓存与索引", "history": "扫描历史与增长记录",
                         "config": "配置、偏好与许可", "recovery": "恢复与操作记录", "other": "其他数据"]
    static let details = [
        "index": "上一次扫描和清理的结果缓存（last-scan.json、last-cleanup.json），以及完整的扫描索引（*.roomyidx）。.roomyidx 是扫描时写下的文件索引，用来加快下一次扫描和按文件夹查看；这些文件都能重新扫描生成。",
        "history": "每次扫描后记下的占用快照（SpaceGrowth）和旧版扫描记录（*.roomyhist）。它保存的是过去的数值，删掉不会重新生成，只会失去可对比的历史，请保留。",
        "config": "清理偏好、受保护清单、代码根、后台规则和许可文件。只读取文件大小，不读取里面的内容。",
        "recovery": "待恢复的回收站账本和操作记录，用于把清理过的文件找回来。这些记录不在别处有备份，请保留。",
        "other": "Roomy 应用支持目录里其余的数据文件。"
    ]
    /// 分类展示顺序：App 本体单独一行，合计只含应用支持目录
    static let categoryOrder = ["index", "history", "config", "recovery", "other"]

    /// 只统计 App Bundle 和 Roomy 应用支持目录；子项按用途分类，父/子总量不相加。
    static func measure(appBundle: String, appSupport: String, capturedAt: Date = Date()) -> RoomyFootprint {
        var categories: [FootprintCategory] = []
        var warnings: [String] = []

        let app = measure(appBundle)
        if app.status == "missing" {
            warnings.append("没有找到 App 本体，可能正在开发目录里运行。")
        } else if app.status == "unknown" {
            warnings.append("读不到 App 本体的占用（权限或其他错误），这里是未知，不是 0。")
        } else if app.status == "partial" {
            warnings.append("App 本体有部分内容读不到，数值是已读到的部分。")
        }
        categories.append(FootprintCategory(id: "app", title: "Roomy App 本体",
            detail: "应用包本身的大小，包含内置的资源。与下面的应用支持目录分开统计，两者不相加。",
            bytes: app.bytes, status: app.status, fileCount: app.files,
            paths: app.status == "missing" ? [] : [appBundle]))

        // 应用支持目录：只列一层子项并归类，不递归拼接父/子总量
        var buckets: [String: Bucket] = [:]
        var supportKnown = false
        var supportStatus = "missing"
        var supportBytes: UInt64? = nil
        var supportFiles: Int? = nil
        var excludedLinks = 0
        var excludedVolumes = 0

        var supportMeta = stat()
        if lstat(appSupport, &supportMeta) != 0 {
            // 不存在与读不到要分开：读不到时合计是未知，不是 0
            supportStatus = errno == ENOENT ? "missing" : "unknown"
            if supportStatus == "unknown" {
                warnings.append("无法确认 Roomy 应用支持目录（权限或其他错误），占用未知。")
            }
        } else if supportMeta.st_mode & S_IFMT != S_IFDIR {
            supportStatus = "unknown"
            warnings.append("Roomy 应用支持目录的位置不是普通目录，占用未知。")
        } else {
            supportKnown = true
            var entries: [DirEntry] = []
            var listed = false
            if let fd = try? openDir(appSupport) {
                let buf = AttrBuffer()
                listed = (try? readEntries(fd: fd, into: &entries, buf: buf)) != nil
                close(fd)
            }
            if !listed {
                // 一项都没读到：合计是未知，不能拿 0 冒充总量
                supportStatus = "unknown"
                warnings.append("无法读取 Roomy 应用支持目录的内容，合计未知。")
            } else {
                let rootDevice = UInt64(UInt32(bitPattern: supportMeta.st_dev))
                // 所有顶级子项共用一个 walker：跨子项的硬链接按 (dev, inode) 只算一次
                let walker = BulkWalker()
                var total: UInt64 = 0
                var totalFiles = 0
                for entry in entries {
                    // 符号链接不跟随：既不统计也不进入，避免把外部内容算成 App 数据
                    if entry.isLink { excludedLinks += 1; continue }
                    let path = appSupport + "/" + entry.name
                    let kind = classify(entry.name)
                    let result = measure(path, walker: walker, rootDevice: rootDevice)
                    // 挂载在应用支持目录上的其他卷不是 Roomy 的数据，跨卷测量会把它整个算进来
                    if result.status == "excluded" { excludedVolumes += 1; continue }
                    var bucket = buckets[kind] ?? Bucket()
                    if let value = result.bytes {
                        total = total &+ value
                        totalFiles += result.files ?? 0
                        bucket.bytes = bucket.bytes &+ value
                        bucket.files += result.files ?? 0
                        bucket.known = true
                    } else if result.status != "missing" {
                        bucket.unknown = true
                    }
                    if result.status == "partial" { bucket.partial = true }
                    if result.status != "missing" { bucket.paths.append(path) }
                    buckets[kind] = bucket
                }
                supportBytes = total
                supportFiles = totalFiles
                supportStatus = buckets.values.contains { $0.partial || $0.unknown } ? "partial" : "measured"
                if supportStatus == "partial" {
                    warnings.append("应用支持目录有部分内容读不到，合计只含已读到的部分。")
                }
                if excludedLinks > 0 {
                    warnings.append("应用支持目录里有 \(excludedLinks) 项符号链接，未计入；链接指向的外部内容也不算。")
                }
                if excludedVolumes > 0 {
                    warnings.append("应用支持目录里有 \(excludedVolumes) 项在其他卷或挂载点上，未计入。")
                }
            }
        }

        for kind in categoryOrder {
            let bucket = buckets[kind]
            let status: String
            if let bucket {
                status = bucket.partial ? "partial" : bucket.unknown ? "unknown" : "measured"
            } else {
                status = supportKnown ? "missing" : "unknown"
            }
            let measured = bucket?.known == true
            categories.append(FootprintCategory(id: kind, title: titles[kind]!,
                detail: details[kind]!,
                // 目录本身不存在时没有数值；一项都没读到也算未知，不写 0
                bytes: measured ? bucket?.bytes : nil, status: status,
                fileCount: measured ? bucket?.files : nil, paths: bucket?.paths ?? []))
        }

        categories.append(FootprintCategory(id: "support", title: "应用支持目录合计",
            detail: "只含 Roomy 自己的应用支持目录，不含 App 本体，也不含用户目录里的其他内容。",
            bytes: supportBytes, status: supportStatus, fileCount: supportFiles,
            paths: supportKnown ? [appSupport] : []))
        return RoomyFootprint(capturedAt: capturedAt, appSupportPath: appSupport,
                              categories: categories, warnings: warnings)
    }
}
