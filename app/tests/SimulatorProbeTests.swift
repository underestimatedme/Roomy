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

@main
struct SimulatorProbeTests {
    static func main() throws {
        let devicesJSON = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/cleanup/simctl-devices.json"))
        let runtimesJSON = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/cleanup/simctl-runtimes.json"))
        let devices = SimulatorProbe.parseDevices(devicesJSON)!
        let runtimes = SimulatorProbe.parseRuntimes(runtimesJSON)!
        precondition(devices.count == 3 && runtimes.count == 3)
        precondition(SimulatorProbe.parseDevices(Data("nope".utf8)) == nil)
        precondition(SimulatorProbe.runtimeLabel("com.apple.CoreSimulator.SimRuntime.iOS-17-2") == "iOS 17.2")

        let now = ISO8601DateFormatter().date(from: "2026-10-02T12:00:00Z")!
        let list = SimulatorProbe.candidates(devices: devices, runtimes: runtimes, deviceFS: [], now: now)
        let titles = list.map(\.entry.title)
        precondition(!titles.contains { $0.contains("iPhone 17 Pro") }, "booted device must not be listed")
        precondition(titles.contains("iPhone 15 Pro 模拟器 · iOS 26.5"), "\(titles)")
        let old = list.first { $0.entry.title.hasPrefix("iPhone 15 Pro") }!
        precondition(old.entry.evidence == "7 个月没启动过", old.entry.evidence)
        precondition(old.entry.size == 4100000000 && !old.entry.defaultChecked && !old.entry.reversible)
        if case .simctlDeleteDevice(let udid) = old.action { precondition(udid == "11111111-2222-3333-4444-555555555555") }
        else { preconditionFailure("wrong action") }
        precondition(list.first { $0.entry.title.hasPrefix("iPad Air") }!.entry.evidence == "从没启动过")
        // iOS 26.5 在用、16.4 不可删 → 只有 17.2 运行时出现
        let runtimeTitles = titles.filter { $0.hasSuffix("模拟器运行时") }
        precondition(runtimeTitles == ["iOS 17.2 模拟器运行时"], "\(runtimeTitles)")

        // 唯一的运行时且仍有设备在用：进清单但锁定；还有别的运行时可用时照旧不列
        let soleRuntime = SimRuntime(id: "1184C577-1086-4DCC-BE63-E113336914AB",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", size: 8_000_000_000, deletable: true)
        let soleDevice = SimDevice(udid: "11111111-2222-3333-4444-555555555555", name: "iPhone 15 Pro",
            runtime: soleRuntime.runtimeIdentifier, state: "Shutdown", lastUsedAt: nil, dataSize: 100)
        let sole = SimulatorProbe.candidates(devices: [soleDevice], runtimes: [soleRuntime], deviceFS: [], now: now)
            .first { $0.entry.source == "runtime" }
        precondition(sole?.entry.tier == .locked && sole?.entry.lockReason == "唯一的模拟器运行时，仍有设备在用"
            && sole?.action == nil && sole?.entry.selectable == false, "\(String(describing: sole?.entry.lockReason))")
        let notSole = SimulatorProbe.candidates(devices: [soleDevice], runtimes: runtimes, deviceFS: [], now: now)
        precondition(!notSole.contains { $0.entry.title == "iOS 26.5 模拟器运行时" }, "a used runtime is not listed when others exist")

        // DeviceFS：UDID 仍存在的不列，不存在的作为残留列出且默认勾选
        let fsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-devicefs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fsRoot) }
        let live = fsRoot.appendingPathComponent("device-A86E8B12-7CF0-4A69-B453-6DC989371771.localized")
        let orphan = fsRoot.appendingPathComponent("device-99999999-8888-7777-6666-555555555555.localized")
        for d in [live, orphan] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let runner = FakeRunner()
        let tools = ToolLocator(searchDirectories: [], isExecutable: { _ in true })
        runner.responses["/usr/bin/xcrun simctl list -j devices"] = ok(String(decoding: devicesJSON, as: UTF8.self))
        runner.responses["/usr/bin/xcrun simctl runtime list -j"] = ok(String(decoding: runtimesJSON, as: UTF8.self))
        let probed = SimulatorProbe.probe(runner: runner, tools: tools, deviceFSRoot: fsRoot.path, now: now,
            sizeOf: { _ in 24_000_000_000 })
        // DeviceFS 是 CoreDevice 的 FSKit 虚拟挂载，不是磁盘上的残留文件：任何情况下都不进清单
        precondition(!probed.contains { $0.entry.source == "devicefs" }, "\(probed.map(\.entry.title))")
        precondition(!probed.contains { if case .trash = $0.action { return true }; return false })

        // Review Focus 2：simctl 失败时绝不能把 DeviceFS 全当成孤儿
        let broken = FakeRunner()
        let none = SimulatorProbe.probe(runner: broken, tools: tools, deviceFSRoot: fsRoot.path, now: now,
            sizeOf: { _ in 1 })
        precondition(none.isEmpty, "simctl failure must yield no candidates, got \(none.map(\.entry.title))")
        // xcrun 不存在 → 什么也不做
        let noTools = ToolLocator(searchDirectories: [], isExecutable: { _ in false })
        precondition(SimulatorProbe.probe(runner: runner, tools: noTools, deviceFSRoot: fsRoot.path, now: now,
            sizeOf: { _ in 1 }).isEmpty)

        // 复核：Booted → 拒绝；不存在 → 拒绝；Shutdown → 放行
        precondition(SimulatorProbe.deviceBlocker(udid: "A86E8B12-7CF0-4A69-B453-6DC989371771", runner: runner, tools: tools)
            == "这台模拟器正在运行，先关掉它")
        precondition(SimulatorProbe.deviceBlocker(udid: "00000000-0000-0000-0000-000000000000", runner: runner, tools: tools)
            == "这台模拟器已经不存在了")
        precondition(SimulatorProbe.deviceBlocker(udid: "11111111-2222-3333-4444-555555555555", runner: runner, tools: tools) == nil)
        precondition(SimulatorProbe.runtimeBlocker(id: "1184C577-1086-4DCC-BE63-E113336914AB", runner: runner, tools: tools)
            == "还有模拟器在用这个运行时")
        precondition(SimulatorProbe.runtimeBlocker(id: "22222222-3333-4444-5555-666666666666", runner: runner, tools: tools) == nil)
        precondition(SimulatorProbe.deviceBlocker(udid: "11111111-2222-3333-4444-555555555555", runner: broken, tools: tools)
            == "无法读取模拟器列表")
        print("SimulatorProbeTests passed")
    }
}
