// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct NpmDependencyActivityTests {
    final class Activity: CommandRunning {
        var command = "launchd", cwd = "/", hasCwd = true
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
            if executable == "/bin/ps" { return .init(status: 0, stdout: "999999 " + command + "\n", stderr: "", timedOut: false) }
            return .init(status: 0, stdout: "p999999\0f\(hasCwd ? "cwd" : "3")\0n\(cwd)\0\n", stderr: "", timedOut: false)
        }
    }
    static func main() throws {
        let fm = FileManager.default, raw = fm.temporaryDirectory.appendingPathComponent("roomy-runtime-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = realpath(raw, nil).map { p in defer { free(p) }; return String(cString: p) }!
        defer { try? fm.removeItem(atPath: root) }
        let project = root + "/project", outside = root + "/outside"
        try fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "// script".write(toFile: outside + "/script.js", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: root + "/alias", withDestinationPath: project)
        let activity = Activity(); activity.cwd = outside
        var failures: [String] = []
        func check(_ command: String, _ blocked: Bool, _ name: String) {
            activity.command = command
            guard let snapshot = CacheActivitySnapshot.capture(runner: activity, dependencies: true) else { failures.append(name + " snapshot unavailable"); return }
            if snapshot.blocksDependencies(project: project) != blocked { failures.append(name) }
        }
        check("node " + outside + "/script.js", false, "unrelated absolute script")
        check("node ./script.js", false, "unrelated relative script with known cwd")
        check("node --require " + outside + "/script.js", true, "preload without entry script is unresolved")
        check("node -erequire('demo') " + outside + "/script.js", true, "attached short eval flag")
        activity.cwd = root + "/alias"
        check("node " + outside + "/script.js", true, "project cwd alias")
        activity.cwd = outside; activity.hasCwd = false
        check("node " + outside + "/script.js", true, "missing runtime cwd")
        precondition(failures.isEmpty, failures.joined(separator: "; "))
        print("NpmDependencyActivityTests passed")
    }
}
