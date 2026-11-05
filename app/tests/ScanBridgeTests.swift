// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct ScanBridgeTests {
    static func main() {
        var state = ScanBridgeState()
        state.start(generation: 4)
        precondition(state.accept(generation: 4, sequence: 1))
        precondition(state.accept(generation: 4, sequence: 2))
        precondition(!state.accept(generation: 3, sequence: 99))
        precondition(!state.accept(generation: 4, sequence: 1))
        precondition(state.cancel(generation: 4))
        precondition(!state.cancel(generation: 4), "cancel should be idempotent")
        precondition(!state.accept(generation: 4, sequence: 3),
            "late snapshots after cancellation must be suppressed")
        state.start(generation: 5)
        precondition(state.accept(generation: 5, sequence: 1))
        let partial = PartialScanSnapshot(generation: 5, sequence: 1,
            rootPath: NSHomeDirectory(), files: 12, directories: 3, allocatedBytes: 4096)
        let report = buildPartialReport(partial, sequence: 2)
        precondition(report.version == 2 && !report.complete)
        precondition(report.diskTree.allocatedBytes == 4096)
        precondition(report.diskTree.children.first?.allocatedBytes == 4096)
        print("scan bridge state ok")
    }
}
