// SPDX-License-Identifier: MPL-2.0
// 正在运行的进程可能还在用某些缓存：删了会让它崩溃或出错，所以这类条目进"不能删"并写明怎么解除。

import Foundation

struct RunningOwners: Equatable {
    let commands: [String]
    /// 每个 go run 都已经跑起了它编译出的程序（编译已结束、只剩程序在跑）。只在 capture 时核实；
    /// 默认 false：go run 一律当作可能还在编译
    var goRunsLaunched = false
    /// 命令行里所有路径在边界处的前缀（/a、/a/b、/a/b/c）。usesDirectory 每个项目都要查一遍：
    /// 近千条命令逐条做子串搜索要几十秒，先切好一次，之后每次查询就是一次集合查找
    private let directoryIndex: Set<String>
    /// 命令行里完整的一段段路径（directoryIndex 是它们在每个 / 处的前缀）
    private let pathRuns: Set<String>
    /// 规则和整块清理的所有者是否在运行，只取决于进程列表：先算好，别让清单里每一项都把近千条命令重新切一遍
    private let xcodeRunning: Bool, xcodeBuildMCPRunning: Bool, gradleDaemonRunning: Bool
    private let toolsRunning: Set<ToolCleanCommand>
    /// go 的命令里有没有 go run 以外的（go build、go test…）
    private let goBuildCommand: Bool

    init(commands: [String], goRunsLaunched: Bool = false) {
        self.commands = commands
        self.goRunsLaunched = goRunsLaunched
        (directoryIndex, pathRuns) = Self.index(commands)
        xcodeRunning = commands.contains(where: Self.runsXcode)
        xcodeBuildMCPRunning = commands.contains(where: Self.runsXcodeBuildMCP)
        gradleDaemonRunning = commands.contains { $0.contains("org.gradle.launcher.daemon") }
        toolsRunning = Set(ToolCleanCommand.allCases.filter { c in commands.contains { Self.runs(c, command: $0) } })
        goBuildCommand = commands.contains { Self.runs(.goBuildCache, command: $0) && !Self.isGoRun($0) }
    }

    /// 路径字符：与 usesDirectory 的边界规则一致（字母、数字、._-+@~% 算"还在同一个名字里"），外加 /
    private static func continues(_ c: Character) -> Bool { c.isLetter || c.isNumber || "._-+@~%".contains(c) }
    private static func pathCharacter(_ c: Character) -> Bool { c == "/" || continues(c) }

    /// 每段以 / 开头、前面不是路径字符的连续路径字符，记下它在每个 / 处和结尾处的前缀，以及整段本身
    private static func index(_ commands: [String]) -> (prefixes: Set<String>, runs: Set<String>) {
        var out = Set<String>(), runs = Set<String>()
        for command in commands {
            var run = "", inRun = false, previous: Character? = nil
            func finish() { if inRun, run.count > 1 { out.insert(run); runs.insert(run) }; inRun = false; run = "" }
            for c in command {
                if inRun {
                    if pathCharacter(c) {
                        if c == "/", run.count > 1 { out.insert(run) }
                        run.append(c)
                    } else { finish() }
                } else if c == "/", previous.map({ !pathCharacter($0) }) ?? true {
                    inRun = true; run = "/"
                }
                previous = c
            }
            finish()
        }
        return (out, runs)
    }

    private static let xcodeRules: Set<String> = ["Xcode DerivedData", "XcodeBuildMCP 工作区", DerivedDataCopyProbe.rule]
    private static let gradleRules: Set<String> = ["Gradle 缓存", "Gradle 旧版本 wrapper"]
    /// 需要检查运行状态的规则；capture 失败时这些条目降为 C
    static let watchedRules = xcodeRules.union(gradleRules)

    /// Xcode 本体：Xcode.app、Xcode-beta.app、Xcode-16.2.0.app、Xcode_15.4.app 里的主程序
    private static let xcodeApp = "/Xcode([-_ ][^/]*)?\\.app/Contents/MacOS/Xcode$"
    static let xcodeBlocker = "Xcode 正在运行，关闭后重新扫描"
    static let xcodeBuildMCPBlocker = "XcodeBuildMCP 正在运行，结束后重新扫描"
    static let gradleBlocker = "Gradle 守护进程正在运行，执行 ./gradlew --stop 后重新扫描"
    static let unverifiedReason = "无法检查运行状态"

