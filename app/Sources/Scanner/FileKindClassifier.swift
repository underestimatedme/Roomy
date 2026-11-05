// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct FileKindClassifier: EntryClassifier {
    private static let modelExtensions: Set<String> = [
        "gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "bin"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm"
    ]
    private static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "tiff", "raw", "dng"
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "pages", "xls", "xlsx", "ppt", "pptx", "txt", "md"
    ]
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "iso"]

    func classify(entry: ScanEntry, context: ClassificationContext) -> [ClassificationEvidence] {
        guard entry.kind == .file else { return [] }
        let ext = context.pathExtension
        var result: [ClassificationEvidence] = []

        if Self.modelExtensions.contains(ext) || context.name.lowercased().hasSuffix(".safetensors.index.json") {
            result.append(ClassificationEvidence(tag: .aiModel, confidence: .heuristic,
                source: .fileExtension, explanation: "文件格式常用于机器学习模型",
                cleanup: .none))
        }
        if Self.videoExtensions.contains(ext) || Self.imageExtensions.contains(ext) {
            result.append(ClassificationEvidence(tag: .media, confidence: .strong,
                source: .fileExtension, explanation: "媒体文件格式", cleanup: .reviewRequired))
        }
        if Self.documentExtensions.contains(ext) {
            result.append(ClassificationEvidence(tag: .document, confidence: .strong,
                source: .fileExtension, explanation: "文档文件格式", cleanup: .reviewRequired))
        }
        if Self.installerExtensions.contains(ext), isInDownloads(context.path) {
            result.append(ClassificationEvidence(tag: .download, confidence: .strong,
                source: .path, explanation: "下载目录中的安装介质", cleanup: .reviewRequired))
        }
        return result
    }

    private func isInDownloads(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let downloads = URL(fileURLWithPath: HOME).appendingPathComponent("Downloads")
            .standardizedFileURL.pathComponents
        return components.count >= downloads.count && Array(components.prefix(downloads.count)) == downloads
    }
}
