// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ReclaimEstimate: Equatable, Sendable {
    case exact(UInt64)
    case shared(upperBound: UInt64)
    case range(lower: UInt64, upper: UInt64)
    case none(reason: String)
}

extension ReclaimEstimate: Codable {
    private enum Keys: String, CodingKey { case kind, lower, upper, reason }
    private enum Kind: String, Codable { case exact, shared, range, none }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .exact: self = .exact(try values.decode(UInt64.self, forKey: .upper))
        case .shared: self = .shared(upperBound: try values.decode(UInt64.self, forKey: .upper))
        case .range: self = .range(lower: try values.decode(UInt64.self, forKey: .lower),
            upper: try values.decode(UInt64.self, forKey: .upper))
        case .none: self = .none(reason: try values.decode(String.self, forKey: .reason))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .exact(let bytes):
            try values.encode(Kind.exact, forKey: .kind)
            try values.encode(bytes, forKey: .lower); try values.encode(bytes, forKey: .upper)
        case .shared(let upper):
            try values.encode(Kind.shared, forKey: .kind)
            try values.encode(UInt64(0), forKey: .lower); try values.encode(upper, forKey: .upper)
        case .range(let lower, let upper):
            try values.encode(Kind.range, forKey: .kind)
            try values.encode(lower, forKey: .lower); try values.encode(upper, forKey: .upper)
        case .none(let reason):
            try values.encode(Kind.none, forKey: .kind); try values.encode(reason, forKey: .reason)
        }
    }
}

struct ReclaimTotals: Equatable, Sendable {
    let exactBytes: UInt64
    let possibleAdditionalBytes: UInt64

    static func sum(_ estimates: [ReclaimEstimate]) -> ReclaimTotals {
        var exact: UInt64 = 0
        var possible: UInt64 = 0
        for estimate in estimates {
            switch estimate {
            case .exact(let bytes): exact &+= bytes
            case .shared(let upper): possible &+= upper
            case .range(let lower, let upper):
                exact &+= lower; possible &+= upper >= lower ? upper - lower : 0
            case .none: break
            }
        }
        return ReclaimTotals(exactBytes: exact, possibleAdditionalBytes: possible)
    }
}

struct ReclaimEstimator: Sendable {
    func estimate(index: ScanIndex, entryID: EntryID, cleanupAllowed: Bool) -> ReclaimEstimate {
        guard cleanupAllowed else { return .none(reason: "项目受保护或不可撤销") }
        var stack = [entryID]
        var exact: UInt64 = 0
        var shared: UInt64 = 0
        while let id = stack.popLast() {
            let entry = index.entries[Int(id)]
            if entry.flags.contains(.mayShareContent) { shared &+= entry.allocatedSize }
            else { exact &+= entry.allocatedSize }
            stack.append(contentsOf: index.children(of: id))
        }
        if shared == 0 { return .exact(exact) }
        if exact == 0 { return .shared(upperBound: shared) }
        return .range(lower: exact, upper: exact &+ shared)
    }
}
