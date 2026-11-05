// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func entry(kind: EntryKind = .directory) -> ScanEntry {
    ScanEntry(id: 1, parentID: 0, fileID: 2, deviceID: 3, nameID: 0,
        kind: kind, logicalSize: 10, allocatedSize: 10, modifiedAt: 1, flags: [])
}

private func classify(_ path: String, kind: EntryKind = .directory) -> [ClassificationEvidence] {
    let context = ClassificationContext(path: path, rootPath: HOME)
    return PathClassifier().classify(entry: entry(kind: kind), context: context) +
        FileKindClassifier().classify(entry: entry(kind: kind), context: context)
}

private func expect(_ path: String, tag: ContentTag, minimum: EvidenceConfidence,
                    kind: EntryKind = .directory) {
    let evidence = classify(path, kind: kind)
    precondition(evidence.contains { $0.tag == tag && $0.confidence >= minimum },
        "missing \(tag) for \(path): \(evidence)")
}

@main
struct PathClassifierTests {
    static func main() {
        let strongAI = [
            "\(HOME)/.ollama/models/blobs/sha256-a",
            "\(HOME)/.cache/huggingface/hub/models--org--repo/snapshots/rev/model.safetensors",
            "\(HOME)/.lmstudio/models/org/model/model.gguf",
            "\(HOME)/.cache/mlx/model/weights.safetensors",
            "\(HOME)/ComfyUI/models/checkpoints/model.ckpt"
        ]
        for path in strongAI { expect(path, tag: .aiModel, minimum: .strong) }

        expect("\(HOME)/.claude/projects/project/session.jsonl", tag: .aiSession, minimum: .strong)
        expect("\(HOME)/.codex/sessions/2026/thread.jsonl", tag: .aiSession, minimum: .strong)
        expect("\(HOME)/Library/Application Support/Cursor/User/workspaceStorage/id",
            tag: .aiSession, minimum: .strong)
        expect("\(HOME)/Library/Developer/Xcode/DerivedData/App-hash", tag: .developerCache,
            minimum: .strong)
        expect("\(HOME)/Library/Android/sdk/system-images/android-36", tag: .developerCache,
            minimum: .strong)
        expect("\(HOME)/code/app/node_modules", tag: .developerCache, minimum: .strong)
        expect("\(HOME)/code/app/.venv", tag: .developerCache, minimum: .strong)
        expect("\(HOME)/Downloads/tool.dmg", tag: .download, minimum: .strong, kind: .file)
        expect("\(HOME)/Movies/demo.mp4", tag: .media, minimum: .strong, kind: .file)
        expect("\(HOME)/Pictures/photo.heic", tag: .media, minimum: .strong, kind: .file)
        expect("\(HOME)/Documents/report.pdf", tag: .document, minimum: .strong, kind: .file)

        let outside = classify("\(HOME)/Documents/random.gguf", kind: .file)
        guard let candidate = outside.first(where: { $0.tag == .aiModel }) else {
            preconditionFailure("extension should identify a model candidate")
        }
        precondition(candidate.confidence == .heuristic)
        precondition(candidate.cleanup == .none)
        precondition(!outside.contains { $0.tag == .aiModel && $0.confidence > .heuristic })

        let credentials = classify("\(HOME)/.claude/.credentials.json", kind: .file)
        precondition(credentials.contains { $0.tag == .systemManaged && $0.cleanup == .none })
        print("path classifiers ok")
    }
}
