// SPDX-License-Identifier: MPL-2.0
import Foundation

private final class ActivityRunner: CommandRunning {
    var processes = "npm run dev\nnpm exec tool mcp\ngopls serve"
    var files = "p123\0\nf0\0n/dev/null\0f12\0n/private/cache/a/blob\0\np124\0\nf1\0n/private/cache/ab/other\0"
    var warning = ""
    var processDetails = ""
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        .init(status: 0, stdout: executable == "/bin/ps" ? (arguments.contains("pid=,ppid=,command=") ? processDetails : processes) : files, stderr: warning, timedOut: false)
    }
}

@main struct CacheActivityTests {
    static func main() {
        let runner = ActivityRunner()
        guard let state = CacheActivitySnapshot.capture(runner: runner) else { preconditionFailure("valid snapshot") }
        precondition(state.blocks(path: "/private/cache/a", family: .npm))
        precondition(!state.blocks(path: "/private/cache/b", family: .npm))
        precondition(!state.blocks(path: "/private/cache/abc", family: .npm), "path boundaries, not prefix collisions")
        runner.processes = "node /opt/npm/bin/npm-cli.js install"
        precondition(CacheActivitySnapshot.capture(runner: runner)!.blocks(path: "/unused", family: .npm))
        for command in ["npm i package", "npm --prefix /private/project install", "node /opt/npm/bin/npm-cli.js --cache /tmp/cache ci"] {
            runner.processes = command
            precondition(CacheActivitySnapshot.capture(runner: runner)!.blocks(path: "/unused", family: .npm), "active install: \(command)")
        }
        runner.processes = "/opt/homebrew/bin/go build ./..."
        precondition(CacheActivitySnapshot.capture(runner: runner)!.blocks(path: "/unused", family: .go))
        runner.processes = "/opt/homebrew/bin/go -C /private/project build ./..."
        precondition(CacheActivitySnapshot.capture(runner: runner)!.blocks(path: "/unused", family: .go))
        runner.processes = "go run server.go"
        runner.processDetails = "200 1 /opt/homebrew/bin/go run server.go\n201 200 /private/tmp/go-build123/b001/exe/server"
        precondition(!CacheActivitySnapshot.capture(runner: runner)!.blocks(path: "/unused", family: .go),
            "an already launched Go server is not still compiling")
        runner.processDetails = "200 1 /opt/homebrew/bin/go run server.go"
        precondition(CacheActivitySnapshot.capture(runner: runner)!.blocks(path: "/unused", family: .go),
            "go run without a verified running binary may still be preparing/building")
        runner.processes = "gopls serve"; runner.warning = "incomplete process access"
        precondition(CacheActivitySnapshot.capture(runner: runner) == nil)
        runner.warning = ""; runner.files = "truncated or unexpected format"
        precondition(CacheActivitySnapshot.capture(runner: runner) == nil)
        print("CacheActivityTests passed: actual file handles, path boundaries, install/build detection and incomplete snapshots")
    }
}
