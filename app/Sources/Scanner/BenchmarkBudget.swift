// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum BenchmarkBudgetLevel: String, Codable, Equatable, Sendable {
    case pass
    case warning
    case failure
}

struct BenchmarkBudgetLine: Equatable, Sendable {
    let metric: String
    let measured: String
    let target: String
    let level: BenchmarkBudgetLevel
}

struct BenchmarkBudgetEvaluation: Equatable, Sendable {
    let lines: [BenchmarkBudgetLine]
    var hasHardFailure: Bool { lines.contains { $0.level == .failure } }
}

struct BenchmarkBudgetEvaluator: Sendable {
    func evaluate(_ result: ScanBenchmarkResult) -> BenchmarkBudgetEvaluation {
        var lines: [BenchmarkBudgetLine] = []
        let fullLevel: BenchmarkBudgetLevel = result.fullScanSeconds > 20 ? .failure :
            result.fullScanSeconds > 15 ? .warning : .pass
        lines.append(line("full scan", result.fullScanSeconds, "≤15s target, ≤20s hard", fullLevel))
        lines.append(line("cancellation", result.cancellationSeconds, "≤0.100s hard",
            result.cancellationSeconds > 0.100 ? .failure : .pass))
        lines.append(line("first useful", result.firstUsefulSeconds, "≤3s",
            result.firstUsefulSeconds > 3 ? .warning : .pass))
        if let cached = result.cachedDisplaySeconds {
            lines.append(line("cached display", cached, "≤1s", cached > 1 ? .warning : .pass))
        } else {
            lines.append(BenchmarkBudgetLine(metric: "cached display", measured: "unavailable",
                target: "≤1s", level: .warning))
        }
        lines.append(line("unexplained ratio", result.unexplainedRatio, "≤0.010",
            result.unexplainedRatio > 0.01 ? .warning : .pass))
        return BenchmarkBudgetEvaluation(lines: lines)
    }

    private func line(_ metric: String, _ value: Double, _ target: String,
                      _ level: BenchmarkBudgetLevel) -> BenchmarkBudgetLine {
        BenchmarkBudgetLine(metric: metric, measured: String(format: "%.3f", value),
            target: target, level: level)
    }
}
