// SPDX-License-Identifier: GPL-3.0-only
// 从 Finder / Dock 打开的 App 默认只能同时打开 256 个文件，终端里通常是 1048576。
// 扫描时并发遍历目录、同时启动多个 git，256 很快用完，子命令启动失败后各项检查只能按最保守处理。
// 所以 App、后台调度和命令行在启动时都先把软上限调高（不超过硬上限，已经更高时不动）。

import Darwin

enum OpenFileLimit {
    static let target: rlim_t = 10_240

    /// 返回调整后的软上限
    @discardableResult
    static func raise(to wanted: rlim_t = target) -> rlim_t {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return 0 }
        let goal = min(wanted, limits.rlim_max)
        guard limits.rlim_cur < goal else { return limits.rlim_cur }
        var raised = limits
        raised.rlim_cur = goal
        return setrlimit(RLIMIT_NOFILE, &raised) == 0 ? goal : limits.rlim_cur
    }
}
