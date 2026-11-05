// SPDX-License-Identifier: GPL-3.0-only
// 规则库。字段对应规划第四节的模板，口径与 scanner/roomy-scan.py 保持一致。
//
// 三级标记 = 可撤销性 × 重建代价 × 时间：
//   lock   保护区，UI 上没有任何选中入口
//   green  有依据且可撤销，默认勾好
//   amber  有依据但要用户点头（不可撤销 / 单一信号 / 最近还在动）
//
// V1 只走废纸篓，所以所有 undo=false 的规则要么标 amber、要么干脆不做。

import Foundation

enum Layer: String, Codable, CaseIterable {
    case models, sess, mobile, cache
    var title: String {
        switch self {
        case .models: return "模型文件"
        case .sess:   return "AI 会话残留"
        case .mobile: return "移动开发"
        case .cache:  return "通用开发缓存"
        }
    }
    var moat: Bool { self != .cache }
}

enum Rebuild: String, Codable { case free, cheap, costly }
enum Grouping: String { case none, perChild }

struct Rule {
    let name: String
    let paths: [String]          // 支持 <codescan:xxx> 与 <downloads:.a,.b> 伪路径
    let layer: Layer
    let evidence: String
    var gentle: String? = nil
    var hard: String = "移到废纸篓"
    var undo: Bool = true
    var group: Grouping = .none
    var protect: Bool = false
    var note: String = ""
    var rebuild: Rebuild = .costly
    var toolOwned: Bool = false  // 由官方工具探测器接管，规则扫描结果不进清单
    var precheck: Bool = true    // false = 依据再足也不默认勾选（如浏览器缓存：应用多半正开着）
}

extension Rule {
    var literalPaths: [String] { paths.filter { !$0.hasPrefix("<") } }

    var contentTag: ContentTag {
        if protect { return .systemManaged }
        switch layer {
        case .models: return .aiModel
        case .sess: return .aiSession
        case .mobile, .cache: return .developerCache
        }
    }

    var cleanupCapability: CleanupCapability {
        if protect || !undo { return .none }
        return rebuild == .costly ? .reviewRequired : .rebuildable
    }
}

let HOME = NSHomeDirectory()

