// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

enum CacheFamily { case npm, go, flutter, rust, gradle }

/// An idle server launched through npm is not an active package installation.
/// Actual handles and active install/build commands are checked separately.
struct CacheActivitySnapshot {
    private let opened: Set<String>
    private let npmInstalling: Bool
    private let goBuilding: Bool
    private let flutterBuilding: Bool
    private let rustBuilding: Bool
    private let gradleRunning: Bool
    private let dependencyRuntimes: [(command: String, cwd: String?)]?

    static func capture(runner: CommandRunning, dependencies: Bool = false) -> CacheActivitySnapshot? {
        let processes = runner.run("/bin/ps", ["-axo", dependencies ? "pid=,command=" : "command="], timeout: 5)
        guard processes.ok, processes.stderr.isEmpty,
              !processes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var commands: [Int32: String] = [:]
        if dependencies {
            for row in processes.stdout.split(separator: "\n") {
                let parts = row.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard parts.count == 2, let pid = Int32(parts[0]), pid > 0 else { return nil }
                commands[pid] = String(parts[1])
            }
        }
        let processOutput = dependencies ? commands.values.joined(separator: "\n") : processes.stdout
        let handles = runner.run("/usr/sbin/lsof", ["-nP", "-F0pn", "-a", "-u", String(getuid())], timeout: 10)
        guard handles.ok, handles.stderr.isEmpty, handles.stdout.contains("\0") else { return nil }
        var cwd: [Int32: String] = [:]
        var pid: Int32?, descriptor: String?, paths = Set<String>(), sawProcess = false, sawPath = false
        for raw in handles.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            let field = raw.drop(while: { $0 == "\n" || $0 == "\r" })
            guard let key = field.first else { continue }
            if key == "p" {
                guard let value = Int32(field.dropFirst()), value > 0 else { return nil }
                pid = value; descriptor = nil; sawProcess = true
            } else if key == "f" {
                let value = String(field.dropFirst())
                guard pid != nil, !value.isEmpty, value != "NOFD" else { return nil }
                descriptor = value
            } else if key == "n" {
                guard let pid, descriptor != nil else { return nil }
                let path = String(field.dropFirst())
                if path.hasPrefix("/") {
                    sawPath = true
                    if pid != getpid() { paths.insert(path) }
                    if descriptor == "cwd" { cwd[pid] = path }
                }
            } else { return nil }
        }
        guard sawProcess, sawPath else { return nil }
        func contains(_ pattern: String) -> Bool {
            processOutput.split(separator: "\n").contains { $0.range(of: pattern, options: .regularExpression) != nil }
        }
        func command(executables: Set<String>, scripts: Set<String> = [], operations: Set<String>) -> Bool {
            processOutput.split(separator: "\n").contains { line in
                let tokens = line.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                guard let index = tokens.indices.first(where: { index in
                    let name = (tokens[index] as NSString).lastPathComponent.lowercased()
                    return (index == 0 && executables.contains(name)) || scripts.contains(name)
                }) else { return false }
                let arguments = tokens.dropFirst(index + 1)
                // Recognize aliases and commands after global options, including paths
                // containing spaces. Suspicious ambiguous forms fail conservatively.
                return arguments.contains { operations.contains($0.lowercased()) } ||
                    ((tokens[index] as NSString).lastPathComponent == "yarn" && arguments.isEmpty)
            }
        }
        let npm = command(executables: ["npm", "npx", "pnpm", "yarn"], scripts: ["npm-cli.js", "pnpm.cjs", "pnpm.mjs", "yarn.js"],
            operations: ["install", "i", "in", "ins", "inst", "insta", "instal", "isntall", "ci", "ic", "add", "update", "up", "upgrade", "remove", "rm", "un", "uninstall", "dedupe", "ddp", "cache"])
        let explicitGoBuild = command(executables: ["go"], operations: ["build", "test", "install", "clean", "generate", "mod", "tool"]) ||
            contains(#"/pkg/tool/[^\s]+/(?:compile|link)(?:\s|$)"#)
        let goRun = command(executables: ["go"], operations: ["run"])
        let go = explicitGoBuild || (goRun && unresolvedGoRun(runner: runner))
        let flutter = command(executables: ["flutter"], scripts: ["flutter_tools.snapshot"],
            operations: ["build", "assemble", "run", "test", "drive", "clean", "pub"]) ||
            contains(#"(?:^|\s)(?:[^\s]*/)?(?:frontend_server|frontend_server_aot)\.(?:dart\.snapshot|snapshot)(?:\s|$)"#)
        let rust = command(executables: ["cargo", "cargo-clippy"], operations: ["build", "b", "check", "c", "run", "r", "test", "t", "bench", "rustc", "clippy", "clean", "install", "fix"]) ||
            contains(#"^(?:[^\s]*/)?(?:rustc|clippy-driver)(?:\s|$)"#)
        // Even an idle daemon can hold dependency-cache state. Do not stop it
        // implicitly, and do not treat unrelated Java applications as Gradle.
        let gradle = contains(#"(?:^|\s)org\.gradle\.(?:launcher|wrapper|process|tooling)\.[^\s]+(?:\s|$)"#) ||
            contains(#"^(?:(?:[^\s]*/)?(?:sh|bash|zsh)\s+)?(?:[^\s]*/)?gradle(?:w)?(?:\s|$)"#)
        return CacheActivitySnapshot(opened: paths, npmInstalling: npm, goBuilding: go,
            flutterBuilding: flutter, rustBuilding: rust, gradleRunning: gradle,
            dependencyRuntimes: dependencies ? commands.compactMap { pid, command in
                guard let first = command.split(whereSeparator: { $0.isWhitespace }).first,
                      ["node", "nodejs", "bun", "deno"].contains((String(first) as NSString).lastPathComponent.lowercased()) else { return nil }
                return (command, cwd[pid])
            } : nil)
    }

    /// `go run` remains as the parent of a long-running application after the
    /// build has finished. Only a known Go-produced runtime child establishes
    /// that state; wrappers, debuggers and incomplete queries remain blocked.
    static func unresolvedGoRun(runner: CommandRunning) -> Bool {
        let result = runner.run("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5)
        guard result.ok, result.stderr.isEmpty, !result.stdout.isEmpty else { return true }
        var rows: [(pid: Int32, parent: Int32, command: String)] = []
        for line in result.stdout.split(separator: "\n") {
            let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return true }
            rows.append((pid, parent, String(fields[2])))
        }
        let parents = rows.filter { row in
            let arguments = row.command.split(whereSeparator: { $0.isWhitespace })
            return arguments.first.map { ($0 as NSString).lastPathComponent == "go" } == true && arguments.dropFirst().contains("run")
        }
        for parent in parents {
            let launched = rows.contains { child in
                guard child.parent == parent.pid,
                      let executable = child.command.split(whereSeparator: { $0.isWhitespace }).first else { return false }
                let path = String(executable)
                return path.range(of: #"/go-build[0-9]+/(?:[^/]+/)*exe/[^/]+$"#, options: .regularExpression) != nil ||
                    path.range(of: #"/Library/Caches/go-build/[0-9a-f]{2}/[0-9a-f]{64}-d/[^/]+$"#, options: .regularExpression) != nil
            }
            if !launched { return true }
        }
        return false
    }

    /// Installed packages can be required lazily after all file handles close.
    /// Check runtime cwd and script paths as well as ordinary cache activity.
    /// Unknown/eval/stdin runtimes cannot establish an inactive project.
    func blocksDependencies(project: String) -> Bool {
        guard !blocks(path: project, family: .npm), let runtimes = dependencyRuntimes else { return true }
        func inside(_ path: String) -> Bool { path == project || path.hasPrefix(project + "/") }
        for runtime in runtimes {
            if runtime.command.contains(project + "/") { return true }
            guard let rawCwd = runtime.cwd, let pointer = realpath(rawCwd, nil) else { return true }
            let cwd = String(cString: pointer); free(pointer)
            if inside(cwd) { return true }
            let words = runtime.command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let tokens = Array(words.dropFirst())
            guard !tokens.isEmpty, tokens.count <= 256 else { return true }
            let valueOptions: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader", "--conditions", "-C",
                "--inspect-port", "--title", "--icu-data-dir", "--env-file", "--redirect-warnings", "--openssl-config", "--snapshot-blob", "--watch-path"]
            let switches: Set<String> = ["--enable-source-maps", "--experimental-strip-types", "--experimental-transform-types", "--no-warnings",
                "--trace-warnings", "--trace-deprecation", "--watch", "--watch-preserve-output", "--inspect", "--inspect-brk", "--test",
                "--no-deprecation", "--preserve-symlinks", "--preserve-symlinks-main", "--no-experimental-fetch"]
            var index = 0
            if ["bun", "deno"].contains((words[0] as NSString).lastPathComponent.lowercased()), tokens[0] == "run" { index = 1 }
            while index < tokens.count {
                let token = tokens[index]
                if token == "--" { index += 1; break }
                if ["-e", "--eval", "-p", "--print", "-", "-i", "--interactive"].contains(token) || token.hasPrefix("--eval=") || token.hasPrefix("--print=") ||
                    (!token.hasPrefix("--") && (token.hasPrefix("-e") || token.hasPrefix("-p"))) { return true }
                if valueOptions.contains(token) { index += 2; continue }
                if switches.contains(token) || (token.hasPrefix("--") && token.contains("=")) { index += 1; continue }
                if token.hasPrefix("-") { return true }
                break
            }
            guard index < tokens.count else { return true }
            let script = tokens[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let path = script.hasPrefix("/") ? script : cwd + "/" + script
            guard let scriptPointer = realpath(path, nil) else { return true }
            let canonical = String(cString: scriptPointer); free(scriptPointer)
            if inside(canonical) || CleanupIdentity.capture(path: canonical)?.kind != .file { return true }

        }
        return false
    }

    func blocks(path: String, family: CacheFamily) -> Bool {
        switch family {
        case .npm: if npmInstalling { return true }
        case .go: if goBuilding { return true }
        case .flutter: if flutterBuilding { return true }
        case .rust: if rustBuilding { return true }
        case .gradle: if gradleRunning { return true }
        }
        return opened.contains { $0 == path || $0.hasPrefix(path + "/") }
    }
}
