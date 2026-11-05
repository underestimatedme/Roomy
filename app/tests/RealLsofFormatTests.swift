// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private struct LsofFields: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        .init(status: 0, stdout: executable == "/bin/ps" ? "npm exec tool mcp" :
            "p123\0\nfcwd\0n/private/project\0\nf12\0n/private/cache/a/blob\0\n", stderr: "", timedOut: false)
    }
}

@main struct RealLsofFormatTests {
    static func main() {
        guard let snapshot = CacheActivitySnapshot.capture(runner: LsofFields()) else {
            preconditionFailure("macOS emits mandatory f descriptor fields even with -F0pn")
        }
        precondition(snapshot.blocks(path: "/private/cache/a", family: .npm))
        precondition(!snapshot.blocks(path: "/private/cache/b", family: .npm))
        print("RealLsofFormatTests passed: actual p/f/n field layout")
    }
}