let RULES: [Rule] = [
    // ── 第一层 · 模型文件 ─────────────────────────────────────────
    Rule(name: "Ollama 模型", paths: ["\(HOME)/.ollama/models"], layer: .models,
         evidence: "最后访问时间 + 是否被 manifest 引用",
         hard: "V1 不做（需要 ollama rm）", undo: false, group: .none,
         note: "删 blob 不删 manifest 会弄脏 Ollama 清单库；V1 只报告", toolOwned: true),
    Rule(name: "LM Studio 模型", paths: ["\(HOME)/.lmstudio/models", "\(HOME)/.cache/lm-studio/models"],
         layer: .models, evidence: "最后访问时间", group: .perChild),
    Rule(name: "HuggingFace hub 缓存", paths: ["\(HOME)/.cache/huggingface/hub"], layer: .models,
         evidence: "重复 revision + 最后访问时间", gentle: "只删旧 revision", group: .perChild),
    Rule(name: "torch / whisper 权重缓存", paths: ["\(HOME)/.cache/torch", "\(HOME)/.cache/whisper"],
         layer: .models, evidence: "缺失时库会自动重新下载"),
    Rule(name: "MLX 缓存", paths: ["\(HOME)/.cache/mlx"], layer: .models, evidence: "缺失时自动重下"),
    Rule(name: "ComfyUI / SD 权重",
         paths: ["\(HOME)/ComfyUI/models", "\(HOME)/Documents/ComfyUI/models", "\(HOME)/stable-diffusion-webui/models"],
         layer: .models, evidence: "工作流最后打开时间", gentle: "只删 checkpoint，保留 LoRA"),

    // ── 第二层 · AI 会话残留 ──────────────────────────────────────
    Rule(name: "Claude Code 会话", paths: ["\(HOME)/.claude/projects"], layer: .sess,
         evidence: "对应项目目录是否还存在 + 最后活动时间", gentle: "压缩归档", group: .perChild),
    Rule(name: "Claude Code 其他残留",
         paths: ["\(HOME)/.claude/todos", "\(HOME)/.claude/shell-snapshots", "\(HOME)/.claude/statsig"],
         layer: .sess, evidence: "纯运行时产物", rebuild: .free),
    Rule(name: "配置 · 记忆 · 登录态",
         paths: ["\(HOME)/.claude/settings.json", "\(HOME)/.claude/CLAUDE.md",
                 "\(HOME)/.claude/memory", "\(HOME)/.claude/.credentials.json"],
         layer: .sess, evidence: "硬编码保护区", protect: true, note: "永不触碰"),
    Rule(name: "Codex 会话", paths: ["\(HOME)/.codex/sessions"], layer: .sess, evidence: "最后活动时间 + 格式版本"),
    Rule(name: "Cursor 工作区", paths: ["\(HOME)/Library/Application Support/Cursor/User/workspaceStorage"],
         layer: .sess, evidence: "工作区指向的目录是否还存在", group: .perChild),
    Rule(name: "VS Code 工作区", paths: ["\(HOME)/Library/Application Support/Code/User/workspaceStorage"],
         layer: .sess, evidence: "工作区指向的目录是否还存在", group: .perChild),
    Rule(name: "其他 AI CLI 残留",
         paths: ["\(HOME)/.gemini", "\(HOME)/.aider.chat.history.md", "\(HOME)/.aider.input.history",
                 "\(HOME)/.opencode", "\(HOME)/.continue"],
         layer: .sess, evidence: "对应可执行文件是否还在 PATH 上"),

    // ── 第三层 · 移动开发 ─────────────────────────────────────────
    Rule(name: "Xcode DerivedData", paths: ["\(HOME)/Library/Developer/Xcode/DerivedData"], layer: .mobile,
         evidence: "各项目最后构建时间", gentle: "只清 >90 天的项目", group: .perChild, rebuild: .cheap),
    Rule(name: "iOS DeviceSupport", paths: ["\(HOME)/Library/Developer/Xcode/iOS DeviceSupport"], layer: .mobile,
         evidence: "近一年实际连过的真机版本", gentle: "保留最近 2 个版本", group: .perChild, rebuild: .cheap),
    Rule(name: "Xcode Archives", paths: ["\(HOME)/Library/Developer/Xcode/Archives"], layer: .mobile,
         evidence: "可能含已上架版本的符号表", protect: true, note: "上架过的 Archive 删了就找不回崩溃符号"),
    Rule(name: "iOS 模拟器设备", paths: ["\(HOME)/Library/Developer/CoreSimulator/Devices"], layer: .mobile,
         evidence: "最后启动时间 + 运行时是否还在",
         hard: "V1 不做（需要 simctl）", undo: false, group: .perChild,
         note: "直接删目录会让 CoreSimulator 的 device_set 变脏；V1 只报告", toolOwned: true),
    Rule(name: "iOS 模拟器运行时",
         paths: ["/Library/Developer/CoreSimulator/Volumes", "\(HOME)/Library/Developer/CoreSimulator/Volumes"],
         layer: .mobile, evidence: "当前 Xcode 需要哪几个版本",
         hard: "V1 不做（需要 simctl，且在 /Library 下要 root）", undo: false, note: "V1 只报告", toolOwned: true),
    Rule(name: "Android AVD 与镜像", paths: ["\(HOME)/.android/avd", "\(HOME)/Library/Android/sdk/system-images"],
         layer: .mobile, evidence: "是否有 AVD 引用该镜像", gentle: "只删快照", group: .perChild),
    Rule(name: "Gradle 缓存", paths: ["\(HOME)/.gradle/caches"], layer: .mobile, evidence: "最后修改时间", rebuild: .cheap),
    Rule(name: "XCTest 设备克隆", paths: ["\(HOME)/Library/Developer/XCTestDevices"], layer: .mobile,
         evidence: "跑测试时自动重建", group: .perChild, rebuild: .cheap),
    Rule(name: "XcodeBuildMCP 工作区", paths: ["\(HOME)/Library/Developer/XcodeBuildMCP/workspaces"], layer: .mobile,
         evidence: "AI 构建工具的临时工作区，下次构建会重建", group: .perChild, rebuild: .cheap),
    Rule(name: "Maven 仓库", paths: ["\(HOME)/.m2/repository"], layer: .cache,
         evidence: "缺失时自动重新下载", rebuild: .cheap),

    // ── 第四层 · 通用开发缓存 ─────────────────────────────────────
    Rule(name: "node_modules", paths: ["<codescan:node_modules>"], layer: .cache,
         evidence: "所在项目最后提交/修改时间", rebuild: .cheap),
    Rule(name: "Python 虚拟环境", paths: ["<codescan:.venv*@has:pyvenv.cfg>"], layer: .cache,
         evidence: "所在项目最后修改时间", rebuild: .cheap),
    Rule(name: "Rust 构建产物", paths: ["<codescan:target@Cargo.toml>"], layer: .cache,
         evidence: "所在项目最后修改时间", rebuild: .cheap),
    Rule(name: "工作空间构建目录", paths: ["<workspace:generated>"], layer: .cache,
         evidence: "工作空间中的构建目录；需单独核实内容，不能整体按缓存清理", rebuild: .cheap, precheck: false),
    Rule(name: "包管理器缓存",
         paths: ["\(HOME)/Library/Caches/pip", "\(HOME)/.npm/_cacache", "\(HOME)/Library/Caches/Homebrew",
                 "\(HOME)/.cargo/registry/cache", "\(HOME)/Library/Caches/Yarn", "\(HOME)/Library/pnpm/store"],
         layer: .cache, evidence: "纯缓存，缺失时自动重建", rebuild: .free),
    // ── 以下来自对真实机器的人工分析（见 ~/.claude/skills/mac-disk-junk-analysis）──────────
    Rule(name: "项目缓存目录", paths: ["<codescan:.cache@gitignored>"], layer: .cache,
         evidence: "被项目 .gitignore 忽略的缓存（如 go-build、gomod）", rebuild: .cheap),
    Rule(name: "Go 模块缓存", paths: ["\(HOME)/go/pkg/mod"], layer: .cache,
         evidence: "缺失时 go 会重新下载", rebuild: .cheap),
    Rule(name: "uv 缓存", paths: ["\(HOME)/.cache/uv"], layer: .cache, evidence: "纯缓存，缺失时自动重建", rebuild: .free),
    Rule(name: "pnpm 元数据缓存", paths: ["\(HOME)/Library/Caches/pnpm"], layer: .cache,
         evidence: "pnpm 的包元数据缓存，缺失时自动重新获取", rebuild: .free),
    Rule(name: "Python 字节码缓存", paths: ["\(HOME)/Library/Caches/com.apple.python"], layer: .cache,
         evidence: "系统自带 Python 生成的 .pyc 字节码，运行时会重新生成", rebuild: .free),
    Rule(name: "浏览器缓存",
         paths: [], // ApplicationCacheProbe owns bounded profile caches, never the enclosing browser root.
         layer: .cache, evidence: "按应用与配置识别的缓存，退出应用后手动确认", rebuild: .cheap, toolOwned: true, precheck: false),
    Rule(name: "自动更新残留",
         paths: ["<glob:\(HOME)/Library/Caches/*-updater>", "<glob:\(HOME)/Library/Application Support/Caches/*-updater>"],
         layer: .cache, evidence: "应用自动更新下载的安装包，需要时会重新下载", rebuild: .cheap),
    Rule(name: "安装临时目录", paths: ["<glob:\(HOME)/.cache/codex-runtimes/*-install-*>"], layer: .sess,
         evidence: "安装中途留下的临时目录，正式安装的版本在旁边", rebuild: .cheap),
    Rule(name: "Playwright 旧版本浏览器", paths: ["<oldversions:\(HOME)/Library/Caches/ms-playwright>"], layer: .cache,
         evidence: "已有更新的版本；老项目需要时 playwright install 会重新下载", rebuild: .cheap, precheck: false),
    Rule(name: "JetBrains 旧版本缓存与日志",
         paths: ["<oldversions:\(HOME)/Library/Caches/JetBrains>", "<oldversions:\(HOME)/Library/Logs/JetBrains>"],
         layer: .cache, evidence: "同一 IDE 已有更新的版本", rebuild: .cheap),
    Rule(name: "JetBrains 旧版本配置", paths: ["<oldversions:\(HOME)/Library/Application Support/JetBrains>"],
         layer: .cache, evidence: "同一 IDE 已有更新的版本，设置通常已迁移过去", rebuild: .costly),
    Rule(name: "Roomy 旧扫描快照", paths: ["\(HOME)/Library/Application Support/Roomy/history"], layer: .cache,
         evidence: "旧版全盘扫描留下的历史索引，当前版本不再读取", rebuild: .free),
    Rule(name: "Go 构建缓存", paths: ["\(HOME)/Library/Caches/go-build"], layer: .cache,
         evidence: "纯缓存，缺失时自动重建", rebuild: .free),
    Rule(name: "Docker 数据", paths: ["\(HOME)/Library/Containers/com.docker.docker/Data"], layer: .cache,
         evidence: "docker system df 的 reclaimable",
         hard: "Roomy 不碰 —— 请自己跑 docker system prune", undo: false,
         note: "数据在单个 .raw 镜像里，删文件回收不了空间；V1 只报告", toolOwned: true),
    Rule(name: "下载目录里的安装包", paths: ["<downloads:.dmg,.pkg,.xip,.iso>"], layer: .cache,
         evidence: "对应 App 是否已安装"),
]

