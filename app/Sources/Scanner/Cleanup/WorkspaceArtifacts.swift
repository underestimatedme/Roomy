// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Lightweight discovery only. Tool manifests identify context, never authorize
/// deleting a mixed output directory. Independent evidence is required later.
enum WorkspaceArtifacts {
    static let boundaries: Set<String> = ["node_modules", ".git", ".svn", ".hg", ".venv", "venv", "Pods",
        "target", "build", "dist", "out", ".build", ".dart_tool", ".gradle", ".next", ".nuxt", ".output",
        ".svelte-kit", ".cache", "DerivedData", "vendor", "__pycache__"]

    static func discover(roots: [String]) -> [String] {
        var paths = Set<String>()
        func visit(_ path: String, _ depth: Int) {
            guard depth < 10, let entries = try? readDir(path) else { return }
            let names = Set(entries.map(\.name))
            let flutter = names.contains("pubspec.yaml")
            let web = names.contains("package.json")
            let gradle = names.contains("build.gradle") || names.contains("build.gradle.kts")
            // Xcode 工程（含 XcodeGen 的 project.yml、CocoaPods 的 Podfile）旁边的 build 和自定义 DerivedData 位置
            let xcode = names.contains("project.yml") || names.contains("Podfile")
                || names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
            for entry in entries where entry.isDir {
                let name = entry.name, child = path + "/" + name
                let recognized: Bool
                switch name {
                case ".dart_tool": recognized = flutter
                case "build": recognized = flutter || gradle || xcode || names.contains("CMakeLists.txt")
                case ".next", ".nuxt", ".output", ".svelte-kit", "dist", "out": recognized = web
                case ".gradle": recognized = gradle || names.contains("settings.gradle") || names.contains("settings.gradle.kts")
                case ".build": recognized = names.contains("Package.swift")
                case "target": recognized = names.contains("pom.xml") && !names.contains("Cargo.toml")
                case "DerivedData": recognized = true // Review-only, including custom Xcode output locations.
                default:
                    // ReleaseDerivedData、DerivedData-codex、.derived-data 一类自定义的 Xcode 输出位置；.xcresult 是 Xcode 测试结果包（带 Info.plist）
                    recognized = (xcode && (name.contains("DerivedData") || name.hasPrefix(".derived-data")))
                        || (name.hasSuffix(".xcresult") && FileManager.default.fileExists(atPath: child + "/Info.plist"))
                }
                if recognized { paths.insert(child) }
                if boundaries.contains(name) || name.hasPrefix(".venv") ||
                    (name.hasPrefix(".") && name != ".worktrees") ||
                    [".app", ".framework", ".xcarchive", ".bundle", ".xcresult"].contains(where: name.hasSuffix) || name.contains("DerivedData") { continue }
                visit(child, depth + 1)
            }
        }
        for root in roots { visit(root, 0) }
        return paths.sorted()
    }
}
