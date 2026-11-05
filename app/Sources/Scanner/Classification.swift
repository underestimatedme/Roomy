// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ContentTag: String, Codable, Hashable, Sendable {
    case aiModel
    case aiSession
    case developerCache
    case applicationData
    case download
    case media
    case document
    case duplicateCandidate
    case systemManaged
}

enum EvidenceConfidence: Int, Codable, Comparable, Sendable {
    case heuristic = 1
    case strong = 2
    case exact = 3

    static func < (lhs: EvidenceConfidence, rhs: EvidenceConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum EvidenceSource: String, Codable, Sendable {
    case path
    case fileExtension
    case manifest
    case legacyRule
}

enum CleanupCapability: String, Codable, Sendable {
    case none
    case reviewRequired
    case rebuildable
}

struct ClassificationEvidence: Codable, Equatable, Sendable {
    let tag: ContentTag
    let confidence: EvidenceConfidence
    let source: EvidenceSource
    let explanation: String
    let cleanup: CleanupCapability
}

struct ClassifiedEntry: Codable, Equatable, Sendable {
    let entryID: EntryID
    let tags: [ContentTag]
    let evidence: [ClassificationEvidence]

    init(entryID: EntryID, tags: [ContentTag], evidence: [ClassificationEvidence]) {
        self.entryID = entryID
        var seen: Set<ContentTag> = []
        self.tags = tags.filter { seen.insert($0).inserted }
        self.evidence = evidence
    }

    init(entryID: EntryID, evidence: [ClassificationEvidence]) {
        self.init(entryID: entryID, tags: evidence.map(\.tag), evidence: evidence)
    }
}

struct ClassificationContext: Equatable, Sendable {
    let path: String
    let rootPath: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var pathExtension: String { URL(fileURLWithPath: path).pathExtension.lowercased() }
}

protocol EntryClassifier: Sendable {
    func classify(entry: ScanEntry, context: ClassificationContext) -> [ClassificationEvidence]
}
