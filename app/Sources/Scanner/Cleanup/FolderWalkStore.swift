// SPDX-License-Identifier: MPL-2.0
// 最近一次完整遍历的结果，供"按文件夹看"读取。每次扫描开始时清空并登记这一代；
// 只有这一代的遍历结果能存进来，旧一代晚到的会被丢掉。没有结果时调用方回复 pending。

import Foundation

/// 一次完整遍历的结果（目录大小、各根总占用、没读成的路径）
struct FolderWalkResult {
    let dirs: [String: UInt64]
    let rootTotals: [String: UInt64]
    let unreadable: [String]
}

final class FolderWalkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var walk: FolderWalkResult?
    private var accepted: UInt64?

    /// 新一代扫描开始（generation 为 nil：扫描由别处开始，之后不再接收任何结果）
    func begin(generation: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        walk = nil; accepted = generation
    }

    func offer(_ value: FolderWalkResult, generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard accepted == generation else { return false }
        walk = value
        return true
    }

    /// 开始重测时丢掉上一份目录结果。只在 accepted 仍是期望代时清 walk：
    /// 不改变 accepted，避免把并发新扫描的 generation 倒退，也不碰清单/授权/扫描代。
    func clear(generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard accepted == generation else { return }
        walk = nil
    }

    /// nil = 还没有完成的遍历（pending）
    func current() -> FolderWalkResult? { lock.lock(); defer { lock.unlock() }; return walk }
}
