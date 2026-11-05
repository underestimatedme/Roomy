// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct ReclaimEstimateTests {
    static func main() {
        var index = ScanIndex(rootPath: "/tmp/fixture")
        _ = index.append(parentID: 0, fileID: 1, deviceID: 1, name: "",
            kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        let unique = index.append(parentID: 0, fileID: 2, deviceID: 1, name: "unique",
            kind: .file, logicalSize: 100, allocatedSize: 100, modifiedAt: 1, flags: [])
        let duplicate = index.append(parentID: 0, fileID: 2, deviceID: 1, name: "duplicate",
            kind: .file, logicalSize: 100, allocatedSize: 0, modifiedAt: 1, flags: [],
            physicalAllocatedSize: 100)
        let shared = index.append(parentID: 0, fileID: 3, deviceID: 1, name: "clone",
            kind: .file, logicalSize: 200, allocatedSize: 200, modifiedAt: 1,
            flags: [.mayShareContent])
        index.finalizeAggregates()

        let estimator = ReclaimEstimator()
        precondition(estimator.estimate(index: index, entryID: unique,
            cleanupAllowed: true) == .exact(100))
        precondition(estimator.estimate(index: index, entryID: duplicate,
            cleanupAllowed: true) == .exact(0))
        precondition(estimator.estimate(index: index, entryID: shared,
            cleanupAllowed: true) == .shared(upperBound: 200))
        if case .none = estimator.estimate(index: index, entryID: unique,
            cleanupAllowed: false) {} else { preconditionFailure("blocked item must have no estimate") }

        let totals = ReclaimTotals.sum([.exact(100), .shared(upperBound: 200),
            .range(lower: 40, upper: 90), .none(reason: "protected")])
        precondition(totals.exactBytes == 140)
        precondition(totals.possibleAdditionalBytes == 250)
        print("reclaim estimate ok")
    }
}
