// SPDX-License-Identifier: GPL-3.0-only
// 标准位置之外的另一份 Android SDK（同时含 platform-tools、build-tools、platforms）。
// 先查谁还指着它：项目的 local.properties（sdk.dir）、shell 启动文件、后台服务的 plist、模拟器配置。
// 都没有就进 A（需要时用 sdkmanager 重新安装）；有引用或没查完进 C，并写明是谁。
// 扫描时把引用与检查完整性记进证据；执行前按同一范围重算，只有证据完全一致才放行。

import CryptoKit
import Darwin
import Foundation

enum SdkCopyProbe {
    static let group = "Android SDK 副本"
    static let inUse = "有进程正在使用这份 SDK（如模拟器或 adb），结束后重新扫描"
    private static let required = ["platform-tools", "build-tools", "platforms"]
    private static let maxDepth = 3
    private static let directoryLimit = 20_000
    private static let skipped: Set<String> = ["node_modules", ".git", "build"]
    /// 找 local.properties 的边界，与 GradleWrapperProbe 找 wrapper 配置相同
    private static let projectDepth = 6
    static let projectDirectoryLimit = 50_000
    private static let projectSecondsBudget: TimeInterval = 5
    private static let propertiesLimit = 65_536
    private static let shellFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile", ".profile",
                                     ".config/fish/config.fish"]

    /// androidHome：只读 ANDROID_HOME 这一个变量（不展开整个环境）；standard：标准 SDK 位置；
    /// codeRoots：在这些目录下找项目的 local.properties；home：shell 启动文件、LaunchAgents、模拟器配置所在的家目录
    static func candidates(searchRoots: [String], codeRoots: [String] = ALL_CODE_ROOTS, home: String = HOME,
                           androidHome: String? = currentAndroidHome(),
                           standard: String = HOME + "/Library/Android/sdk",
                           sizeOf: ((String) -> UInt64?)? = nil) -> [CleanupCandidate] {
        let excluded = ([standard] + [androidHome].compactMap { $0 }.filter { !$0.isEmpty }).map(canonical)
        var found: [String] = [], seen = Set<String>(), visited = 0
        for root in searchRoots {
            var stack = [(root, 0)]
            while let (dir, depth) = stack.popLast() {
                guard visited < directoryLimit else { break }
                visited += 1
                if hasSdkLayout(dir) {
                    let real = canonical(dir)
                    // 标准 SDK、ANDROID_HOME 指向的 SDK，以及包含或位于它们之内的目录都不列
                    let related = excluded.contains { real == $0 || real.hasPrefix($0 + "/") || $0.hasPrefix(real + "/") }
                    if !related, seen.insert(real).inserted { found.append(dir) }
                    continue
                }
                guard depth < maxDepth, let children = try? readDir(dir) else { continue }
                for child in children where child.isDir && !skipped.contains(child.name) {
                    stack.append((dir + "/" + child.name, depth + 1))
                }
            }
        }
        guard !found.isEmpty else { return [] }
        found.sort()
        // 有副本才去翻项目：绝大多数机器上没有副本，不该为它多走一遍代码目录
        let projects = sdkDirectories(in: codeRoots, home: home)
        let sizes = sizeOf == nil ? BulkWalker().measureTargets(found) : [:]
        return found.map { path in
            let size = sizeOf?(path) ?? sizes[path] ?? 0
            let scan = referenceScan(to: path, projects: projects.entries,
                                     projectComplete: projects.complete, projectUnknown: projects.unknown, home: home)
            let state = ScanState(scan: scan, codeRoots: codeRoots, home: home,
                                  androidHome: androidHome, standard: standard)
            let evidence = "标准 SDK 之外的另一份 Android SDK，" + (scan.references.isEmpty
                ? (scan.complete ? "本次检查范围内没有找到引用" : "引用检查不完整")
                : "仍有引用")
            let item = ScanItem.trashTarget(path: path, name: (path as NSString).lastPathComponent, size: size,
                                            rule: group, evidence: evidence, risk: .amber)
            let candidate = OwnerCachePolicy.ownedCandidate(item, title: group + " · " + shown(path, home: home),
                                                            role: "sdk-copy", detail: state.encoded)
            if !scan.references.isEmpty {
                let named = scan.references.prefix(3).joined(separator: "、") + (scan.references.count > 3 ? " 等" : "")
                var reason = "被 \(named) 引用；确认不再需要后再清"
                if !scan.unknown.isEmpty { reason += "；另有部分配置无法读取" }
                return candidate.retiered(.review, reason: reason)
            }
            guard scan.complete else {
                let why = scan.unknown.isEmpty
                    ? "代码目录太大或层级太深，没能查完所有项目的 local.properties"
                    : "有配置或目录无法读取，没能完整检查引用"
                return candidate.retiered(.review, reason: why + "；请确认没有脚本或 CI 使用后再清")
            }
            return candidate.retiered(.obsolete, reason:
                "在本次扫描的代码目录、shell 启动文件、后台服务和模拟器配置中没有找到引用；未检查其他位置；需要时用 sdkmanager 重新安装，也可从废纸篓找回")
        }
    }

    /// 执行前复核：布局还在、扫描范围与引用证据仍完全一致。nil = 可以执行
    static func executionBlocker(path: String, evidence: String?,
                                 codeRoots: [String] = CodeRoots.splitProtected(ALL_CODE_ROOTS).fast,
                                 home: String = HOME,
                                 androidHome: String? = currentAndroidHome()) -> String? {
        guard hasSdkLayout(path) else { return "目录已不再是 Android SDK 的布局，请重新扫描" }
        guard let evidence, let scanned = ScanState.decode(evidence) else {
            return "缺少扫描时的引用检查证据，请重新扫描"
        }
        let projects = sdkDirectories(in: codeRoots, home: home)
        let scan = referenceScan(to: path, projects: projects.entries,
                                 projectComplete: projects.complete, projectUnknown: projects.unknown, home: home)
        let current = ScanState(scan: scan, codeRoots: codeRoots, home: home,
                                androidHome: androidHome, standard: home + "/Library/Android/sdk")
        guard current.home == scanned.home, current.standard == scanned.standard,
              current.codeRoots == scanned.codeRoots, current.androidHome == scanned.androidHome else {
            return "扫描范围或 SDK 环境（ANDROID_HOME / 标准位置）已变化，请重新扫描"
        }
        let added = Set(current.references).subtracting(scanned.references)
        if !added.isEmpty {
            let named = added.sorted().prefix(3).joined(separator: "、") + (added.count > 3 ? " 等" : "")
            return "扫描后有新的引用（\(named)），请重新扫描"
        }
        guard current.fingerprint == scanned.fingerprint else {
            return "引用或检查状态在扫描后发生变化，请重新扫描"
        }
        return nil
    }

    static func currentAndroidHome() -> String? {
        getenv("ANDROID_HOME").map { String(cString: $0) }
    }

    static func hasSdkLayout(_ dir: String) -> Bool {
        required.allSatisfy { isDirectory(dir + "/" + $0) }
    }

    /// 扫描时向用户展示的引用与完整性证据。执行前按同一范围重算，指纹一致才允许沿用旧预览。
    private struct ScanState: Codable, Equatable {
        var version = 1
        var complete: Bool
        var references: [String]
        var unknown: [String]
        var androidHome: String?
        var standard: String
        var codeRoots: [String]
        var home: String

        init(scan: ReferenceScan, codeRoots: [String], home: String, androidHome: String?, standard: String) {
            complete = scan.complete
            references = scan.references
            unknown = scan.unknown
            self.androidHome = androidHome.flatMap { $0.isEmpty ? nil : SdkCopyProbe.canonical($0) }
            self.standard = SdkCopyProbe.canonical(standard)
            self.codeRoots = codeRoots.map(SdkCopyProbe.canonical).sorted()
            self.home = SdkCopyProbe.canonical(home)
        }

        var fingerprint: String {
            var parts = ["sdkCopy/v\(version)", "complete=\(complete)", "home=\(home)",
                         "standard=\(standard)", "android=\(androidHome ?? "-")",
                         "roots=\(codeRoots.count)"]
            parts += codeRoots
            parts.append("references=\(references.count)")
            parts += references
            parts.append("unknown=\(unknown.count)")
            parts += unknown
            let text = parts.map { "\($0.utf8.count):\($0)" }.joined(separator: "\n")
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        var encoded: String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        static func decode(_ text: String) -> ScanState? {
            guard let data = text.data(using: .utf8),
                  let state = try? JSONDecoder().decode(ScanState.self, from: data),
                  state.version == 1 else { return nil }
            return state
        }
    }

    private struct ReferenceScan {
        var references: [String] = []
        var unknown: [String] = []
        var complete = true
    }

    private enum PropertiesResult {
        case none
        case sdk(String)
        case unknown(String)
    }

    private enum TextResult {
        case missing
        case text(String)
        case unknown(String)
    }

    private enum DirectoryResult {
        case missing
        case entries([String])
        case unknown(String)
    }

    /// 在代码根下有界查找项目的 local.properties，收集 sdk.dir 指向的目录。
    /// 读不到、文件过大、不是普通文件、深度或预算截断都不算完整。
    static func sdkDirectories(in roots: [String], directoryLimit: Int = projectDirectoryLimit,
                               home: String = HOME)
        -> (entries: [(file: String, sdk: String)], complete: Bool, unknown: [String]) {
        var entries: [(file: String, sdk: String)] = [], complete = true, visited = 0
        var unknown: [String] = []
        let deadline = Date().addingTimeInterval(projectSecondsBudget)
        for root in roots {
            var rootStat = stat()
            guard lstat(root, &rootStat) == 0 else {
                unknown.append(shown(root, home: home) + "：代码目录不存在或无法读取")
                complete = false
                continue
            }
            guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
                unknown.append(shown(root, home: home) + "：代码目录不是目录")
                complete = false
                continue
            }
            var stack = [(root, 0)]
            while let (dir, depth) = stack.popLast() {
                guard visited < directoryLimit, Date() < deadline else { complete = false; break }
                visited += 1
                let properties = dir + "/local.properties"
                switch sdkDirectory(inProperties: properties) {
                case .sdk(let sdk): entries.append((properties, sdk))
                case .unknown(let why):
                    unknown.append(shown(properties, home: home) + "：" + why)
                    complete = false
                case .none: break
                }
                let children: [DirEntry]
                do { children = try readDir(dir) }
                catch {
                    unknown.append(shown(dir, home: home) + "：无法读取目录")
                    complete = false
                    continue
                }
                let dirs = children.filter { child in
                    child.isDir && !skipped.contains(child.name)
                        && (!child.name.hasPrefix(".") || child.name == ".worktrees")
                }
                if depth >= projectDepth {
                    // 更深一层还有项目目录：本次没有继续走，不能宣称已经查完
                    if !dirs.isEmpty { complete = false }
                    continue
                }
                for child in dirs { stack.append((dir + "/" + child.name, depth + 1)) }
            }
        }
        return (entries, complete, unknown)
    }

    /// sdk.dir=/Users/me/Library/Android/sdk（Java properties 会把 : 写成 \:）
    private static func sdkDirectory(inProperties path: String) -> PropertiesResult {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return errno == ENOENT ? .none : .unknown("无法读取")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { return .unknown("不是普通文件") }
        guard metadata.st_size <= propertiesLimit else { return .unknown("文件过大（\(metadata.st_size) 字节）") }
        guard let text = readSmallText(path, limit: propertiesLimit) else { return .unknown("无法读取或不是 UTF-8") }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("sdk.dir"), let eq = trimmed.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\:", with: ":").replacingOccurrences(of: "\\=", with: "=")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return value.hasPrefix("/") ? .sdk(value) : .unknown("sdk.dir 不是绝对路径")
        }
        return .none
    }

    /// 谁还指着这份 SDK（给人看的名字）：项目的 local.properties、shell 启动文件、后台服务、模拟器。
    /// 同时收集读不到/无法解析的来源：这些不是“没有引用”，而是本次检查不完整。
    private static func referenceScan(to sdk: String, projects: [(file: String, sdk: String)],
                                      projectComplete: Bool, projectUnknown: [String], home: String) -> ReferenceScan {
        var scan = ReferenceScan(complete: projectComplete)
        scan.unknown += projectUnknown
        let real = canonical(sdk)
        scan.references += projects.filter {
            let p = canonical($0.sdk)
            return p == real || p.hasPrefix(real + "/")
        }.map { shown($0.file, home: home) }
        let spellings = Self.spellings(of: [sdk, real], home: home)
        for name in shellFiles {
            switch text(at: home + "/" + name, limit: 1 << 20) {
            case .missing: continue
            case .text(let text):
                if mentions(text, spellings) { scan.references.append("~/" + name) }
            case .unknown(let why):
                scan.unknown.append("~/" + name + "：" + why)
                scan.complete = false
            }
        }
        let agents = home + "/Library/LaunchAgents"
        switch directory(at: agents) {
        case .missing: break
        case .unknown(let why):
            scan.unknown.append("~/Library/LaunchAgents：" + why)
            scan.complete = false
        case .entries(let names):
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = agents + "/" + name
                guard let data = FileManager.default.contents(atPath: path) else {
                    scan.unknown.append("后台服务配置 " + name + "：无法读取")
                    scan.complete = false
                    continue
                }
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                    scan.unknown.append("后台服务配置 " + name + "：无法解析")
                    scan.complete = false
                    continue
                }
                if strings(in: plist).contains(where: { mentions($0, spellings) }) {
                    let label = (plist as? [String: Any])?["Label"] as? String ?? name
                    scan.references.append("后台服务 " + label)
                }
            }
        }
        let avds = home + "/.android/avd"
        switch directory(at: avds) {
        case .missing: break
        case .unknown(let why):
            scan.unknown.append("~/.android/avd：" + why)
            scan.complete = false
        case .entries(let names):
            for name in names.sorted() where name.hasSuffix(".avd") {
                let dir = avds + "/" + name, label = "模拟器 " + name.dropLast(4)
                var used = false, hasConfig = false, unknownWhy: String?
                for file in ["config.ini", "hardware-qemu.ini"] {
                    switch text(at: dir + "/" + file, limit: 1 << 20) {
                    case .missing: continue
                    case .text(let text):
                        hasConfig = true
                        if mentions(text, spellings) { used = true }
                    case .unknown(let why):
                        hasConfig = true
                        unknownWhy = file + "：" + why
                    }
                }
                if used { scan.references.append(label) }
                if let unknownWhy {
                    scan.unknown.append(label + "：" + unknownWhy)
                    scan.complete = false
                } else if !hasConfig {
                    scan.unknown.append(label + "：缺少配置文件")
                    scan.complete = false
                }
            }
        }
        scan.references = Array(Set(scan.references)).sorted()
        scan.unknown = Array(Set(scan.unknown)).sorted()
        return scan
    }

    /// 同一个目录在配置文件里的写法：绝对路径（含解析符号链接后的），以及家目录下的 ~、$HOME、${HOME}
    private static func spellings(of paths: [String], home: String) -> [String] {
        var out: [String] = []
        for path in Set(paths) {
            out.append(path)
            if path.hasPrefix(home + "/") {
                let rest = path.dropFirst(home.count)
                out += ["~" + rest, "$HOME" + rest, "${HOME}" + rest]
            }
        }
        return out
    }

    /// 文本里出现了其中某个写法，且前后都在路径边界上：…/android-sdk 不算提到了 …/android-sdk-old
    private static func mentions(_ text: String, _ spellings: [String]) -> Bool {
        func continues(_ c: Character) -> Bool { c.isLetter || c.isNumber || "._-+@~%".contains(c) }
        for spelling in spellings {
            var from = text.startIndex
            while let found = text.range(of: spelling, range: from..<text.endIndex) {
                let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
                if before.map({ !continues($0) && $0 != "/" }) ?? true, after.map({ !continues($0) }) ?? true { return true }
                from = found.upperBound
            }
        }
        return false
    }

    private static func strings(in value: Any) -> [String] {
        if let s = value as? String { return [s] }
        if let a = value as? [Any] { return a.flatMap(strings) }
        if let d = value as? [String: Any] { return d.values.flatMap(strings) }
        return []
    }

    private static func text(at path: String, limit: Int) -> TextResult {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return errno == ENOENT ? .missing : .unknown("无法读取")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { return .unknown("不是普通文件") }
        guard metadata.st_size <= limit else { return .unknown("文件过大（\(metadata.st_size) 字节）") }
        guard let text = readSmallText(path, limit: limit) else { return .unknown("无法读取或不是 UTF-8") }
        return .text(text)
    }

    private static func directory(at path: String) -> DirectoryResult {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            return errno == ENOENT ? .missing : .unknown("无法读取")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { return .unknown("不是目录") }
        do { return .entries(try FileManager.default.contentsOfDirectory(atPath: path)) }
        catch { return .unknown("无法读取目录") }
    }

    private static func shown(_ path: String, home: String = HOME) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func canonical(_ path: String) -> String {
        realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? GitRepositoryDiscovery.normalizedPath(path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
