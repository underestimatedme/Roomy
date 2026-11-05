// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 合并后的一次并行遍历（findAllInCodeRoots）必须和每种标记各走一遍（findInCodeRoots）找到同样的目录
@main
struct CodeScanWalkTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("roomy-codescan-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        func dir(_ path: String) throws { try fm.createDirectory(atPath: base + "/" + path, withIntermediateDirectories: true) }
        func file(_ path: String, _ text: String = "x") throws {
            try dir((path as NSString).deletingLastPathComponent)
            try Data(text.utf8).write(to: URL(fileURLWithPath: base + "/" + path))
        }
        for i in 0..<30 {
            let p = "code/group\(i % 4)/proj\(i)"
            try dir(p + "/node_modules/dep/node_modules")              // 嵌套的 node_modules 不再单独列
            if i % 2 == 0 { try file(p + "/Cargo.toml") }               // target 只在有 Cargo.toml 时算
            try dir(p + "/target/debug")
            try file(p + "/.venv312/pyvenv.cfg")
            if i % 3 == 0 { try dir(p + "/.venv-empty") }              // 没有 pyvenv.cfg：不算
            try dir(p + "/.cache/go-build")
            if i % 2 == 1 { try file(p + "/.gitignore", ".cache/\n") }  // .cache 只在被忽略时算
            try dir(p + "/src/deep/a/b/c/d/e/f/g/h/node_modules")       // 超过深度上限的不找
            try dir(p + "/build/node_modules")                           // build 是边界：不进去
        }
        try dir("code/.worktrees/wt1/node_modules")                      // .worktrees 虽是隐藏目录也要进
        try dir("code/.hidden/node_modules")                             // 其他隐藏目录不进
        let specs = ["node_modules", ".venv*@has:pyvenv.cfg", "target@Cargo.toml", ".cache@gitignored"]
        let roots = [base + "/code", base + "/missing"]
        let merged = findAllInCodeRoots(specs, roots: roots, threads: 6)
        for spec in specs {
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            let single = findInCodeRoots(parts[0], sibling: parts.count > 1 ? parts[1] : nil, roots: roots)
            precondition(merged[spec] == single, "\(spec): merged \(merged[spec]?.count ?? -1) vs single \(single.count)")
            precondition(!single.isEmpty, "\(spec) fixture found nothing")
        }
        precondition(merged["node_modules"]!.contains(base + "/code/.worktrees/wt1/node_modules"))
        precondition(!merged["node_modules"]!.contains { $0.contains("/.hidden/") || $0.contains("/build/") || $0.hasSuffix("/dep/node_modules") })
        precondition(merged["target@Cargo.toml"]!.count == 15 && merged[".cache@gitignored"]!.count == 15)
        // planRuleTargets 用合并遍历后，结果与逐条展开一致
        let viaPlan = Set(planRuleTargets(codeRoots: roots, protected: false).map(\.path))
        let viaRules = Set(RULES.flatMap { rule in expandPaths(rule.paths.filter { $0.hasPrefix("<codescan:") }, codeRoots: roots) })
        precondition(viaRules.isSubset(of: viaPlan), "planRuleTargets lost codescan targets")
        print("CodeScanWalkTests passed")
    }
}
