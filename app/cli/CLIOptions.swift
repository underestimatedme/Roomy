// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct CLIOptions {
    var command = "scan"
    var root = NSHomeDirectory()
    var subject: String?
    var ids: [String] = []
    var query = ""
    var filesOnly = false
    var minBytes: UInt64 = 0
    var limit = 20
    var offset = 0
    var json: String?
    var apply = false
    var yes = false
    var noOverview = false
    var legacy = false
    var tierAction: String?
    var tier: CleanupTier?
    var scheduleAction: String?
    var everyDays: Int?
    var scheduleScopes: [String] = []
    var once = false

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions(), args = arguments[...]
        let commands: Set<String> = ["scan", "disk", "apps", "preview", "clean", "uninstall", "history", "restore", "protect", "help", "version", "permissions", "growth", "tier", "schedule"]
        if arguments.contains("--help") || arguments.contains("-h") { options.command = "help"; return options }
        if arguments == ["--version"] { options.command = "version"; return options }
        if let first = args.first, !first.hasPrefix("-") {
            guard commands.contains(first) else { throw cliError("未知命令：\(first)。使用 roomy --help 查看用法。") }
            options.command = args.removeFirst()
        }
        var positionals: [String] = []
        var seen = Set<String>()
        func value(_ flag: String) throws -> String {
            guard let next = args.first, !next.hasPrefix("--"), !next.isEmpty else { throw cliError("\(flag) 缺少值") }
            return args.removeFirst()
        }
        while let flag = args.first {
            args.removeFirst()
            if flag == "--" { positionals += args; break }
            if !flag.hasPrefix("-") { positionals.append(flag); continue }
            guard flag == "--id" || flag == "--scope" || seen.insert(flag).inserted else { throw cliError("重复参数：\(flag)") }
            switch flag {
            case "--root": options.root = try value(flag)
            case "--index-root": options.command = "disk"; options.root = try value(flag)
            case "--index-json": options.json = try value(flag)
            case "--json":
                options.json = "-"
                if let next = args.first, next == "-" || !next.hasPrefix("-") { options.json = args.removeFirst() }
            case "--query": options.query = try value(flag)
            case "--files": options.filesOnly = true
            case "--id": options.ids.append(try value(flag))
            case "--min-bytes":
                guard let n = UInt64(try value(flag)) else { throw cliError("--min-bytes 必须为非负整数") }; options.minBytes = n
            case "--limit", "--top":
                guard let n = Int(try value(flag)), (1...200).contains(n) else { throw cliError("\(flag) 必须在 1–200 之间") }; options.limit = n
            case "--offset":
                guard let n = Int(try value(flag)), n >= 0 else { throw cliError("--offset 必须为非负整数") }; options.offset = n
            case "--apply": options.apply = true
            case "--yes": options.yes = true
            case "--no-overview": options.noOverview = true
            case "--legacy-rules": options.legacy = true
            case "--every-days":
                guard let days = Int(try value(flag)), (1...3650).contains(days) else { throw cliError("--every-days 必须在 1–3650 之间") }
                options.everyDays = days
            case "--scope": options.scheduleScopes.append(try value(flag))
            case "--once": options.once = true
            default: throw cliError("未知参数：\(flag)。使用 roomy --help 查看用法。")
            }
        }
        let common: Set<String> = ["--json"]
        let allowed: [String: Set<String>] = [
            "scan": ["--root", "--top", "--legacy-rules"],
            "disk": ["--root", "--index-root", "--index-json", "--files", "--query", "--min-bytes", "--limit", "--offset"],
            "apps": ["--query", "--limit", "--offset"], "preview": [],
            "clean": ["--id", "--apply", "--yes", "--no-overview"], "uninstall": ["--id", "--apply", "--yes"],
            "permissions": [], "growth": [], "tier": ["--apply", "--yes"],
            "schedule": ["--every-days", "--once", "--apply", "--yes"],
            "history": [], "restore": ["--apply", "--yes"], "protect": [], "help": [], "version": []]
        guard seen.isSubset(of: common.union(allowed[options.command] ?? [])),
              options.ids.isEmpty || ["clean", "uninstall"].contains(options.command) else { throw cliError("此命令不支持所提供的参数") }
        guard options.scheduleScopes.isEmpty || options.command == "schedule" else { throw cliError("--scope 仅用于定时清理") }
        if options.command == "schedule" {
            let usage = "用法：roomy schedule scopes|list|history|status|install|uninstall|run|add NAME|enable ID|disable ID|remove ID|acknowledge RUNID"
            guard let action = positionals.first else { throw cliError(usage) }
            let needsSubject = ["add", "enable", "disable", "remove", "acknowledge"].contains(action)
            guard needsSubject || ["scopes", "list", "history", "status", "install", "uninstall", "run"].contains(action),
                  positionals.count == (needsSubject ? 2 : 1) else { throw cliError(usage) }
            options.scheduleAction = positionals.removeFirst()
            if needsSubject { options.subject = positionals.removeFirst() }
            if action == "add" {
                guard options.everyDays != nil, !options.scheduleScopes.isEmpty,
                      Set(options.scheduleScopes).count == options.scheduleScopes.count else { throw cliError("新增任务需要 --every-days 和不重复的 --scope PATH") }
            } else {
                guard options.everyDays == nil, options.scheduleScopes.isEmpty, !options.once else { throw cliError("间隔和范围参数仅用于 schedule add") }
            }
            guard !options.apply || !["scopes", "list", "history", "status"].contains(action) else { throw cliError("此定时查询命令只读") }
        }
        if options.command == "disk", positionals.count == 1 {
            guard !seen.contains("--root"), !seen.contains("--index-root") else { throw cliError("只能指定一个扫描目录") }
            options.root = positionals.removeFirst()
        }
        if ["preview", "uninstall", "restore"].contains(options.command) {
            guard positionals.count == 1 else { throw cliError("\(options.command) 需要一个明确的应用或记录标识") }
            options.subject = positionals.removeFirst()
        }
        if options.command == "protect" {
            guard positionals == ["list"] || (positionals.count == 2 && ["add", "remove"].contains(positionals[0])) else {
                throw cliError("用法：roomy protect list | add PATH | remove ID")
            }
            options.subject = positionals.joined(separator: "\u{0}"); positionals = []
        }
        if options.command == "growth", positionals.count == 1 { options.subject = positionals.removeFirst() }
        if options.command == "tier" {
            let usage = "用法：roomy tier list | set ID A|B|C | undo KEYID | reset"
            guard let action = positionals.first, ["list", "set", "undo", "reset"].contains(action),
                  positionals.count == ["list": 1, "set": 3, "undo": 2, "reset": 1][action] else { throw cliError(usage) }
            options.tierAction = positionals.removeFirst()
            if action == "set" { options.subject = positionals.removeFirst(); options.tier = try CLITier.parseTier(positionals.removeFirst()) }
            if action == "undo" { options.subject = positionals.removeFirst() }
            guard !options.apply || action != "list" else { throw cliError("tier list 只读，不支持 --apply") }
        }
        guard positionals.isEmpty else { throw cliError("多余的位置参数：\(positionals.joined(separator: " "))") }
        guard !options.yes || options.apply else { throw cliError("--yes 必须和 --apply 一起使用") }
        guard !options.apply || options.command != "clean" || !options.ids.isEmpty else { throw cliError("执行清理必须逐项指定 --id") }
        guard !options.apply || options.command != "uninstall" || !options.ids.isEmpty else { throw cliError("执行卸载必须逐项指定 --id；先查看预览") }
        guard options.ids.allSatisfy({ $0.count == 16 && $0.allSatisfy(\.isHexDigit) }) else { throw cliError("--id 必须是本轮预览返回的 16 位标识") }
        guard !(seen.contains("--root") && seen.contains("--index-root")),
              !(seen.contains("--json") && seen.contains("--index-json")),
              !(options.legacy && seen.contains("--root")) else { throw cliError("扫描范围或输出参数冲突；旧规则扫描不支持自定义 --root") }
        return options
    }
}

func cliError(_ message: String) -> NSError {
    NSError(domain: "RoomyCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
