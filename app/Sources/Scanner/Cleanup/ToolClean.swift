// SPDX-License-Identifier: MPL-2.0
// 官方整体清理命令：让包管理器自己清空它管理的整个缓存。执行前再问一次工具"缓存在哪"，
// 和用户预览时的范围对不上就不动手。

import Darwin
import Foundation

enum ToolCleanCommand: String, Codable, CaseIterable {
    case npmCache, goBuildCache, goModCache, pipCache, uvCache, pnpmStorePrune, brewCleanup, dockerBuilderPrune

    var tool: Tool {
        switch self {
        case .npmCache: return .npm
        case .goBuildCache, .goModCache: return .go
        case .pipCache: return .pip3
        case .uvCache: return .uv
        case .pnpmStorePrune: return .pnpm
        case .brewCleanup: return .brew
        case .dockerBuilderPrune: return .docker
        }
    }

    var arguments: [String] {
        switch self {
        case .npmCache: return ["cache", "clean", "--force", "--no-update-notifier"]   // 不去 registry 查新版本
        case .goBuildCache: return ["clean", "-cache"]
        case .goModCache: return ["clean", "-modcache"]
        case .pipCache: return ["cache", "purge"]
        case .uvCache: return ["cache", "clean"]
        case .pnpmStorePrune: return ["store", "prune"]
        case .brewCleanup: return ["cleanup"]
        case .dockerBuilderPrune: return ["builder", "prune", "-f"]
        }
    }

    /// 向工具询问缓存位置的参数；nil = 没有范围查询（docker 改查守护进程状态）
    var scopeQuery: [String]? {
        switch self {
        case .npmCache: return ["config", "get", "cache", "--no-update-notifier"]
        case .goBuildCache: return ["env", "GOCACHE"]
        case .goModCache: return ["env", "GOMODCACHE"]
        case .pipCache: return ["cache", "dir"]
        case .uvCache: return ["cache", "dir"]
        case .pnpmStorePrune: return ["store", "path"]
        case .brewCleanup: return ["--cache"]
        case .dockerBuilderPrune: return nil
        }
    }

    /// 清完能不能直接用预览时测的大小当作释放量；prune / cleanup 只清一部分，大小不可知
    var exactSize: Bool {
        switch self {
        case .npmCache, .goBuildCache, .goModCache, .pipCache, .uvCache: return true
        case .pnpmStorePrune, .brewCleanup, .dockerBuilderPrune: return false
        }
    }

    /// 完整命令的可读形式，如 "npm cache clean --force"（不含只为离线加的开关）
    var label: String { ([tool.rawValue] + arguments.filter { $0 != "--no-update-notifier" }).joined(separator: " ") }

    /// 清单上的动作说明。brew cleanup 不只清下载缓存，还会删除已安装软件包的旧版本，不能写成"清空"
    var actionLabel: String { self == .brewCleanup ? "用 brew cleanup 删除旧版本软件包和下载缓存" : "用 \(label) 清空" }

    /// 整块清理不可撤回：被超时杀掉就停在删到一半的状态，所以给足 30 分钟（go clean -modcache 逐个删只读目录，最慢）
    static let wholeCacheTimeout: TimeInterval = 1800
    var timeout: TimeInterval { Self.wholeCacheTimeout }
}

enum ToolCleanScope {
    /// 问工具当前的缓存位置，换算成预览时展示的范围；查不到返回 nil
    static func resolve(_ c: ToolCleanCommand, runner: CommandRunning, tools: ToolLocator) -> String? {
        guard let reported = reportedPath(c, runner: runner, tools: tools) else { return nil }
        return c == .npmCache ? reported + "/_cacache" : reported
    }

    /// nil = 可以执行；否则是不执行的原因
    static func blocker(_ c: ToolCleanCommand, expected: String, runner: CommandRunning, tools: ToolLocator) -> String? {
        if c == .dockerBuilderPrune { return DockerProbe.daemonBlocker(runner: runner, tools: tools) }
        guard tools.path(for: c.tool) != nil else { return "找不到 \(c.tool.rawValue)" }
        guard expected.hasPrefix("/"), expected != "/" else { return "预期清理范围不合法，请重新扫描" }
        var info = stat()
        if lstat(expected, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            return "预期清理范围是符号链接，Roomy 不会通过它清理"
        }
        guard let reported = resolve(c, runner: runner, tools: tools) else {
            return "无法确认 \(c.tool.rawValue) 的缓存位置，请重新扫描"
        }
        let want = canonical(expected), got = canonical(reported)
        // pnpm 的 store 位置带版本子目录：只要在预览的范围之内就算一致
        let matches = c == .pnpmStorePrune ? (got == want || got.hasPrefix(want + "/")) : got == want
        return matches ? nil : "\(c.tool.rawValue) 现在报告的缓存位置是 \(reported)，和预览时的 \(expected) 不一致，请重新扫描"
    }

    private static func reportedPath(_ c: ToolCleanCommand, runner: CommandRunning, tools: ToolLocator) -> String? {
        guard let query = c.scopeQuery, let exe = tools.path(for: c.tool) else { return nil }
        let r = ToolInvocation.run(c.tool, executable: exe, query, runner: runner, tools: tools, timeout: 10)
        guard r.ok else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path != "/", !path.contains("\n") else { return nil }
        return path
    }

    /// realpath；路径还不存在时，解析最深的已存在祖先再接上剩余部分
    static func canonical(_ path: String) -> String {
        var existing = path, rest: [String] = []
        while existing != "/", !existing.isEmpty {
            if let p = realpath(existing, nil) {
                defer { free(p) }
                return ([String(cString: p)] + rest.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            }
            rest.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return path
    }
}

/// 包管理器命令的运行方式（范围查询和整体清理共用）：
/// - PATH 补上工具自己的目录、ToolLocator 的搜索目录和系统目录。Finder 启动的应用 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
///   npm、pnpm 这类 `#!/usr/bin/env node` 脚本否则找不到 node
/// - 工作目录固定为 HOME：不读调用方所在项目的 .npmrc、go.mod 等
/// - go 设 GOTOOLCHAIN=local：go.mod 的 toolchain 指令不能让查询去下载工具链
/// - brew 设 HOMEBREW_NO_AUTO_UPDATE=1 和 HOMEBREW_NO_AUTOREMOVE=1：不联网更新，不删预览之外的软件包
enum ToolInvocation {
    static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func environment(for tool: Tool, executable: String, tools: ToolLocator,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let inherited = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>(), path: [String] = []
        for dir in [(executable as NSString).deletingLastPathComponent] + tools.searchDirectories + systemDirectories + inherited
            where !dir.isEmpty && seen.insert(dir).inserted { path.append(dir) }
        env["PATH"] = path.joined(separator: ":")
        if tool == .go { env["GOTOOLCHAIN"] = "local" }
        if tool == .brew {
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            // brew cleanup 默认还会 autoremove 没人依赖的软件包（Homebrew cleanup.rb：除非 HOMEBREW_NO_AUTOREMOVE）；
            // 那超出了预览给用户看的范围，所以关掉
            env["HOMEBREW_NO_AUTOREMOVE"] = "1"
        }
        return env
    }

    static func run(_ tool: Tool, executable: String, _ arguments: [String], runner: CommandRunning,
                    tools: ToolLocator, timeout: TimeInterval) -> CommandResult {
        runner.run(executable, arguments, environment: environment(for: tool, executable: executable, tools: tools),
                   directory: HOME, timeout: timeout)
    }
}
