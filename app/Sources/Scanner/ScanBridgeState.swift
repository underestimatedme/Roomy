// SPDX-License-Identifier: MPL-2.0
import Foundation

struct ScanBridgeState: Equatable, Sendable {
    private(set) var generation: ScanGeneration?
    private(set) var sequence: UInt64 = 0
    private(set) var cancelled = false

    mutating func start(generation: ScanGeneration) {
        self.generation = generation
        sequence = 0
        cancelled = false
    }

    mutating func accept(generation: ScanGeneration, sequence: UInt64) -> Bool {
        guard self.generation == generation, !cancelled, sequence > self.sequence else {
            return false
        }
        self.sequence = sequence
        return true
    }

    @discardableResult
    mutating func cancel(generation: ScanGeneration) -> Bool {
        guard self.generation == generation, !cancelled else { return false }
        cancelled = true
        return true
    }

    func isActive(generation: ScanGeneration) -> Bool {
        self.generation == generation && !cancelled
    }
}
