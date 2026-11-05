// SPDX-License-Identifier: GPL-3.0-only
// ~/.gradle/wrapper/dists 里没有任何项目引用的 Gradle 发行版：gradlew 需要时会自己重新下载，进 A。
// 引用关系来自代码目录下各项目的 gradle/wrapper/gradle-wrapper.properties 的 distributionUrl。

import Foundation

enum GradleWrapperProbe {
    static let rule = "Gradle 旧版本 wrapper"
    private static let maxDepth = 6
    private static let directoryLimit = 50_000
    private static let secondsBudget: TimeInterval = 5
    private static let skipped: Set<String> = ["node_modules", ".git", "build"]

    /// sizeOf：发现阶段传入统一的大小登记函数；nil = 自己量
    static func candidates(home: String = HOME, codeRoots: [String], sizeOf: ((String) -> UInt64?)? = nil) -> [CleanupCandidate] {
        let dists = home + "/.gradle/wrapper/dists"
        guard let entries = try? readDir(dists) else { return [] }
        let names = entries.filter(\.isDir).map(\.name).filter { !$0.hasPrefix(".") }.sorted()
        guard !names.isEmpty else { return [] }
        let found = referencedDistributions(in: codeRoots)
        let sizes = sizeOf == nil ? BulkWalker().measureTargets(names.map { dists + "/" + $0 }) : [:]
        return names.filter { !found.names.contains($0) }.map { name in
            let path = dists + "/" + name
            let size = sizeOf?(path) ?? sizes[path] ?? 0
            let evidence = "没有找到引用这个 Gradle 版本的项目；用到时 gradlew 会自动重新下载"
            let item = ScanItem.trashTarget(path: path, name: name, size: size, rule: rule, evidence: evidence, risk: .amber)
            let candidate = OwnerCachePolicy.ownedCandidate(item, title: rule + " · " + name, role: "gradle-wrapper")
            return found.complete
                ? candidate.retiered(.obsolete, reason: "没有项目引用这个 Gradle 版本，gradlew 用到时会自动重新下载；可从废纸篓找回")
                : candidate.retiered(.review, reason: "代码目录太大，没能查完所有项目的引用；请核实后再清")
        }
    }

    /// 在代码根下有界查找 gradle/wrapper/gradle-wrapper.properties，收集 distributionUrl 指向的发行名（如 gradle-9.4.0-bin）
    static func referencedDistributions(in roots: [String]) -> (names: Set<String>, complete: Bool) {
        var names = Set<String>(), complete = true, visited = 0
        let deadline = Date().addingTimeInterval(secondsBudget)
        for root in roots {
            var stack = [(root, 0)]
            while let (dir, depth) = stack.popLast() {
                guard visited < directoryLimit, Date() < deadline else { complete = false; break }
                visited += 1
                if let name = distribution(inProperties: dir + "/gradle/wrapper/gradle-wrapper.properties") { names.insert(name) }
                guard depth < maxDepth else { continue }
                guard let children = try? readDir(dir) else { continue }
                for child in children where child.isDir && !skipped.contains(child.name)
                    && (!child.name.hasPrefix(".") || child.name == ".worktrees") {
                    stack.append((dir + "/" + child.name, depth + 1))
                }
            }
        }
        return (names, complete)
    }

    /// distributionUrl=https\://services.gradle.org/distributions/gradle-9.4.0-bin.zip → gradle-9.4.0-bin
    static func distribution(inProperties path: String) -> String? {
        guard let text = readSmallText(path) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("distributionUrl"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\:", with: ":")
            var leaf = (value as NSString).lastPathComponent
            if leaf.hasSuffix(".zip") { leaf = String(leaf.dropLast(4)) }
            return leaf.isEmpty ? nil : leaf
        }
        return nil
    }
}

/// 读一个不大的普通文本文件（不跟随符号链接，不阻塞在 FIFO 上）；不存在、太大、不是普通文件或不是 UTF-8 时返回 nil
func readSmallText(_ path: String, limit: Int = 65_536) -> String? {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= limit else { return nil }
    var data = [UInt8](repeating: 0, count: Int(metadata.st_size))
    guard read(fd, &data, data.count) == data.count else { return nil }
    return String(bytes: data, encoding: .utf8)
}
