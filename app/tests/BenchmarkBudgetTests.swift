// SPDX-License-Identifier: MPL-2.0
import Foundation

private func result(full: Double = 14, cancel: Double = 0.05,
                    first: Double = 2, cached: Double? = 0.8,
                    unexplained: Double = 0.005) -> ScanBenchmarkResult {
    ScanBenchmarkResult(machineModel: "Mac16,12", osVersion: "macOS 26",
        filesystem: "apfs", rootIdentifier: "fixture", fileCount: 1_000_000,
        directoryCount: 200_000, cachedDisplaySeconds: cached,
        firstUsefulSeconds: first, fullScanSeconds: full,
        cancellationSeconds: cancel, cpuUserSeconds: 1, cpuSystemSeconds: 1,
        peakRSSBytes: 1, peakOpenFiles: 1, unexplainedRatio: unexplained)
}

@main
struct BenchmarkBudgetTests {
    static func main() throws {
        let pass = BenchmarkBudgetEvaluator().evaluate(try JSONDecoder().decode(
            ScanBenchmarkResult.self, from: JSONEncoder().encode(result())))
        precondition(!pass.hasHardFailure && pass.lines.allSatisfy { $0.level == .pass })

        let warning = BenchmarkBudgetEvaluator().evaluate(result(full: 16, first: 3.1,
            cached: 1.1, unexplained: 0.02))
        precondition(!warning.hasHardFailure)
        precondition(warning.lines.contains { $0.level == .warning })

        precondition(BenchmarkBudgetEvaluator().evaluate(result(full: 20.001)).hasHardFailure)
        precondition(BenchmarkBudgetEvaluator().evaluate(result(cancel: 0.101)).hasHardFailure)
        print("benchmark budgets ok")
    }
}