    /// 读不到进程列表（没有 ps、命令失败、超时）返回 nil，不能当成"没有进程在运行"
    static func capture(runner: CommandRunning, tools: ToolLocator) -> RunningOwners? {
        guard let ps = tools.path(for: .ps) else { return nil }
        let result = runner.run(ps, ["-axo", "command="], timeout: 10)
        guard result.ok else { return nil }
        let lines = result.stdout.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 空列表不是"没有进程在运行"：macOS 上 ps 至少会列出自己，空输出或只有空白行说明这次检查不可信
        guard !lines.isEmpty else { return nil }
        var owners = RunningOwners(commands: lines)
        // 开着的 go run 开发服务器不该一直锁住 Go 缓存：核实不了父子关系时仍按在编译处理
        if owners.commands.contains(where: isGoRun) { owners.goRunsLaunched = !CacheActivitySnapshot.unresolvedGoRun(runner: runner) }
        return owners
    }

    /// go run（与 CacheActivitySnapshot.unresolvedGoRun 认定父进程的方式一致）
    static func isGoRun(_ command: String) -> Bool {
        let args = command.split(separator: " ", omittingEmptySubsequences: true)
        return args.first.map { ($0 as NSString).lastPathComponent == "go" } == true && args.dropFirst().contains("run")
    }

    static let projectInUse = "有进程正在使用这个项目，结束后重新扫描"
    static let npxInUse = "有进程正在使用 npx 临时工具缓存，结束后重新扫描"
    /// 探测器发现的目录：有进程的命令行带着它就锁定（规则组 → 锁定原因）
    static let directoryUsers: [String: String] = [OwnerCachePolicy.npxRule: npxInUse, SdkCopyProbe.group: SdkCopyProbe.inUse,
                                                   ReleaseHistoryProbe.rule: ReleaseHistoryProbe.inUse]
    /// 读不到进程列表时要降为 C 的条目：除了所有者在跑会出事的规则，还有项目构建产物和按进程锁定的探测目录
    static let unverifiedRules = watchedRules.union(ProjectArtifactPolicy.rules).union(directoryUsers.keys)

    /// 有没有进程的命令行里带着这个目录。两侧都做路径边界检查：/a/b 不匹配 /a/bc，也不匹配 /x/a/b
    func usesDirectory(_ directory: String) -> Bool {
        let path = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        guard path.count > 1 else { return false }
        // 全由路径字符组成的绝对路径：出现在边界处、后面不是名字字符，正好就是索引里的某个前缀
        if path.hasPrefix("/"), path.allSatisfy(Self.pathCharacter) { return directoryIndex.contains(path) }
        return scansDirectory(path)
    }

    /// 命令行里落在 directory 之内（含它自己）的完整路径，比如 /p/server 之下的 /p/server/target/release/app。
    /// 只认索引能表示的情况；directory 含空格之类的字符、或有命令在别处以非路径方式提到它时返回 nil（调用方按整体在用处理）
    func pathsUsed(under directory: String) -> [String]? {
        let path = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        guard path.count > 1, path.hasPrefix("/"), path.allSatisfy(Self.pathCharacter) else { return nil }
        let found = pathRuns.filter { $0 == path || $0.hasPrefix(path + "/") }
        // 逐条搜索也认为在用、但索引里一段都没有：说明是以索引表示不了的方式出现的，不拆
        if found.isEmpty, scansDirectory(path) { return nil }
        return found.sorted()
    }

    /// 逐条命令搜索：路径里有空格之类的字符时用它（索引按这些字符切开了，查不到）
    func scansDirectory(_ path: String) -> Bool {
        let continues = Self.continues
        for command in commands {
            var from = command.startIndex
            while let found = command.range(of: path, range: from..<command.endIndex) {
                let before = found.lowerBound == command.startIndex ? nil : command[command.index(before: found.lowerBound)]
                let after = found.upperBound == command.endIndex ? nil : command[found.upperBound]
                if before.map({ !continues($0) && $0 != "/" }) ?? true, after.map({ !continues($0) }) ?? true { return true }
                from = found.upperBound
            }
        }
        return false
    }

    func blocker(forRule rule: String) -> String? {
        if Self.xcodeRules.contains(rule) {
            // 只认 Xcode 本体和 xcodebuild（按可执行文件判断，不按子串）。装在 Xcode 里的其他程序（DeviceHub、sourcekit-lsp）、
            // Xcodes.app（版本管理器）、名字里带 xcodebuild 的 MCP 服务都不算
            if xcodeRunning { return Self.xcodeBlocker }
            // XcodeBuildMCP 的工作区归它自己：它在运行只锁它的工作区
            if rule == "XcodeBuildMCP 工作区", xcodeBuildMCPRunning { return Self.xcodeBuildMCPBlocker }
            return nil
        }
        if Self.gradleRules.contains(rule) {
            return gradleDaemonRunning ? Self.gradleBlocker : nil
        }
        return nil
    }

