// SPDX-License-Identifier: MPL-2.0
// 清单分组：类别（这是什么）→ 规则组（同一条规则的多项合成一行）→ 条目。
// 规则名 / 探测来源 → 类别的对应集中在这里。

import Foundation

struct CleanupCategory: Codable, Equatable {
    let key: String
    let title: String
    let blurb: String   // 一句人话说明
}

enum CleanupCategories {
    static let all: [CleanupCategory] = [
        .init(key: "worktree", title: "AI 代理留下的 worktree", blurb: "AI 编程代理每个任务开一个，分支合入后就没人管了"),
        .init(key: "devcache", title: "开发缓存", blurb: "npm、Gradle、Go、pip 等，缺失时会自动重新下载"),
        .init(key: "deps", title: "项目依赖与构建产物", blurb: "源码之外的依赖和编译产物；已验证子项可单独处理"),
        .init(key: "xcode", title: "Xcode 与模拟器", blurb: "构建产物、测试克隆和模拟器"),
        .init(key: "leftover", title: "应用残留与旧版本", blurb: "已卸载应用的数据、更新包、旧版本和浏览器缓存"),
        .init(key: "ai", title: "AI 会话与模型", blurb: "对话记录和模型文件，删了不一定找得回"),
        .init(key: "docker", title: "Docker", blurb: "已停止的容器和构建缓存"),
        .init(key: "notice", title: "需要留意", blurb: "只提示，不能清理"),
        .init(key: "other", title: "其他", blurb: ""),
    ]

    private static let byRule: [String: String] = {
        var m: [String: String] = [:]
        for r in ["包管理器缓存", "npm 下载缓存", "Gradle 缓存", "Gradle 下载缓存", "Maven 仓库", "Go 模块缓存", "Go 构建缓存", "Go 生成缓存", "uv 缓存", "pnpm 元数据缓存", "Python 字节码缓存", "项目缓存目录",
                  GradleWrapperProbe.rule, OwnerCachePolicy.npxRule] { m[r] = "devcache" }
        for r in [NpmDependencyEvidence.rule, "node_modules", "Python 虚拟环境", "Rust 构建产物", "工作空间构建目录", "Flutter 编译快照", "Rust 增量缓存"] { m[r] = "deps" }
        for r in ["Xcode DerivedData", "Xcode 生成缓存", "iOS DeviceSupport", "XCTest 设备克隆", "XcodeBuildMCP 工作区", "Android AVD 与镜像", SdkCopyProbe.group,
                  DerivedDataCopyProbe.rule] { m[r] = "xcode" }
        for r in ["自动更新残留", "安装临时目录", "Playwright 旧版本浏览器", "JetBrains 旧版本缓存与日志", "JetBrains 旧版本配置",
                  "浏览器缓存", "Roomy 旧扫描快照", "下载目录里的安装包", ReleaseHistoryProbe.rule] { m[r] = "leftover" }
        for r in ["LM Studio 模型", "HuggingFace hub 缓存", "torch / whisper 权重缓存", "MLX 缓存", "ComfyUI / SD 权重",
                  "Claude Code 会话", "Claude Code 其他残留", "Codex 会话", "Cursor 工作区", "VS Code 工作区", "其他 AI CLI 残留"] { m[r] = "ai" }
        return m
    }()

    private static let bySource: [String: (category: String, group: String)] = [
        "simulator": ("xcode", "iOS 模拟器"), "runtime": ("xcode", "模拟器运行时"),
        "ollama": ("ai", "Ollama 模型"), "docker": ("docker", "Docker"),
        "leftover": ("leftover", "已卸载应用的残留"), "launchagent": ("leftover", "后台服务残留"),
        "agenthealth": ("notice", "后台服务反复失败"), "worktree": ("worktree", "worktree"),
        "appcache": ("leftover", "应用缓存"), "appdata": ("leftover", "应用缓存与日志"),
    ]

    static func category(forRule rule: String) -> String { byRule[rule] ?? "other" }
    static func category(forSource source: String) -> String { bySource[source]?.category ?? "other" }

    /// 给清单里的一项定类别和规则组
    static func assign(_ c: CleanupCandidate) -> CleanupCandidate {
        var entry = c.entry
        switch (c.entry.source, c.action) {
        case ("appcache", _), ("appdata", _):
            entry.category = "leftover"; entry.group = c.entry.group
        case ("rule", nil), ("rule", .toolClean?):
            // Review-only evidence rows still belong to their original rule/category; so do rows a package manager
            // clears itself (Go, pip, pnpm, Homebrew), which carry the rule's category and group from the scan.
            break
        case ("rule", .trash(let item)?):
            entry.category = category(forRule: item.rule); entry.group = item.rule
        case ("worktree", .worktreeRemove(_, let repo, _, _)?):
            entry.category = "worktree"; entry.group = "\((repo as NSString).lastPathComponent) 的 worktree"
        default:
            let s = bySource[c.entry.source]
            entry.category = s?.category ?? "other"; entry.group = s?.group ?? c.entry.source
        }
        return CleanupCandidate(entry: entry, action: c.action)
    }
}
