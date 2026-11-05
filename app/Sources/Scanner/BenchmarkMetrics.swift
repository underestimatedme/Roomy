// SPDX-License-Identifier: MPL-2.0
import Foundation

enum BenchmarkValidationError: Error, Equatable {
    case missing(String)
    case invalid(String)
}

struct ScanBenchmarkResult: Equatable, Sendable {
    var machineModel: String
    var osVersion: String
    var filesystem: String
    var rootIdentifier: String
    var fileCount: Int
    var directoryCount: Int
    var cachedDisplaySeconds: Double?
    var firstUsefulSeconds: Double
    var fullScanSeconds: Double
    var cancellationSeconds: Double
    var cpuUserSeconds: Double
    var cpuSystemSeconds: Double
    var peakRSSBytes: UInt64
    var peakOpenFiles: Int
    var unexplainedRatio: Double

    func validate() throws {
        for (name, value) in [("machineModel", machineModel), ("osVersion", osVersion),
                              ("filesystem", filesystem), ("rootIdentifier", rootIdentifier)] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BenchmarkValidationError.missing(name)
            }
        }
        guard fileCount > 0, directoryCount > 0 else {
            throw BenchmarkValidationError.missing("data scale")
        }
        let values = [firstUsefulSeconds, fullScanSeconds, cancellationSeconds,
                      cpuUserSeconds, cpuSystemSeconds, unexplainedRatio] +
            (cachedDisplaySeconds.map { [$0] } ?? [])
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), peakRSSBytes > 0,
              peakOpenFiles > 0 else { throw BenchmarkValidationError.invalid("metrics") }
    }

    var passesHardBudgets: Bool {
        fullScanSeconds <= 20.0 && cancellationSeconds <= 0.100
    }
}

extension ScanBenchmarkResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case machineModel, osVersion, filesystem, rootIdentifier, fileCount, directoryCount
        case cachedDisplaySeconds, firstUsefulSeconds, fullScanSeconds, cancellationSeconds
        case cpuUserSeconds, cpuSystemSeconds, peakRSSBytes, peakOpenFiles, unexplainedRatio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machineModel = try c.decode(String.self, forKey: .machineModel)
        osVersion = try c.decode(String.self, forKey: .osVersion)
        filesystem = try c.decode(String.self, forKey: .filesystem)
        rootIdentifier = try c.decode(String.self, forKey: .rootIdentifier)
        fileCount = try c.decode(Int.self, forKey: .fileCount)
        directoryCount = try c.decode(Int.self, forKey: .directoryCount)
        cachedDisplaySeconds = try c.decodeIfPresent(Double.self, forKey: .cachedDisplaySeconds)
        firstUsefulSeconds = try c.decode(Double.self, forKey: .firstUsefulSeconds)
        fullScanSeconds = try c.decode(Double.self, forKey: .fullScanSeconds)
        cancellationSeconds = try c.decode(Double.self, forKey: .cancellationSeconds)
        cpuUserSeconds = try c.decode(Double.self, forKey: .cpuUserSeconds)
        cpuSystemSeconds = try c.decode(Double.self, forKey: .cpuSystemSeconds)
        peakRSSBytes = try c.decode(UInt64.self, forKey: .peakRSSBytes)
        peakOpenFiles = try c.decode(Int.self, forKey: .peakOpenFiles)
        unexplainedRatio = try c.decode(Double.self, forKey: .unexplainedRatio)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machineModel, forKey: .machineModel); try c.encode(osVersion, forKey: .osVersion)
        try c.encode(filesystem, forKey: .filesystem); try c.encode(rootIdentifier, forKey: .rootIdentifier)
        try c.encode(fileCount, forKey: .fileCount); try c.encode(directoryCount, forKey: .directoryCount)
        if let cachedDisplaySeconds { try c.encode(cachedDisplaySeconds, forKey: .cachedDisplaySeconds) }
        else { try c.encodeNil(forKey: .cachedDisplaySeconds) }
        try c.encode(firstUsefulSeconds, forKey: .firstUsefulSeconds)
        try c.encode(fullScanSeconds, forKey: .fullScanSeconds)
        try c.encode(cancellationSeconds, forKey: .cancellationSeconds)
        try c.encode(cpuUserSeconds, forKey: .cpuUserSeconds); try c.encode(cpuSystemSeconds, forKey: .cpuSystemSeconds)
        try c.encode(peakRSSBytes, forKey: .peakRSSBytes); try c.encode(peakOpenFiles, forKey: .peakOpenFiles)
        try c.encode(unexplainedRatio, forKey: .unexplainedRatio)
    }
}
