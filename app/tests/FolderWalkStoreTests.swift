// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct FolderWalkStoreTests {
    static func walk(_ marker: UInt64) -> FolderWalkResult {
        FolderWalkResult(dirs: ["/h/a": marker], rootTotals: ["/h": marker], unreadable: [])
    }

    static func main() {
        let store = FolderWalkStore()
        // 没有任何一代开始之前、以及开始之后遍历还没好：pending
        precondition(store.current() == nil, "pending before any scan")
        precondition(!store.offer(walk(1), generation: 1), "nothing accepted before a scan begins")
        store.begin(generation: 1)
        precondition(store.current() == nil, "pending until the walk arrives")
        precondition(store.offer(walk(1), generation: 1) && store.current()?.rootTotals["/h"] == 1, "ready after the walk")
        // 旧的一代被拒绝；更新的一代开始后，旧结果被清掉、旧一代晚到的丢弃
        store.begin(generation: 2)
        precondition(store.current() == nil, "a new scan clears the previous walk")
        precondition(!store.offer(walk(9), generation: 1), "stale generation rejected")
        precondition(store.current() == nil)
        precondition(store.offer(walk(2), generation: 2) && store.current()?.rootTotals["/h"] == 2, "newer generation accepted")
        // 没有代次的重置（其他入口开始新扫描）：什么都不再接收
        store.begin(generation: nil)
        precondition(store.current() == nil && !store.offer(walk(3), generation: 2), "reset without a generation accepts nothing")
        print("FolderWalkStoreTests passed")
    }
}
