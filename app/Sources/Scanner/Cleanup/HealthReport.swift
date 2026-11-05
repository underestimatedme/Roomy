// SPDX-License-Identifier: MPL-2.0
// 健康提醒：只读的发现，不是清理项。交换空间、失效的 Docker 上下文、反复失败的后台服务、本地快照。
// 任一命令失败或超时，对应那一项直接省略；这里没有任何命令会修改系统。
// command 只是给用户看的建议，由用户自己决定是否在终端里执行，Roomy 不会运行它。

import Foundation

struct HealthFinding: Codable, Equatable {
    let id: String
    let title: String
    let detail: String
    let advice: String
    let command: String?
}

enum HealthReport {
    static let swapThreshold = 0.8
    private static let timeout: TimeInterval = 10

    static func collect(runner: CommandRunning, tools: ToolLocator, launchAgents: [CleanupCandidate]) -> [HealthFinding] {
        var out: [HealthFinding] = []
        if let finding = swapFinding(runner: runner, tools: tools) { out.append(finding) }
        out += deadDockerContexts(runner: runner, tools: tools)
        out += launchAgents.map { agent in
            HealthFinding(id: "agent:" + agent.entry.id, title: agent.entry.title, detail: agent.entry.evidence,
                          advice: "它启动的程序反复失败；确认对应的应用是否还需要，不需要就在系统设置的登录项里关掉它",
                          command: nil)
        }
        if let finding = snapshotFinding(runner: runner, tools: tools) { out.append(finding) }
        return out
    }

    // MARK: 交换空间

    /// "total = 11264.00M  used = 10892.50M  free = 371.50M  (encrypted)"；单位 K / M / G，1 M = 1_048_576 字节
    static func parseSwap(_ s: String) -> (total: UInt64, used: UInt64)? {
        func value(_ key: String) -> UInt64? {
            guard let range = s.range(of: key + " = ") else { return nil }
            let token = s[range.upperBound...].prefix { !$0.isWhitespace }
            guard let unit = token.last, let number = Double(token.dropLast()), number >= 0, number.isFinite else { return nil }
            let scale: Double
            switch unit {
            case "K": scale = 1_024
            case "M": scale = 1_048_576
            case "G": scale = 1_073_741_824
            default: return nil
            }
            return UInt64((number * scale).rounded())
        }
        guard let total = value("total"), let used = value("used") else { return nil }
        return (total, used)
    }

    private static func swapFinding(runner: CommandRunning, tools: ToolLocator) -> HealthFinding? {
        guard let sysctl = tools.path(for: .sysctl) else { return nil }
        let r = runner.run(sysctl, ["vm.swapusage"], timeout: timeout)
        guard r.ok, let (total, used) = parseSwap(r.stdout), total > 0, Double(used) / Double(total) >= swapThreshold else { return nil }
        return HealthFinding(id: "swap", title: "交换空间快满了", detail: "已用 \(size(used)) / 共 \(size(total))",
                             advice: "关闭不用的应用或重启可缓解；磁盘越满，交换越容易出问题", command: nil)
    }

    // MARK: Docker context

    private static func deadDockerContexts(runner: CommandRunning, tools: ToolLocator) -> [HealthFinding] {
        guard let docker = tools.path(for: .docker) else { return [] }
        let r = ToolInvocation.run(.docker, executable: docker, ["context", "ls", "--format", "{{json .}}"],
                                   runner: runner, tools: tools, timeout: timeout)
        guard r.ok else { return [] }
        var out: [HealthFinding] = []
        for line in r.stdout.split(whereSeparator: \.isNewline) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = row["Name"] as? String, name != "default", CleanupArgument.isDockerReference(name),
                  (row["Current"] as? Bool) != true,
                  let endpoint = (row["DockerEndpoint"] ?? row["Endpoint"]) as? String,
                  endpoint.hasPrefix("unix://") else { continue }
            let socket = String(endpoint.dropFirst("unix://".count))
            // 只看 socket 文件在不在；不去连它，也不碰 unix 以外的端点
            guard socket.hasPrefix("/"), !FileManager.default.fileExists(atPath: socket) else { continue }
            out.append(HealthFinding(id: "docker-context:" + name, title: "Docker 上下文 \(name) 已失效",
                detail: "它指向的 socket 已不存在：\(socket)",
                advice: "这个上下文已经连不上；确认不再需要后，可以在终端里删除它的配置",
                command: "docker context rm \(name)"))
        }
        return out
    }

    // MARK: 本地快照

    private static func snapshotFinding(runner: CommandRunning, tools: ToolLocator) -> HealthFinding? {
        guard let tmutil = tools.path(for: .tmutil) else { return nil }
        let r = runner.run(tmutil, ["listlocalsnapshots", "/"], timeout: timeout)
        guard r.ok else { return nil }
        let count = r.stdout.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("com.apple.") }.count
        guard count > 0 else { return nil }
        return HealthFinding(id: "local-snapshots", title: "有 \(count) 个本地快照",
                             detail: "时间机器在本机留了 \(count) 个本地快照",
                             advice: "快照会占用空间，系统会在空间紧张时自动清理", command: nil)
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}
