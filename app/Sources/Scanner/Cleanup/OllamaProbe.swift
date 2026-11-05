// SPDX-License-Identifier: MPL-2.0
// Ollama 的模型由它自己的清单库管理；删 blob 不删 manifest 会弄脏它，所以只走 ollama rm。

import Foundation

enum OllamaProbe {
    struct Model: Equatable {
        let name: String
        let size: UInt64
        let idleDays: Int?
    }

    static func parseList(_ text: String) -> [Model] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let cols = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cols.count >= 4, let size = parseSize(cols[2]) else { return nil }
            return Model(name: cols[0], size: size, idleDays: parseAgo(cols[3]))
        }
    }

    /// ollama 用十进制单位："39 GB"、"274 MB"
    static func parseSize(_ text: String) -> UInt64? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let scale: Double
        switch parts[1].uppercased() {
        case "B": scale = 1
        case "KB": scale = 1e3
        case "MB": scale = 1e6
        case "GB": scale = 1e9
        case "TB": scale = 1e12
        default: return nil
        }
        return UInt64((value * scale).rounded())
    }

    static func parseAgo(_ text: String) -> Int? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        let units: [String: Int] = ["second": 0, "minute": 0, "hour": 0, "day": 1, "week": 7, "month": 30, "year": 365]
        for (i, word) in words.enumerated() {
            let unit = word.hasSuffix("s") ? String(word.dropLast()) : word
            guard let days = units[unit] else { continue }
            guard i > 0 else { return days }
            let count = Int(words[i - 1]) ?? 1   // "a" / "an" / "about an" 都按 1
            return days * count
        }
        return nil
    }

    static func candidates(_ models: [Model]) -> [CleanupCandidate] {
        models.filter { CleanupArgument.isModelName($0.name) }.map { m in
            let evidence = m.idleDays.flatMap { Humanize.span(days: $0) }.map { "\($0)没更新过" } ?? "今天刚更新过"
            return CleanupCandidate(source: "ollama", key: m.name, title: "Ollama · \(m.name)", size: m.size,
                evidence: evidence, risk: .amber, action: .ollamaRemove(model: m.name))
        }
    }

    static func probe(runner: CommandRunning, tools: ToolLocator) -> [CleanupCandidate] {
        guard let models = list(runner: runner, tools: tools) else { return [] }
        return candidates(models)
    }

    static func modelBlocker(model: String, runner: CommandRunning, tools: ToolLocator) -> String? {
        guard let models = list(runner: runner, tools: tools) else { return "无法读取 Ollama 模型列表" }
        return models.contains { $0.name == model } ? nil : "这个模型已经不在 Ollama 里了"
    }

    private static func list(runner: CommandRunning, tools: ToolLocator) -> [Model]? {
        guard let ollama = tools.path(for: .ollama) else { return nil }
        let r = runner.run(ollama, ["list"], timeout: 10)
        return r.ok ? parseList(r.stdout) : nil
    }
}
