// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private struct NoopClassifier: EntryClassifier {
    func classify(entry: ScanEntry, context: ClassificationContext) -> [ClassificationEvidence] { [] }
}

@main
struct ClassificationTests {
    static func main() throws {
        let evidence = ClassificationEvidence(tag: .aiModel, confidence: .exact,
            source: .manifest, explanation: "Ollama manifest references this blob",
            cleanup: .reviewRequired)
        let result = ClassifiedEntry(entryID: 9, tags: [.aiModel, .download],
            evidence: [evidence])
        precondition(Set(result.tags) == [.aiModel, .download])
        precondition(evidence.source == .manifest)
        precondition(!evidence.explanation.isEmpty)
        precondition(EvidenceConfidence.exact > .strong)
        precondition(EvidenceConfidence.strong > .heuristic)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ClassifiedEntry.self, from: data)
        precondition(decoded == result)
        let _: any EntryClassifier = NoopClassifier()
        print("classification contracts ok")
    }
}
