// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

struct CleanupIdentity: Codable, Equatable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let kind: EntryKind
    let allocatedSize: UInt64
    let modifiedAt: Int64
    let logicalSize: UInt64?
    let modifiedNanoseconds: Int64?

    init(deviceID: UInt64, fileID: UInt64, kind: EntryKind, allocatedSize: UInt64,
         modifiedAt: Int64, logicalSize: UInt64? = nil, modifiedNanoseconds: Int64? = nil) {
        self.deviceID = deviceID; self.fileID = fileID; self.kind = kind
        self.allocatedSize = allocatedSize; self.modifiedAt = modifiedAt
        self.logicalSize = logicalSize; self.modifiedNanoseconds = modifiedNanoseconds
    }

    static func capture(path: String, fallback: ScanEntry) -> CleanupIdentity {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_ino == fallback.fileID,
              UInt64(UInt32(bitPattern: value.st_dev)) == fallback.deviceID else {
            return CleanupIdentity(deviceID: fallback.deviceID, fileID: fallback.fileID,
                kind: fallback.kind, allocatedSize: fallback.physicalAllocatedSize,
                modifiedAt: fallback.modifiedAt)
        }
        return CleanupIdentity(deviceID: fallback.deviceID, fileID: fallback.fileID,
            kind: fallback.kind, allocatedSize: UInt64(value.st_blocks) * 512,
            modifiedAt: Int64(value.st_mtimespec.tv_sec), logicalSize: UInt64(max(0, value.st_size)),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
}

final class LiveFile: @unchecked Sendable {
    let parentDescriptor: Int32
    let path: String

    init(parentDescriptor: Int32, path: String) {
        self.parentDescriptor = parentDescriptor
        self.path = path
    }

    deinit { close(parentDescriptor) }
}

enum CleanupValidation {
    case allowed(LiveFile)
    case changed(String)
    case blocked(String)
}

struct CleanupValidator: Sendable {
    func validate(path: String, expected item: ScanItem, home: String, minimumDepth: Int = 2,
                  selectedRoot: SavedCodeRoot? = nil,
                  runner: CommandRunning = ProcessRunner(), tools: ToolLocator = ToolLocator(),
                  probeCodeRoots: [String] = CodeRoots.splitProtected(ALL_CODE_ROOTS).fast,
                  probeHome: String = HOME,
                  probeAndroidHome: String? = SdkCopyProbe.currentAndroidHome()) -> CleanupValidation {
        guard item.undo, item.risk != .lock else { return .blocked("项目受保护或不可撤销") }
        guard let expected = item.identity else { return .blocked("扫描结果缺少文件身份，请重新扫描") }
        guard expected.logicalSize != nil, expected.modifiedNanoseconds != nil else {
            return .blocked("扫描结果缺少完整文件元数据，请重新扫描")
        }

        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedHome = URL(fileURLWithPath: home).standardizedFileURL.path
        let depth = selectedRoot == nil ? minimumDepth : 1
        guard normalized.hasPrefix(normalizedHome + "/"),
              normalized.dropFirst(normalizedHome.count).split(separator: "/").count >= max(1, depth) else {
            return .blocked("路径太浅或不在用户目录")
        }
        let relative = normalized.dropFirst(normalizedHome.count + 1).split(separator: "/").map(String.init)
        guard let leaf = relative.last else { return .blocked("无效路径") }
        guard !leaf.isEmpty else { return .blocked("无效路径") }
        var parentFD = open(normalizedHome, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentFD >= 0 else { return .blocked("无法安全打开用户目录") }
        if let selectedRoot {
            var rootIdentity = stat()
            guard selectedRoot.path == GitRepositoryDiscovery.normalizedPath(home),
                  fstat(parentFD, &rootIdentity) == 0, rootIdentity.st_ino == selectedRoot.fileID,
                  UInt64(UInt32(bitPattern: rootIdentity.st_dev)) == selectedRoot.deviceID else {
                close(parentFD); return .blocked("手动选择的代码目录已变化，请重新选择并扫描")
            }
        }
        for component in relative.dropLast() {
            let next = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            close(parentFD)
            guard next >= 0 else {
                return errno == ELOOP || errno == ENOTDIR
                    ? .blocked("父目录已变成符号链接或非目录") : .changed("父目录已变化")
            }
            parentFD = next
        }

        var live = stat()
        guard fstatat(parentFD, leaf, &live, AT_SYMLINK_NOFOLLOW) == 0 else {
            close(parentFD)
            return .changed(errno == ENOENT ? "项目已不存在" : "项目无法重新验证")
        }
        let kind = entryKind(live.st_mode)
        if kind == .symbolicLink {
            close(parentFD)
            return .blocked("项目已变成符号链接")
        }
        let actual = CleanupIdentity(
            deviceID: UInt64(UInt32(bitPattern: live.st_dev)), fileID: live.st_ino,
            kind: kind, allocatedSize: UInt64(live.st_blocks) * 512,
            modifiedAt: Int64(live.st_mtimespec.tv_sec), logicalSize: UInt64(max(0, live.st_size)),
            modifiedNanoseconds: Int64(live.st_mtimespec.tv_nsec))
        guard actual == expected else {
            close(parentFD)
            return .changed("文件身份、类型、大小或修改时间已变化")
        }
        if let reason = CleanupEvidence.executionBlocker(item, runner: runner, tools: tools,
            codeRoots: probeCodeRoots, home: probeHome, androidHome: probeAndroidHome) {
            close(parentFD)
            return .blocked(reason)
        }
        return .allowed(LiveFile(parentDescriptor: parentFD, path: normalized))
    }

    private func entryKind(_ mode: mode_t) -> EntryKind {
        switch mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }
}
