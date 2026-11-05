// SPDX-License-Identifier: GPL-3.0-only
// 常见路径、Git 仓库标记和开发工具工作记录共同确定扫描范围。

import Foundation

enum CodeRoots {
    struct Configuration {
        let roots: [String]
        let automatic: [String]
        let manual: [CodeRootStatus]
        let warnings: [String]
        /// 用户已在首次启动时选过：roots 只含选中的目录（可能为空），自动发现的只作候选
        var chosen = false
    }

    static func configuration(store: CodeRootStore = .shared, automatic: [String]? = nil,
                              includeAutomaticCandidates: Bool = true) -> Configuration {
        do {
            let manual = try store.statuses(), chosen = try store.isChosen()
            // A saved choice is already the entire active scope. The picker still requests automatic
            // candidates; a scan need not rediscover unused suggestions before reading the chosen roots.
            // Before a choice (or on configuration failure below), automatic roots remain active as before.
            let automatic = automatic ?? (includeAutomaticCandidates || !chosen ? automaticCodeRoots : [])
            // Explicit starts get their own depth/time budget, including when an
            // automatic ancestor already exists. Do not collapse them away.
            let selected = manual.filter { $0.state == "available" }.map(\.path).sorted()
            let roots = chosen ? selected : selected + automatic.filter { !selected.contains($0) }
            return .init(roots: roots, automatic: automatic, manual: manual,
                warnings: manual.filter { $0.state != "available" }.map { $0.path + "：" + $0.reason }, chosen: chosen)
        } catch {
            let automatic = automatic ?? automaticCodeRoots
            return .init(roots: automatic, automatic: automatic, manual: [], warnings: [error.localizedDescription])
        }
    }
    private static let systemTops: Set<String> = ["System", "Library", "private", "usr", "bin", "sbin",
                                                   "etc", "tmp", "var", "dev", "cores", "Applications", "Users"]

    /// "-opt-projects-team-github-Roomy" → "/opt/projects/team/github/Roomy"。
    /// 目录名本身可能含 "-"，所以逐段尝试 "/" 和 "-" 两种拼法，返回已存在的最长路径。
    static func decodeProjectName(_ name: String, isDir: (String) -> Bool) -> String? {
        guard name.hasPrefix("-") else { return nil }
        let tokens = name.dropFirst().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var best: String?
        func walk(_ index: Int, _ path: String) {
            if index == tokens.count { if best == nil || path.count > best!.count { best = path }; return }
            let token = tokens[index]
            let slash = path + "/" + token
            var advanced = false
            if isDir(slash) { advanced = true; walk(index + 1, slash) }
            if !path.isEmpty, isDir(path + "-" + token) { advanced = true; walk(index + 1, path + "-" + token) }
            // 这条路径还有尝试（形如 "my-app" 的中间段可能本身不存在）
            if !advanced, index + 1 < tokens.count {
                let joined = path + "/" + token + "-" + tokens[index + 1]
                if isDir(joined) { advanced = true; walk(index + 2, joined) }
            }
            if !advanced, !path.isEmpty, best == nil || path.count > best!.count { best = path }
        }
        walk(0, "")
        return best
    }

    /// 家目录内取 ~/<第一层>，家目录外取 /<前两层>；去掉系统目录、隐藏目录和互相包含的根。
    static func roots(from paths: [String], home: String) -> [String] {
        var out = Set<String>()
        for raw in paths {
            guard raw.hasPrefix("/") else { continue }
            let path = GitRepositoryDiscovery.normalizedPath(raw)
            if path.hasPrefix(home + "/") {
                guard let first = path.dropFirst(home.count + 1).split(separator: "/").first,
                      !first.hasPrefix("."), first != "Library" else { continue }
                out.insert(home + "/" + first)
            } else {
                let parts = path.split(separator: "/").map(String.init)
                guard parts.count >= 2, !systemTops.contains(parts[0]) else { continue }
                out.insert("/" + parts[0] + "/" + parts[1])
            }
        }
        let sorted = out.sorted()
        return sorted.filter { root in !sorted.contains { $0 != root && root.hasPrefix($0 + "/") } }
    }

    static func discover(home: String = HOME, projectsDir: String? = nil, includeGit: Bool = true,
                         isDir: (String) -> Bool = isDirectory) -> [String] {
        let dir = projectsDir ?? home + "/.claude/projects"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var paths = names.compactMap { decodeProjectName($0, isDir: isDir) }
        if includeGit {
            let guarded = ["Documents", "Desktop", "Downloads", "Library", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
            paths += GitRepositoryDiscovery.discover(searchRoots: [home, "/opt"], excluded: guarded).repositories
        }
        return roots(from: paths, home: home)
    }
}

extension CodeRoots {
    /// Agent-managed checkouts are development projects too. Keep this separate
    /// from the user's saved choices, and share it with discovery and revalidation.
    static func scanRoots(_ selected: [String], home: String = HOME,
                          isDir: (String) -> Bool = isDirectory) -> [String] {
        let worktrees = home + "/.codex/worktrees"
        var seen = Set<String>()
        return (selected + (isDir(worktrees) ? [worktrees] : [])).filter {
            seen.insert(GitRepositoryDiscovery.normalizedPath($0)).inserted
        }
    }

    /// 落在文稿 / 桌面 / 下载里的代码目录：读它们会弹授权框，只能放到清单之后
    static func splitProtected(_ roots: [String], home: String = HOME) -> (fast: [String], protected: [String]) {
        let guarded = ["Documents", "Desktop", "Downloads"].map { home + "/" + $0 }
        let isProtected = { (r: String) in guarded.contains { r == $0 || r.hasPrefix($0 + "/") } }
        return (roots.filter { !isProtected($0) }, roots.filter(isProtected))
    }
}

/// 常见目录 + Git 仓库发现 + 开发工具工作记录。
private let automaticCodeRoots: [String] = {
    let combined = CODE_ROOTS.filter { isDirectory($0) } + CodeRoots.discover()
    let unique = Array(Set(combined)).sorted()
    return unique.filter { root in !unique.contains { $0 != root && root.hasPrefix($0 + "/") } }
}()

var ALL_CODE_ROOTS: [String] { CodeRoots.scanRoots(CodeRoots.configuration().roots) }