// 在这些目录里找 node_modules / .venv（深度有限，不走全盘）
let CODE_ROOTS = ["code", "Code", "Projects", "projects", "dev", "src", "work", "Developer", "repos", "github"]
    .map { "\(HOME)/\($0)" }

/// 在代码根目录里找 node_modules / .venv* / target / .cache。
/// marker 以 * 结尾 = 前缀匹配；sibling 不为空时要求同级存在该文件（如 Cargo.toml），
/// sibling == "gitignored" 时要求同级 .gitignore 忽略了这个目录。
func findInCodeRoots(_ marker: String, sibling: String? = nil, maxDepth: Int = 10,
                     roots: [String] = ALL_CODE_ROOTS) -> [String] {
    var hits: [String] = []
    let prefix = marker.hasSuffix("*") ? String(marker.dropLast()) : nil
    func isMarker(_ name: String) -> Bool { prefix.map { name.hasPrefix($0) } ?? (name == marker) }
    func rec(_ dir: String, _ depth: Int) {
        guard depth < maxDepth, let es = try? readDir(dir) else { return }
        for e in es where e.isDir {
            if isMarker(e.name) {
                if let sibling, !siblingMatches(sibling, dir: dir, name: e.name) { continue }
                hits.append(dir + "/" + e.name); continue   // 不进去
            }
            // AI 代理的 worktree 目录虽以点开头，里面的东西也要扫
            if (e.name.hasPrefix(".") && e.name != ".worktrees") || WorkspaceArtifacts.boundaries.contains(e.name) { continue }
            rec(dir + "/" + e.name, depth + 1)
        }
    }
    for r in roots { rec(r, 0) }
    return Array(Set(hits)).sorted()
}