    // MARK: - 包管理器整块清理的所有者

    static func toolBlocker(_ c: ToolCleanCommand) -> String {
        let name = c == .pipCache ? "pip" : c.tool.rawValue
        return "\(name) 正在运行，结束后重新扫描"
    }

    /// 整块清理命令的所有者（npm / go / pip / uv / pnpm / brew）是否在运行；docker builder prune 另查守护进程，这里不管
    func blocker(forTool c: ToolCleanCommand) -> String? {
        guard toolsRunning.contains(c) else { return nil }
        // go 的所有者里只有已经跑起程序的 go run：不再算在编译
        if (c == .goBuildCache || c == .goModCache), goRunsLaunched, !goBuildCommand { return nil }
        return Self.toolBlocker(c)
    }

    /// 按进程的可执行文件判断，不按子串：argv0 的文件名，或 node / bash / ruby 运行的工具入口脚本（npm-cli.js、brew.sh）。
    /// 一般的 node 进程、gopls、uvicorn、pipx、/x/my-npm/bin/tool 都不算
    /// argv0 是 Xcode 主程序，或文件名就是 xcodebuild
    static func runsXcode(_ command: String) -> Bool {
        guard let first = command.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) else { return false }
        return (first as NSString).lastPathComponent == "xcodebuild" || first.range(of: xcodeApp, options: .regularExpression) != nil
    }

    /// XcodeBuildMCP：某个参数是 xcodebuildmcp 本身（npm exec xcodebuildmcp@latest、node …/.bin/xcodebuildmcp）
    static func runsXcodeBuildMCP(_ command: String) -> Bool {
        command.split(separator: " ", omittingEmptySubsequences: true).prefix(4).contains { token in
            let name = (String(token) as NSString).lastPathComponent
            return name == "xcodebuildmcp" || name.hasPrefix("xcodebuildmcp@")
        }
    }

    static func runs(_ c: ToolCleanCommand, command: String) -> Bool {
        let args = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = args.first else { return false }
        func base(_ s: String) -> String { (s as NSString).lastPathComponent }
        let exe = base(first)
        let scripts = Set(args.dropFirst().map(base))
        switch c {
        case .npmCache:
            // npx 也读写同一个 _cacache；npm 7+ 的 npx 进程名就是 "npm exec …"
            return exe == "npm" || exe == "npx" || !scripts.isDisjoint(with: ["npm-cli.js", "npx-cli.js"])
        case .goBuildCache, .goModCache:
            return exe == "go"
        case .pipCache:
            if exe.range(of: "^pip[0-9.]*$", options: .regularExpression) != nil { return true }
            return zip(args, args.dropFirst()).contains { $0 == "-m" && $1 == "pip" }   // python3 -m pip
        case .uvCache:
            return exe == "uv" || exe == "uvx"
        case .pnpmStorePrune:
            return exe == "pnpm" || exe == "pnpx" || !scripts.isDisjoint(with: ["pnpm.cjs", "pnpm.mjs", "pnpm.js", "pnpx.cjs"])
        case .brewCleanup:
            return exe == "brew" || !scripts.isDisjoint(with: ["brew.sh", "brew.rb"])
        case .dockerBuilderPrune:
            return false
        }
    }

    /// 执行前复核：读不到进程列表也不执行（fail closed）。nil = 可以执行
    static func executionBlocker(forTool c: ToolCleanCommand, runner: CommandRunning, tools: ToolLocator) -> String? {
        guard c != .dockerBuilderPrune else { return nil }
        guard let running = capture(runner: runner, tools: tools) else { return "无法检查运行状态，请重新扫描" }
        return running.blocker(forTool: c)
    }

    /// capture 返回 nil 时：相关条目降为 C，写明为什么；已锁定或不相关的条目不动
    static func markUnverified(_ list: CleanupList) -> CleanupList {
        var result = list
        result.candidates = list.candidates.map { c in
            // 包管理器整块清理（toolClean）的所有者同样要查运行状态；docker builder prune 另查守护进程
            var wholeCache = false
            if case .toolClean(let command, _)? = c.action { wholeCache = command != .dockerBuilderPrune }
            guard c.entry.tier != .locked, unverifiedRules.contains(c.entry.group) || wholeCache,
                  c.entry.tierReason != unverifiedReason else { return c }
            return c.requiringReview(unverifiedReason)
        }
        return result
    }
}
