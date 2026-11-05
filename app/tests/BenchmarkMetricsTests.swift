// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct BenchmarkMetricsTests {
    static func main() throws {
        let valid = ScanBenchmarkResult(machineModel: "Mac", osVersion: "macOS",
            filesystem: "apfs", rootIdentifier: "fixture", fileCount: 10,
            directoryCount: 2, cachedDisplaySeconds: 1.000,
            firstUsefulSeconds: 3.0, fullScanSeconds: 20.0,
            cancellationSeconds: 0.100, cpuUserSeconds: 1,
            cpuSystemSeconds: 1, peakRSSBytes: 1024, peakOpenFiles: 8,
            unexplainedRatio: 0)
        try valid.validate()
        precondition(valid.passesHardBudgets)

        var missing = valid
        missing.machineModel = ""
        do { try missing.validate(); preconditionFailure("machine model is required") }
        catch is BenchmarkValidationError {}
        missing = valid; missing.fileCount = 0
        do { try missing.validate(); preconditionFailure("file scale is required") }
        catch is BenchmarkValidationError {}

        var slow = valid
        slow.fullScanSeconds = 20.001
        precondition(!slow.passesHardBudgets)
        slow = valid; slow.cancellationSeconds = 0.101
        precondition(!slow.passesHardBudgets)

        let roundTrip = try JSONDecoder().decode(ScanBenchmarkResult.self,
            from: JSONEncoder().encode(valid))
        precondition(roundTrip == valid)
        print("benchmark metrics ok")
    }
}