/// 一次并行遍历同时找多种 codescan 标记（spec 即 "<codescan:…>" 括号里的内容，如 "target@Cargo.toml"）。
/// 结果与对每个 spec 分别调用 findInCodeRoots 相同：现有标记（node_modules、target、.venv*、.cache）本身都是
/// 隐藏目录或 WorkspaceArtifacts.boundaries 里的名字，单独遍历时也从不进入，所以合并后访问的目录完全一样。
/// 用共享的工作栈，多个线程一起读目录：代码目录很深、分布不均，按顶层拆分并发度不够
func findAllInCodeRoots(_ specs: [String], maxDepth: Int = 10, roots: [String] = ALL_CODE_ROOTS,
                        threads: Int = 8) -> [String: [String]] {
    struct Marker { let spec: String; let name: String; let prefix: String?; let sibling: String? }
    let markers = specs.map { spec -> Marker in
        let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
        return Marker(spec: spec, name: parts[0], prefix: parts[0].hasSuffix("*") ? String(parts[0].dropLast()) : nil,
                      sibling: parts.count > 1 ? parts[1] : nil)
    }
    final class Work: @unchecked Sendable {
        let cond = NSCondition()
        var stack: [(String, Int)] = []
        var active = 0
        var hits: [String: Set<String>] = [:]
    }
    let work = Work()
    work.stack = roots.map { ($0, 0) }
    DispatchQueue.concurrentPerform(iterations: max(1, threads)) { _ in
        while true {
            work.cond.lock()
            while work.stack.isEmpty && work.active > 0 { work.cond.wait() }
            guard let item = work.stack.popLast() else { work.cond.broadcast(); work.cond.unlock(); return }
            let (dir, depth) = item
            work.active += 1
            work.cond.unlock()
            var found: [(String, String)] = [], next: [(String, Int)] = []
            if depth < maxDepth, let es = try? readDir(dir) {
                for e in es where e.isDir {
                    var marked = false
                    for m in markers where m.prefix.map({ e.name.hasPrefix($0) }) ?? (e.name == m.name) {
                        marked = true
                        if let sibling = m.sibling, !siblingMatches(sibling, dir: dir, name: e.name) { continue }
                        found.append((m.spec, dir + "/" + e.name))
                    }
                    if marked { continue }   // 不进去
                    // AI 代理的 worktree 目录虽以点开头，里面的东西也要扫
                    if (e.name.hasPrefix(".") && e.name != ".worktrees") || WorkspaceArtifacts.boundaries.contains(e.name) { continue }
                    next.append((dir + "/" + e.name, depth + 1))
                }
            }
            work.cond.lock()
            work.stack += next; work.active -= 1
            for (spec, path) in found { work.hits[spec, default: []].insert(path) }
            work.cond.broadcast()
            work.cond.unlock()
        }
    }
    return Dictionary(uniqueKeysWithValues: specs.map { ($0, (work.hits[$0] ?? []).sorted()) })
}

