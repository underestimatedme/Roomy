// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct WorkspaceArtifactDiscoveryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-workspace-discovery-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: root) }
        func write(_ relative: String) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "fixture".write(toFile: path, atomically: true, encoding: .utf8)
        }
        // Removing deep workspace discovery would miss real nested mobile projects.
        let project = "team/github/mobile/apps/client/flutter_app"
        try write(project + "/pubspec.yaml")
        try write(project + "/.dart_tool/flutter_build/hash/app.dill")
        try write(project + "/build/app/intermediates/file")
        try write("team/github/web/package.json")
        try write("team/github/web/.next/cache/file")
        try write("team/github/web/node_modules/example/package.json")
        try write("team/github/web/node_modules/example/dist/source.js")
        try write("team/github/android/app/build.gradle.kts")
        try write("team/github/android/app/build/intermediates/file")
        try write(project + "/native/Cargo.toml")
        try write(project + "/native/target/debug/incremental/file")
        let targets = planRuleTargets(codeRoots: [root], protected: false)
        let paths = Set(targets.map(\.path))
        for expected in [project + "/.dart_tool", project + "/build", "team/github/web/.next",
                         "team/github/android/app/build", project + "/native/target"] {
            precondition(paths.contains(root + "/" + expected), "missing nested workspace artifact: \(expected)")
        }
        precondition(!paths.contains(root + "/team/github/web/node_modules/example/dist"), "dependency internals are not independent project outputs")
        precondition(targets.filter { $0.path.hasPrefix(root + "/") }.count == paths.filter { $0.hasPrefix(root + "/") }.count,
            "overlapping discoveries must not produce duplicate targets")
        // Xcode 工程（XcodeGen 的 project.yml 或 .xcodeproj）旁边的 build、自定义 DerivedData 位置，以及测试结果包
        try write("team/github/ios/project.yml")
        try write("team/github/ios/build/Debug-iphonesimulator/App.app/App")
        try write("team/github/ios/.derived-data/Build/Products/file")
        try write("team/github/ios/ReleaseDerivedData/Build/file")
        try write("team/github/ios/DerivedData-codex/Logs/Test/Run.xcresult/Info.plist")   // 测试包在它里面：整块算一项
        try write("team/github/ios/Regression.xcresult/Info.plist")
        try write("team/github/ios/Regression.xcresult/Data/blob")
        try write("team/github/ios/notes.xcresult/readme.txt")       // 没有 Info.plist：不是测试结果包
        try write("team/github/docs/build/index.html")                // 没有工程标记的 build 不算
        let more = Set(planRuleTargets(codeRoots: [root], protected: false).map(\.path))
        for expected in ["ios/build", "ios/.derived-data", "ios/ReleaseDerivedData", "ios/DerivedData-codex", "ios/Regression.xcresult"] {
            precondition(more.contains(root + "/team/github/" + expected), "missing Xcode output: \(expected)")
        }
        for unexpected in ["ios/notes.xcresult", "docs/build", "ios/Regression.xcresult/Data", "ios/DerivedData-codex/Logs/Test/Run.xcresult"] {
            precondition(!more.contains(root + "/team/github/" + unexpected), "not an Xcode output: \(unexpected)")
        }
        print("WorkspaceArtifactDiscoveryTests passed")
    }
}
