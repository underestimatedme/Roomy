// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation

@main
struct NpmDependencyEvidenceTests {
    final class Activity: CommandRunning {
        var process = "launchd", opened = "/unrelated", captures = 0, gitCalls = 0
        var gitDelay: useconds_t = 0
        var finalMutation: (() -> Void)?
        func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
            if executable == "/bin/ps" { return .init(status: 0, stdout: (arguments.contains("pid=,command=") ? "999999 " : "") + process + "\n", stderr: "", timedOut: false) }
            if executable == "/usr/sbin/lsof" {
                captures += 1
                if captures == 2 { finalMutation?() }
                return .init(status: 0, stdout: "p999999\0fcwd\0n\(opened)\0\n", stderr: "", timedOut: false)
            }
            if executable == "/usr/bin/git" { gitCalls += 1; if gitDelay > 0 { usleep(gitDelay) } }
            return ProcessRunner().run(executable, arguments, timeout: timeout)
        }
    }
    static func main() throws {
        let fm = FileManager.default
        let raw = fm.temporaryDirectory.appendingPathComponent("roomy-node-proof-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = realpath(raw, nil).map { p in defer { free(p) }; return String(cString: p) }!
        defer { try? fm.removeItem(atPath: root) }
        let project = root + "/project", node = project + "/node_modules", installed = node + "/demo"
        let cache = root + "/.npm/_cacache", staging = root + "/staging"
        func write(_ path: String, _ value: Data) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try value.write(to: URL(fileURLWithPath: path))
        }
        func text(_ path: String, _ value: String) throws { try write(path, Data(value.utf8)) }
        func json(_ path: String, _ value: Any) throws { try write(path, JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
        try text(staging + "/package/package.json", "{\"name\":\"demo\",\"version\":\"1.0.0\"}")
        try text(staging + "/package/index.js", "module.exports = 'original package';\n")
        let archive = root + "/demo.tgz"
        precondition(ProcessRunner().run("/usr/bin/tar", ["-czf", archive, "-C", staging, "package"], timeout: 5).ok)
        let data = try Data(contentsOf: URL(fileURLWithPath: archive)), digest = SHA512.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let blob = cache + "/content-v2/sha512/" + hex.prefix(2) + "/" + hex.dropFirst(2).prefix(2) + "/" + hex.dropFirst(4)
        try write(blob, data)
        try fm.createDirectory(atPath: node, withIntermediateDirectories: true)
        try fm.copyItem(atPath: staging + "/package", toPath: installed)
        try json(project + "/package.json", ["name": "fixture", "dependencies": ["demo": "1.0.0"]])
        var lock: [String: Any] = ["lockfileVersion": 3, "packages": ["": ["name": "fixture", "dependencies": ["demo": "1.0.0"]], "node_modules/demo": ["version": "1.0.0", "resolved": "https://registry.npmjs.org/demo/-/demo-1.0.0.tgz", "integrity": "sha512-" + Data(digest).base64EncodedString()]]]
        try json(project + "/package-lock.json", lock)
        try text(project + "/.gitignore", "node_modules/\n")
        precondition(ProcessRunner().run("/usr/bin/git", ["init", "-q", project], timeout: 5).ok)
        let parent = CleanupEvidence.applying(to: ScanItem.trashTarget(path: node, name: "fixture", size: 4096, rule: "node_modules", evidence: "", risk: .amber))
        let activity = Activity()
        let children = NpmDependencyEvidence.children(of: [parent], runner: activity, cacheRoot: cache)
        precondition(children.count == 1 && children[0].path == installed, "unchanged locked npm package should be individually rebuildable")
        precondition(!parent.undo, "mixed node_modules parent must remain protected")
        let item = children[0], candidate = CleanupListBuilder.fromRule(item)
        precondition(candidate.entry.selectable && candidate.entry.tier == .rebuildable && !candidate.entry.defaultChecked)
        precondition(activity.captures == 2, "one dependency batch shares two activity snapshots")
        func allowed(_ runner: Activity = Activity()) -> Bool { NpmDependencyEvidence.inspect(item, runner: runner, cacheRoot: cache).allowed }
        precondition(allowed())
        var finalRegressions: [String] = []
        let slow = Activity(); slow.gitDelay = 40_000
        let timed = NpmDependencyEvidence.children(of: Array(repeating: parent, count: 10), runner: slow, cacheRoot: cache, scanSeconds: 0.02)
        if slow.gitCalls > 1 || !timed.isEmpty { finalRegressions.append("project context Git work escaped the shared scan deadline") }
        try text(installed + "/index.js", "module.exports = 'local edits';\n")
        precondition(!allowed(), "locally modified package must stay")
        try fm.removeItem(atPath: installed + "/index.js")
        precondition(!allowed(), "a missing archive member cannot qualify")
        try fm.copyItem(atPath: staging + "/package/index.js", toPath: installed + "/index.js")
        try fm.copyItem(atPath: staging + "/package/index.js", toPath: installed + "/original-copy")
        precondition(!allowed(), "extra local file must stay")
        try fm.removeItem(atPath: installed + "/original-copy")
        try fm.removeItem(atPath: installed + "/index.js")
        try fm.copyItem(atPath: staging + "/package/index.js", toPath: installed + "/index.js")
        try fm.createDirectory(atPath: installed + "/local-data", withIntermediateDirectories: true)
        precondition(!allowed(), "even an empty extra directory must stay")
        try fm.removeItem(atPath: installed + "/local-data")
        try fm.removeItem(atPath: installed + "/index.js")
        try fm.createSymbolicLink(atPath: installed + "/index.js", withDestinationPath: staging + "/package/index.js")
        precondition(!allowed(), "linked package content is not an independent unit")
        try fm.removeItem(atPath: installed + "/index.js")
        try fm.copyItem(atPath: staging + "/package/index.js", toPath: installed + "/index.js")
        let active = Activity(); active.process = "npm ci"
        precondition(!allowed(active), "active installation blocks")
        let runtime = Activity(); runtime.opened = project
        precondition(!allowed(runtime), "active project cwd/handles block even when no module file remains open")
        try fm.moveItem(atPath: project + "/.git", toPath: root + "/.git")
        let monorepoRuntime = Activity(); monorepoRuntime.opened = root
        if allowed(monorepoRuntime) { finalRegressions.append("runtime cwd at enclosing Git repository did not block nested project") }
        try fm.moveItem(atPath: root + "/.git", toPath: project + "/.git")
        let absoluteScript = Activity(); absoluteScript.opened = root; absoluteScript.process = "node " + project + "/server.js"
        if allowed(absoluteScript) { finalRegressions.append("absolute project runtime script was not blocked after its files closed") }
        let unresolvedRuntime = Activity(); unresolvedRuntime.opened = root; unresolvedRuntime.process = "node --eval require(\"demo\")"
        if allowed(unresolvedRuntime) { finalRegressions.append("unresolved Node runtime was not conservatively blocked") }
        precondition(ProcessRunner().run("/usr/bin/git", ["-C", project, "add", "-f", "node_modules/demo/index.js"], timeout: 5).ok)
        precondition(!allowed(), "tracked package content must stay")
        precondition(ProcessRunner().run("/usr/bin/git", ["-C", project, "rm", "--cached", "-q", "node_modules/demo/index.js"], timeout: 5).ok)
        let race = Activity(); race.finalMutation = { try! text(installed + "/index.js", "mutation during final query") }
        precondition(!allowed(race), "final activity query cannot hide content mutations")
        try fm.removeItem(atPath: installed + "/index.js"); try fm.copyItem(atPath: staging + "/package/index.js", toPath: installed + "/index.js")
        let lockRace = Activity(); lockRace.finalMutation = { try! text(project + "/package-lock.json", "{}") }
        precondition(!allowed(lockRace), "final query lock changes invalidate proof")
        try json(project + "/package-lock.json", lock)
        try json(project + "/package.json", ["dependencies": ["demo": "2.0.0"]])
        precondition(!allowed(), "outdated lock declarations do not establish reproducibility")
        try json(project + "/package.json", ["name": "fixture", "dependencies": ["demo": "1.0.0"]])
        try write(blob, Data("not the original archive".utf8))
        precondition(!allowed(), "corrupt cached archive must stay")
        try write(blob, data)
        lock["lockfileVersion"] = 1; try json(project + "/package-lock.json", lock)
        precondition(!allowed(), "unsupported old lockfiles must stay")
        var invalid = lock; invalid["lockfileVersion"] = 3
        invalid["packages"] = ["": ["dependencies": 42], "node_modules/demo": (lock["packages"] as! [String: [String: Any]])["node_modules/demo"]!]
        try json(project + "/package-lock.json", invalid); try json(project + "/package.json", ["dependencies": 42])
        precondition(!allowed(), "malformed dependency declarations cannot establish a working restore plan")
        try json(project + "/package.json", ["name": "fixture", "dependencies": ["demo": "1.0.0"]])
        // Bundled dependency records must never count both a package and its child.
        lock["lockfileVersion"] = 3
        let inner = staging + "/package/node_modules/inner"
        try text(inner + "/package.json", "{\"name\":\"inner\",\"version\":\"1.0.0\"}")
        try text(inner + "/index.js", "module.exports = 1;")
        try fm.createDirectory(atPath: installed + "/node_modules", withIntermediateDirectories: true)
        try fm.copyItem(atPath: inner, toPath: installed + "/node_modules/inner")
        precondition(ProcessRunner().run("/usr/bin/tar", ["-czf", archive, "-C", staging, "package"], timeout: 5).ok)
        func cacheArchive(_ archive: String) throws -> String {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: archive)), digest = SHA512.hash(data: bytes)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            try write(cache + "/content-v2/sha512/" + hex.prefix(2) + "/" + hex.dropFirst(2).prefix(2) + "/" + hex.dropFirst(4), bytes)
            return "sha512-" + Data(digest).base64EncodedString()
        }
        let outerIntegrity = try cacheArchive(archive)
        let innerStage = root + "/inner-stage"
        try fm.createDirectory(atPath: innerStage, withIntermediateDirectories: true)
        try fm.copyItem(atPath: inner, toPath: innerStage + "/package")
        precondition(ProcessRunner().run("/usr/bin/tar", ["-czf", archive, "-C", innerStage, "package"], timeout: 5).ok)
        let innerIntegrity = try cacheArchive(archive)
        var records = lock["packages"] as! [String: [String: Any]]
        records["node_modules/demo"]!["integrity"] = outerIntegrity
        records["node_modules/demo/node_modules/inner"] = ["version": "1.0.0", "resolved": "https://registry.npmjs.org/inner/-/inner-1.0.0.tgz", "integrity": innerIntegrity]
        lock["packages"] = records; try json(project + "/package-lock.json", lock)
        let bundled = NpmDependencyEvidence.children(of: [parent], runner: Activity(), cacheRoot: cache)
        precondition(bundled.count == 1 && bundled[0].path == installed, "bundled parent and nested package cannot both be cleanup targets")
        precondition(finalRegressions.isEmpty, finalRegressions.joined(separator: "; "))
        print("NpmDependencyEvidenceTests passed")
    }
}
