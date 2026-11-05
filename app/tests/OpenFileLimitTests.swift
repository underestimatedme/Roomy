// SPDX-License-Identifier: MPL-2.0
import Darwin
import Foundation

// 从 Finder / Dock 打开的 App 默认只能同时打开 256 个文件；扫描时并发遍历目录、启动 git，
// 超出后子命令启动失败，检查一律按最保守处理，大量条目被误锁成"不能删"
@main
struct OpenFileLimitTests {
    static func soft() -> rlim_t { var l = rlimit(); getrlimit(RLIMIT_NOFILE, &l); return l.rlim_cur }
    static func setSoft(_ value: rlim_t) { var l = rlimit(); getrlimit(RLIMIT_NOFILE, &l); l.rlim_cur = min(value, l.rlim_max); setrlimit(RLIMIT_NOFILE, &l) }

    static func main() {
        var limits = rlimit(); getrlimit(RLIMIT_NOFILE, &limits)
        let expected = min(OpenFileLimit.target, limits.rlim_max)

        setSoft(256)
        precondition(soft() == 256, "test setup")
        let raised = OpenFileLimit.raise()
        precondition(raised == expected && soft() == expected, "GUI default 256 is raised: \(raised) \(soft())")

        // 已经比目标高时不往下调（终端里常见的 1048576）
        if limits.rlim_max > OpenFileLimit.target {
            setSoft(OpenFileLimit.target + 100)
            precondition(OpenFileLimit.raise() == OpenFileLimit.target + 100 && soft() == OpenFileLimit.target + 100, "never lowers")
        }

        // 命令行入口自己调高，不依赖终端的 ulimit
        setSoft(256)
        precondition(runRoomyCLI(["version"]) == 0)
        precondition(soft() == expected, "runRoomyCLI raises the limit: \(soft())")
        print("OpenFileLimitTests passed")
    }
}
