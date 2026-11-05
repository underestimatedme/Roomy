// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct CodeRootsTests {
    static func main() throws {
        let existing: Set<String> = ["/opt", "/opt/projects", "/opt/projects/team", "/opt/projects/team/github",
            "/opt/projects/team/github/Roomy", "/opt/projects/demo", "/opt/projects/demo/workspace",
            "/opt/projects/demo/workspace/ai-routines", "/Users", "/Users/me", "/Users/me/code",
            "/Users/me/code/my-app"]
        let isDir: (String) -> Bool = { existing.contains($0) }

        precondition(CodeRoots.decodeProjectName("-opt-projects-team-github-Roomy", isDir: isDir)
            == "/opt/projects/team/github/Roomy")
        // 目录名里本来就带 "-" 的情况
        precondition(CodeRoots.decodeProjectName("-opt-projects-demo-workspace-ai-routines", isDir: isDir)
            == "/opt/projects/demo/workspace/ai-routines")
        precondition(CodeRoots.decodeProjectName("-Users-me-code-my-app", isDir: isDir) == "/Users/me/code/my-app")
        // 只能解出一部分时，返回已存在的最长前缀
        precondition(CodeRoots.decodeProjectName("-opt-projects-gone-project", isDir: isDir) == "/opt/projects")
        precondition(CodeRoots.decodeProjectName("not-a-path", isDir: isDir) == nil)

        let roots = CodeRoots.roots(from: [
            "/opt/projects/team/github/Roomy", "/opt/projects/demo/workspace/ai-routines", "/opt/projects",
            "/Users/me/code/my-app", "/Users/me", "/Users/me/.claude", "/Users/me/Library/x",
            "/tmp/scratch", "/private/var/x", "/", "/opt"
        ], home: "/Users/me")
        precondition(roots == ["/Users/me/code", "/opt/projects"], "\(roots)")

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-roots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["-opt-projects-team-github-Roomy", "-Users-me-code-my-app"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects/\(name)"),
                withIntermediateDirectories: true)
        }
        let found = CodeRoots.discover(home: "/Users/me", projectsDir: home.appendingPathComponent(".claude/projects").path, includeGit: false,
            isDir: isDir)
        precondition(found == ["/Users/me/code", "/opt/projects"], "\(found)")
        precondition(CodeRoots.discover(home: "/Users/me", projectsDir: "/nonexistent", includeGit: false, isDir: isDir).isEmpty)

        // Codex checkouts must participate in every project scan, even after the
        // user chose no ordinary code folders. Other agent data stays outside.
        let worktrees = home.appendingPathComponent(".codex/worktrees").path
        let checkout = worktrees + "/task/repo"
        for path in [checkout + "/node_modules/pkg", checkout + "/.venv", checkout + "/dist",
                     home.path + "/.codex/sessions/fake/node_modules"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try "gitdir: /nonexistent".write(toFile: checkout + "/.git", atomically: true, encoding: .utf8)
        try "{}".write(toFile: checkout + "/package.json", atomically: true, encoding: .utf8)
        try "home = /python".write(toFile: checkout + "/.venv/pyvenv.cfg", atomically: true, encoding: .utf8)
        let scanRoots = CodeRoots.scanRoots([], home: home.path)
        precondition(scanRoots == [worktrees])
        precondition(CodeRoots.scanRoots([worktrees, worktrees + "/"], home: home.path) == [worktrees],
            "equivalent roots must not be scanned twice")
        precondition(CodeRoots.scanRoots([checkout], home: home.path) == [checkout, worktrees],
            "explicit nested starts retain their own depth budget")
        precondition(CodeRoots.scanRoots([], home: home.path + "/missing").isEmpty,
            "missing agent directories must not make reference scans incomplete")
        let markers = findAllInCodeRoots(["node_modules", ".venv*@has:pyvenv.cfg"], roots: scanRoots)
        precondition(markers["node_modules"] == [checkout + "/node_modules"])
        precondition(markers[".venv*@has:pyvenv.cfg"] == [checkout + "/.venv"])
        precondition(WorkspaceArtifacts.discover(roots: scanRoots) == [checkout + "/dist"])
        let realCheckout = realpath(checkout, nil).map { p in defer { free(p) }; return String(cString: p) }!
        precondition(WorktreeProbe.findRepositories(roots: scanRoots) == [realCheckout])

        let ownedItems = ["Docker 数据", "Ollama 模型", "iOS 模拟器设备", "iOS 模拟器运行时", "浏览器缓存"].map { name in
            ScanItem.trashTarget(path: home.appendingPathComponent(name).path, name: name, size: 4096,
                rule: name, evidence: "fixture", risk: .green)
        }
        precondition(CleanupListBuilder.build(items: ownedItems, probes: []).candidates.isEmpty,
            "native-probe-owned content must not gain generic rule Trash actions")
        for name in ["XCTest 设备克隆", "Maven 仓库", "Go 构建缓存", "Rust 构建产物"] {
            precondition(RULES.contains { $0.name == name }, "missing rule \(name)")
        }
        // 测试设备克隆可能正被测试使用：至少要一段时间没动过才默认勾选
        precondition(RULES.first { $0.name == "XCTest 设备克隆" }!.rebuild == .cheap)
        // Roomy 自己旧的全盘扫描历史：V1 不再读写，属于可以直接清掉的缓存
        let own = RULES.first { $0.name == "Roomy 旧扫描快照" }
        precondition(own?.paths == ["\(HOME)/Library/Application Support/Roomy/history"] && own?.rebuild == .free)
        // 在文稿 / 桌面 / 下载里的代码目录：读它们会弹授权，只能放到清单之后
        let split = CodeRoots.splitProtected(["/Users/me/Documents", "/opt/projects", "/Users/me/code", "/Users/me/Desktop/proj"],
                                             home: "/Users/me")
        precondition(split.fast == ["/opt/projects", "/Users/me/code"] && split.protected == ["/Users/me/Documents", "/Users/me/Desktop/proj"],
                     "\(split)")
        print("CodeRootsTests passed")
    }
}
