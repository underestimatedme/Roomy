// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct PathClassifier: EntryClassifier {
    func classify(entry: ScanEntry, context: ClassificationContext) -> [ClassificationEvidence] {
        let path = standardized(context.path)
        var evidence: [ClassificationEvidence] = []

        for rule in RULES {
            guard rule.literalPaths.contains(where: { contains(path, root: standardized($0)) }) else {
                continue
            }
            evidence.append(ClassificationEvidence(
                tag: rule.contentTag,
                confidence: rule.protect ? .exact : .strong,
                source: .legacyRule,
                explanation: rule.protect ? rule.note : rule.evidence,
                cleanup: rule.cleanupCapability
            ))
        }

        let components = URL(fileURLWithPath: path).pathComponents
        if components.contains("node_modules") {
            evidence.append(developerEvidence("Node dependencies can be restored from the project manifest"))
        }
        if components.contains(".venv") {
            evidence.append(developerEvidence("Python environment can be rebuilt from project dependencies"))
        }

        return deduplicated(evidence)
    }

    private func developerEvidence(_ explanation: String) -> ClassificationEvidence {
        ClassificationEvidence(tag: .developerCache, confidence: .strong, source: .path,
            explanation: explanation, cleanup: .rebuildable)
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func contains(_ path: String, root: String) -> Bool {
        let child = URL(fileURLWithPath: path).pathComponents
        let parent = URL(fileURLWithPath: root).pathComponents
        return child.count >= parent.count && Array(child.prefix(parent.count)) == parent
    }

    private func deduplicated(_ evidence: [ClassificationEvidence]) -> [ClassificationEvidence] {
        var best: [ContentTag: ClassificationEvidence] = [:]
        for item in evidence where best[item.tag]?.confidence ?? .heuristic <= item.confidence {
            best[item.tag] = item
        }
        return best.values.sorted { $0.tag.rawValue < $1.tag.rawValue }
    }
}