private func siblingMatches(_ sibling: String, dir: String, name: String) -> Bool {
    if sibling.hasPrefix("has:") {   // 目录里必须有这个文件（如 .venv 里的 pyvenv.cfg）
        return FileManager.default.fileExists(atPath: dir + "/" + name + "/" + sibling.dropFirst(4))
    }
    guard sibling == "gitignored" else { return FileManager.default.fileExists(atPath: dir + "/" + sibling) }
    guard let text = try? String(contentsOfFile: dir + "/.gitignore", encoding: .utf8) else { return false }
    let accepted: Set<String> = [name, name + "/", "/" + name, "/" + name + "/"]
    return text.split(whereSeparator: \.isNewline).contains { accepted.contains($0.trimmingCharacters(in: .whitespaces)) }
}

/// "GoLand2024.3" → ("GoLand", [2024, 3])；"chromium-1148" → ("chromium", [1148])；没有版本号返回 nil
func splitVersion(_ name: String) -> (name: String, version: [Int])? {
    guard let m = name.range(of: #"-?\d+(\.\d+)*$"#, options: .regularExpression), m.lowerBound > name.startIndex else { return nil }
    let ver = name[m].drop { $0 == "-" }.split(separator: ".").compactMap { Int($0) }
    return (String(name[..<m.lowerBound]), ver)
}

/// 同名软件里比它新的那个版本；它已是最新或没有版本号时返回 nil
func newerVersion(of name: String, among names: [String]) -> String? {
    guard let me = splitVersion(name) else { return nil }
    let newest = names.compactMap { n in splitVersion(n).flatMap { $0.name == me.name ? (n, $0.version) : nil } }
        .max { $0.1.lexicographicallyPrecedes($1.1) }
    guard let newest, newest.0 != name, me.version.lexicographicallyPrecedes(newest.1) else { return nil }
    return newest.0
}


func findDownloads(_ exts: [String]) -> [String] {
    let d = "\(HOME)/Downloads"
    guard let es = try? readDir(d) else { return [] }
    return es.filter { e in e.isFile && exts.contains { e.name.lowercased().hasSuffix($0) } }
             .map { d + "/" + $0.name }
}

/// 把规则里的伪路径展开成真实存在的路径
/// precomputed：已经算好的伪路径结果（"<codescan:…>"、"<workspace:generated>"），planRuleTargets 一次性并行算好再传进来
func expandPaths(_ paths: [String], codeRoots: [String] = ALL_CODE_ROOTS, precomputed: [String: [String]] = [:]) -> [String] {
    var out: [String] = []
    func subdirs(_ dir: String) -> [String] {
        ((try? readDir(dir)) ?? []).filter(\.isDir).map(\.name).sorted()
    }
    for p in paths {
        if let known = precomputed[p] {
            out += known
        } else if p == "<workspace:generated>" {
            out += WorkspaceArtifacts.discover(roots: codeRoots)
        } else if p.hasPrefix("<glob:") {
            // <glob:/dir/pattern>：dir 下名字匹配 pattern 的子目录
            let spec = String(p.dropFirst("<glob:".count).dropLast())
            let dir = (spec as NSString).deletingLastPathComponent, pattern = (spec as NSString).lastPathComponent
            out += subdirs(dir).filter { fnmatch(pattern, $0, 0) == 0 }.map { dir + "/" + $0 }
        } else if p.hasPrefix("<oldversions:") {
            // <oldversions:/dir>：同名软件已有更新版本的旧版本目录
            let dir = String(p.dropFirst("<oldversions:".count).dropLast())
            let names = subdirs(dir)
            out += names.filter { newerVersion(of: $0, among: names) != nil }.map { dir + "/" + $0 }
        } else if p.hasPrefix("<codescan:") {
            let spec = String(p.dropFirst("<codescan:".count).dropLast())
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            out += findInCodeRoots(parts[0], sibling: parts.count > 1 ? parts[1] : nil, roots: codeRoots)
        } else if p.hasPrefix("<downloads:") {
            out += findDownloads(String(p.dropFirst("<downloads:".count).dropLast()).split(separator: ",").map(String.init))
        } else if pathExists(p) {
            out.append(p)
        }
    }
    return out
}
