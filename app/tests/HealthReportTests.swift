// SPDX-License-Identifier: MPL-2.0
import Foundation

final class FakeRunner: CommandRunning {
    var responses: [String: CommandResult] = [:]
    private(set) var calls: [String] = []
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let key = ([executable] + arguments).joined(separator: " ")
        calls.append(key)
        return responses[key] ?? CommandResult(status: 1, stdout: "", stderr: "unexpected \(key)", timedOut: false)
    }
}

private func ok(_ text: String) -> CommandResult { CommandResult(status: 0, stdout: text, stderr: "", timedOut: false) }
private func failed() -> CommandResult { CommandResult(status: 1, stdout: "", stderr: "boom", timedOut: false) }
private func timedOut() -> CommandResult { CommandResult(status: -1, stdout: "", stderr: "", timedOut: true) }

private func contextLine(_ name: String, _ endpoint: String, current: Bool = false) -> String {
    "{\"Current\":\(current),\"Description\":\"fixture\",\"DockerEndpoint\":\"\(endpoint)\",\"Error\":\"\",\"Name\":\"\(name)\"}"
}

@main
struct HealthReportTests {
    static func main() throws {
        // parseSwap
        let parsed = HealthReport.parseSwap("total = 11264.00M  used = 10892.50M  free = 371.50M  (encrypted)")
        precondition(parsed?.total == 11_811_160_064 && parsed?.used == 11_421_614_080, "parseSwap: \(String(describing: parsed))")
        precondition(HealthReport.parseSwap("total = 2.00G  used = 1.00G  free = 1.00G")?.total == 2_147_483_648)
        precondition(HealthReport.parseSwap("garbage") == nil)
        precondition(HealthReport.parseSwap("") == nil)

        let sysctl = "/usr/sbin/sysctl", tmutil = "/usr/bin/tmutil", docker = "/fake/docker"
        let tools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { _ in true }, dockerHost: nil)
        let swapKey = "\(sysctl) vm.swapusage"
        let tmKey = "\(tmutil) listlocalsnapshots /"
        let ctxKey = "\(docker) context ls --format {{json .}}"
        precondition(tools.path(for: .sysctl) == sysctl && tools.path(for: .tmutil) == tmutil)

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("roomy-health-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let liveSocket = dir + "/live.sock"
        try "".write(toFile: liveSocket, atomically: true, encoding: .utf8)
        let missingSocket = dir + "/gone/docker.sock"

        func collect(_ r: FakeRunner, agents: [CleanupCandidate] = []) -> [HealthFinding] {
            HealthReport.collect(runner: r, tools: tools, launchAgents: agents)
        }

        // 70% 不报，97% 报
        let r1 = FakeRunner()
        r1.responses[swapKey] = ok("vm.swapusage: total = 10000.00M  used = 7000.00M  free = 3000.00M  (encrypted)\n")
        r1.responses[tmKey] = failed(); r1.responses[ctxKey] = failed()
        precondition(collect(r1).isEmpty, "70% swap is not reported")

        r1.responses[swapKey] = ok("vm.swapusage: total = 11264.00M  used = 10892.50M  free = 371.50M  (encrypted)\n")
        let swap = collect(r1)
        precondition(swap.count == 1 && swap[0].title == "交换空间快满了", "swap finding")
        precondition(swap[0].detail.hasPrefix("已用 ") && swap[0].detail.contains(" / 共 "), swap[0].detail)
        precondition(swap[0].advice == "关闭不用的应用或重启可缓解；磁盘越满，交换越容易出问题")
        precondition(swap[0].command == nil)

        // 恰好 80% 报
        r1.responses[swapKey] = ok("total = 1000.00M  used = 800.00M  free = 200.00M")
        precondition(collect(r1).count == 1, "80% boundary reports")
        // 总量 0：不报
        r1.responses[swapKey] = ok("total = 0.00M  used = 0.00M  free = 0.00M")
        precondition(collect(r1).isEmpty, "no swap configured")
        // 失败 / 超时：省略
        r1.responses[swapKey] = failed(); precondition(collect(r1).isEmpty)
        r1.responses[swapKey] = timedOut(); precondition(collect(r1).isEmpty)
        r1.responses[swapKey] = ok("unparseable"); precondition(collect(r1).isEmpty)

        // Docker：失效的非当前 context
        let r2 = FakeRunner()
        r2.responses[swapKey] = failed(); r2.responses[tmKey] = failed()
        r2.responses[ctxKey] = ok([
            contextLine("default", "unix://\(missingSocket)"),                  // default 不能删
            contextLine("desktop-linux", "unix://\(missingSocket)"),            // 失效
            contextLine("orbstack", "unix://\(missingSocket)", current: true),  // 当前：不报
            contextLine("alive", "unix://\(liveSocket)"),                       // socket 在：不报
            contextLine("remote", "ssh://user@example.invalid"),                // 非 unix：不碰
            contextLine("tcp", "tcp://10.0.0.5:2376"),
            contextLine("bad name", "unix://\(missingSocket)"),                 // 名字不合规：不拼命令
            contextLine("-rf", "unix://\(missingSocket)"),
        ].joined(separator: "\n") + "\n")
        let dockerFindings = collect(r2)
        precondition(dockerFindings.count == 1, "docker findings: \(dockerFindings)")
        precondition(dockerFindings[0].title == "Docker 上下文 desktop-linux 已失效")
        precondition(dockerFindings[0].command == "docker context rm desktop-linux")
        precondition(r2.calls.contains(ctxKey))
        // 旧版字段名 Endpoint 也认
        r2.responses[ctxKey] = ok("{\"Current\":false,\"Endpoint\":\"unix://\(missingSocket)\",\"Name\":\"old\"}\n")
        precondition(collect(r2).first?.command == "docker context rm old")
        // 失败：省略
        r2.responses[ctxKey] = failed(); precondition(collect(r2).isEmpty)
        r2.responses[ctxKey] = timedOut(); precondition(collect(r2).isEmpty)
        r2.responses[ctxKey] = ok("not json\n"); precondition(collect(r2).isEmpty)
        // 没装 docker：不调用
        let noDocker = ToolLocator(searchDirectories: [], isExecutable: { _ in false }, dockerHost: nil)
        let r2b = FakeRunner()
        precondition(HealthReport.collect(runner: r2b, tools: noDocker, launchAgents: []).isEmpty)

        // 快照
        let r3 = FakeRunner()
        r3.responses[swapKey] = failed(); r3.responses[ctxKey] = failed()
        r3.responses[tmKey] = ok("Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-28-101010.local\ncom.apple.TimeMachine.2026-10-29-111111.local\n")
        let snaps = collect(r3)
        precondition(snaps.count == 1 && snaps[0].detail.contains("2"), "snapshots: \(snaps)")
        precondition(snaps[0].advice == "快照会占用空间，系统会在空间紧张时自动清理")
        precondition(snaps[0].command == nil)
        // 无快照：只有表头
        r3.responses[tmKey] = ok("Snapshots for disk /:\n")
        precondition(collect(r3).isEmpty)
        // tmutil 失败 / 超时：无快照项
        r3.responses[tmKey] = failed(); precondition(collect(r3).isEmpty)
        r3.responses[tmKey] = timedOut(); precondition(collect(r3).isEmpty)

        // 失败启动项：每条一条 finding，没有命令
        let agent = CleanupCandidate(source: "agenthealth", key: "com.example.flaky", title: "后台服务反复失败 · com.example.flaky",
            size: 0, evidence: "已被拉起 40 次，上次退出码 1 · 启动的程序：/opt/example/bin/flaky", risk: .amber, action: nil)
        let agent2 = CleanupCandidate(source: "agenthealth", key: "com.example.other", title: "后台服务反复失败 · com.example.other",
            size: 0, evidence: "已被拉起 25 次，上次退出码 2 · 启动的程序：/opt/example/bin/other", risk: .amber, action: nil)
        let r4 = FakeRunner()
        r4.responses[swapKey] = failed(); r4.responses[ctxKey] = failed(); r4.responses[tmKey] = failed()
        let agents = collect(r4, agents: [agent, agent2])
        precondition(agents.count == 2 && agents.allSatisfy { $0.command == nil }, "agent findings")
        precondition(agents[0].title == agent.entry.title && agents[0].detail == agent.entry.evidence)
        precondition(Set(agents.map(\.id)).count == 2)

        // 所有命令都只读：不出现 rm / delete 之类的调用
        let all = FakeRunner()
        all.responses[swapKey] = failed(); all.responses[ctxKey] = ok(contextLine("x", "unix://\(missingSocket)")); all.responses[tmKey] = failed()
        _ = collect(all)
        precondition(all.calls.allSatisfy { !$0.contains(" rm") && !$0.contains("delete") && !$0.contains("thinlocalsnapshots") }, "\(all.calls)")

        // Codable 往返
        let f = HealthFinding(id: "a", title: "t", detail: "d", advice: "v", command: nil)
        let back = try JSONDecoder().decode(HealthFinding.self, from: JSONEncoder().encode(f))
        precondition(back == f)

        print("HealthReportTests passed")
    }
}
