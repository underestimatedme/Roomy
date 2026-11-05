// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// usesDirectory 的索引查找必须和逐条命令搜索（scansDirectory）给出同样的结果
@main
struct RunningOwnersIndexTests {
    static func main() {
        // 固定种子的伪随机数，失败时可复现
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(n)) }
        let pieces = ["/", "/", "/", "a", "b", "ab", "x.y", "-", "_", "@", "~", "%", "+", " ", " ", "=", ":", "\"", "'", ",", "代码", "1", "//"]
        func text(_ length: Int) -> String { (0..<length).map { _ in pieces[next(pieces.count)] }.joined() }
        var checked = 0
        for _ in 0..<400 {
            let commands = (0..<(1 + next(6))).map { _ in text(1 + next(24)) }
            let owners = RunningOwners(commands: commands)
            // 既查命令里真实出现的片段，也查随机路径
            var probes = (0..<20).map { _ in "/" + text(1 + next(6)) }
            for command in commands {
                let chars = Array(command)
                for start in chars.indices where chars[start] == "/" {
                    for end in stride(from: start + 1, through: min(chars.count, start + 12), by: 1) { probes.append(String(chars[start..<end])) }
                }
            }
            for path in probes {
                let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                guard normalized.count > 1 else { continue }
                precondition(owners.usesDirectory(path) == owners.scansDirectory(normalized),
                             "index disagrees for \(path) in \(commands)")
                checked += 1
            }
        }
        precondition(checked > 10_000, "too few comparisons: \(checked)")
        // 典型情况
        let owners = RunningOwners(commands: ["/usr/bin/node /opt/work/app/server.js --root=/srv/data", "vim '/Users/x/Code With Spaces/a.txt'"])
        precondition(owners.usesDirectory("/opt/work/app") && owners.usesDirectory("/opt/work") && owners.usesDirectory("/srv/data"))
        precondition(!owners.usesDirectory("/opt/wor") && !owners.usesDirectory("/work/app") && !owners.usesDirectory("/opt/work/app/server"))
        precondition(owners.usesDirectory("/Users/x/Code With Spaces"), "paths with spaces still found")
        print("RunningOwnersIndexTests passed: \(checked) comparisons")
    }
}
