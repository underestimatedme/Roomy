// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

private final class RecordingManifestReader: ManifestReading, @unchecked Sendable {
    private(set) var paths: [String] = []
    func readJSON(at url: URL, maxBytes: Int) -> ManifestReadOutcome {
        paths.append(url.path)
        return ManifestReader().readJSON(at: url, maxBytes: maxBytes)
    }
}

private func makeIndex(root: String, names: [String]) -> ScanIndex {
    var index = ScanIndex(rootPath: root)
    _ = index.append(parentID: 0, fileID: 1, deviceID: 1, name: "", kind: .directory,
        logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
    for (offset, name) in names.enumerated() {
        _ = index.append(parentID: 0, fileID: UInt64(offset + 2), deviceID: 1, name: name,
            kind: .file, logicalSize: 1, allocatedSize: 1, modifiedAt: 1, flags: [])
    }
    index.finalizeAggregates()
    return index
}

@main
struct AIManifestClassifierTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("roomy-manifest-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let ollamaRelative = ".ollama/models/manifests/registry/model/latest"
        let ollama = temp.appendingPathComponent(ollamaRelative)
        try fm.createDirectory(at: ollama.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"qwen2.5","digest":"sha256:abc","format":"gguf","quantization":"Q4_K_M","ignored":"private"}"#.utf8).write(to: ollama)
        let huggingFaceRelative = ".cache/huggingface/hub/models--org--repo/snapshots/abc/config.json"
        let huggingFace = temp.appendingPathComponent(huggingFaceRelative)
        try fm.createDirectory(at: huggingFace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"repository":"org/repo","revision":"abc123","ignored":"private"}"#.utf8).write(to: huggingFace)
        let malformed = temp.appendingPathComponent("malformed.json")
        try Data("{".utf8).write(to: malformed)
        let oversized = temp.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 1_048_577).write(to: oversized)
        let symlink = temp.appendingPathComponent("link.json")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: ollama)

        let reader = ManifestReader()
        guard case .value = reader.readJSON(at: ollama, maxBytes: 1_048_576) else {
            preconditionFailure("valid manifest should parse")
        }
        guard case .malformed = reader.readJSON(at: malformed, maxBytes: 1_048_576) else {
            preconditionFailure("malformed manifest should be ignored")
        }
        guard case .tooLarge = reader.readJSON(at: oversized, maxBytes: 1_048_576) else {
            preconditionFailure("oversized manifest should be ignored")
        }
        guard case .notRegular = reader.readJSON(at: symlink, maxBytes: 1_048_576) else {
            preconditionFailure("symlinked manifest should not be followed")
        }

        let fifo = temp.appendingPathComponent("manifest-fifo")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        let fifoDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            guard case .notRegular = reader.readJSON(at: fifo, maxBytes: 1_048_576) else {
                preconditionFailure("FIFO should be rejected")
            }
            fifoDone.signal()
        }
        precondition(fifoDone.wait(timeout: .now() + 1) == .success,
            "manifest reader must not block opening a FIFO")

        let transcript = temp.appendingPathComponent("conversation.jsonl")
        try Data(#"{"messages":["private"]}"#.utf8).write(to: transcript)
        let index = makeIndex(root: temp.path, names: [
            ollamaRelative, huggingFaceRelative, transcript.lastPathComponent
        ])
        let candidates = index.entries.dropFirst().map {
            ClassifiedEntry(entryID: $0.id, tags: [.aiModel], evidence: [])
        }
        let recording = RecordingManifestReader()
        let enriched = AIManifestClassifier(reader: recording).enrich(candidates, index: index)
        precondition(enriched[0].evidence.contains { $0.confidence == .exact && $0.source == .manifest })
        precondition(enriched[1].evidence.contains { $0.confidence == .exact && $0.source == .manifest })
        precondition(!recording.paths.contains(transcript.path), "conversation transcripts must never be opened")
        precondition(enriched[0].evidence.allSatisfy { !$0.explanation.contains("private") })

        let payload = temp.appendingPathComponent("ollama-manifest.gguf")
        try Data(#"{"model":"must-not-open"}"#.utf8).write(to: payload)
        let payloadIndex = makeIndex(root: temp.path, names: [payload.lastPathComponent])
        let payloadRecording = RecordingManifestReader()
        _ = AIManifestClassifier(reader: payloadRecording).enrich([
            ClassifiedEntry(entryID: 1, evidence: [ClassificationEvidence(tag: .aiModel,
                confidence: .heuristic, source: .fileExtension, explanation: "fixture", cleanup: .none)])
        ], index: payloadIndex)
        precondition(payloadRecording.paths.isEmpty, "model payload filename must never be opened")
        precondition(!classifyScanIndex(payloadIndex).flatMap(\.evidence)
            .contains(where: { $0.source == .manifest }),
            "the full classifier pipeline must not enrich a model payload")
        print("AI manifest classifier ok")
    }
}
