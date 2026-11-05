// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct RuleExpansionTests {
    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("roomy-rules-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tmp) }
        func dir(_ p: String) throws { try fm.createDirectory(atPath: tmp + "/" + p, withIntermediateDirectories: true) }
        func write(_ p: String, _ text: String) throws { try text.write(toFile: tmp + "/" + p, atomically: true, encoding: .utf8) }

        // ── 项目里被 .gitignore 忽略的 .cache（包括 .worktrees 里的 worktree）
        try dir("code/Valley/.cache/go-build"); try write("code/Valley/.gitignore", "node_modules\n.cache/\n")
        try dir("code/Other/.cache/stuff"); try write("code/Other/.gitignore", "dist\n")            // 没被忽略 → 不算
        try dir("code/.worktrees/wt1/.cache/gomod"); try write("code/.worktrees/wt1/.gitignore", "/.cache\n")
        try dir("code/Plain/.cache")                                                              // 没有 .gitignore → 不算
        let caches = expandPaths(["<codescan:.cache@gitignored>"], codeRoots: [tmp + "/code"]).sorted()
        precondition(caches == [tmp + "/code/.worktrees/wt1/.cache", tmp + "/code/Valley/.cache"], "\(caches)")

        // ── 名字带版本号的虚拟环境
        try dir("code/ml/.venv312"); try dir("code/ml2/.venv"); try dir("code/ml3/venv-old")
        for v in ["code/ml/.venv312", "code/ml2/.venv"] { FileManager.default.createFile(atPath: tmp + "/" + v + "/pyvenv.cfg", contents: Data()) }
        let venvs = expandPaths(["<codescan:.venv*@has:pyvenv.cfg>"], codeRoots: [tmp + "/code"]).sorted()
        precondition(venvs == [tmp + "/code/ml/.venv312", tmp + "/code/ml2/.venv"], "\(venvs)")

        // ── 按名字模式匹配子目录
        try dir("Caches/@guanjia-openclawelectron-updater"); try dir("Caches/notion-updater"); try dir("Caches/com.google.GoogleUpdater")
        let updaters = expandPaths(["<glob:\(tmp)/Caches/*-updater>"], codeRoots: []).sorted()
        precondition(updaters == [tmp + "/Caches/@guanjia-openclawelectron-updater", tmp + "/Caches/notion-updater"], "\(updaters)")

        // ── 同一软件有更新版本时，旧版本的目录
        for d in ["chromium-1148", "chromium-1223", "chromium-1234", "chromium_headless_shell-1148",
                  "chromium_headless_shell-1234", "ffmpeg-1010", "ffmpeg-1011", "webkit-2000"] { try dir("pw/" + d) }
        let oldPW = expandPaths(["<oldversions:\(tmp)/pw>"], codeRoots: []).map { ($0 as NSString).lastPathComponent }.sorted()
        precondition(oldPW == ["chromium-1148", "chromium-1223", "chromium_headless_shell-1148", "ffmpeg-1010"], "\(oldPW)")
        for d in ["GoLand2024.3", "GoLand2025.1", "IdeaIC2024.3", "PyCharm2025.1", "plugins", "config"] { try dir("jb/" + d) }
        let oldJB = expandPaths(["<oldversions:\(tmp)/jb>"], codeRoots: []).map { ($0 as NSString).lastPathComponent }
        precondition(oldJB == ["GoLand2024.3"], "\(oldJB)")
        precondition(newerVersion(of: "GoLand2024.3", among: ["GoLand2024.3", "GoLand2025.1"]) == "GoLand2025.1")

        // ── 新规则都在规则库里
        for name in ["项目缓存目录", "Go 模块缓存", "uv 缓存", "XcodeBuildMCP 工作区", "浏览器缓存", "自动更新残留",
                     "安装临时目录", "Playwright 旧版本浏览器", "JetBrains 旧版本缓存与日志", "JetBrains 旧版本配置"] {
            precondition(RULES.contains { $0.name == name }, "missing rule \(name)")
        }
        precondition(RULES.first { $0.name == "JetBrains 旧版本配置" }!.rebuild == .costly, "old IDE config is not pre-checked")
        precondition(RULES.first { $0.name == "Python 虚拟环境" }!.paths == ["<codescan:.venv*@has:pyvenv.cfg>"])
        print("RuleExpansionTests passed")
    }
}
