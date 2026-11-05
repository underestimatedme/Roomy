// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct AIManifestClassifier: Sendable {
    private let reader: any ManifestReading
    private let maxBytes = 1_048_576

    init(reader: any ManifestReading = ManifestReader()) {
        self.reader = reader
    }

    func enrich(_ candidates: [ClassifiedEntry], index: ScanIndex) -> [ClassifiedEntry] {
        candidates.map { candidate in
            guard candidate.tags.contains(.aiModel),
                  Int(candidate.entryID) < index.entries.count,
                  index.entries[Int(candidate.entryID)].kind == .file else { return candidate }
            let path = index.path(for: candidate.entryID)
            guard let kind = manifestKind(path) else { return candidate }
            guard case .value(let json) = reader.readJSON(
                at: URL(fileURLWithPath: path), maxBytes: maxBytes
            ) else { return candidate }

            let fields: [String]
            switch kind {
            case .ollama:
                fields = whitelistedStrings(json, keys: [
                    "model", "name", "digest", "format", "quantization"
                ])
            case .huggingFace:
                fields = whitelistedStrings(json, keys: [
                    "repository", "repo_id", "revision", "commit_hash", "model_type"
                ])
            }
            guard !fields.isEmpty else { return candidate }
            let evidence = ClassificationEvidence(tag: .aiModel, confidence: .exact,
                source: .manifest, explanation: fields.joined(separator: " · "),
                cleanup: .reviewRequired)
            return ClassifiedEntry(entryID: candidate.entryID,
                tags: candidate.tags, evidence: candidate.evidence + [evidence])
        }
    }

    private enum ManifestKind { case ollama, huggingFace }

    private func manifestKind(_ path: String) -> ManifestKind? {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: lower).lastPathComponent
        if lower.contains("/.ollama/models/manifests/") {
            return .ollama
        }
        if lower.contains("/.cache/huggingface/hub/") && name == "config.json" {
            return .huggingFace
        }
        return nil
    }

    private func whitelistedStrings(_ value: JSONValue, keys: Set<String>) -> [String] {
        var result: [String] = []
        func visit(_ value: JSONValue) {
            switch value {
            case .object(let object):
                for (key, value) in object {
                    if keys.contains(key.lowercased()), case .string(let text) = value {
                        result.append("\(key): \(String(text.prefix(160)))")
                    } else if key == "config" || key == "details" {
                        visit(value)
                    }
                }
            case .array(let values): values.prefix(64).forEach(visit)
            default: break
            }
        }
        visit(value)
        return result.sorted()
    }
}
