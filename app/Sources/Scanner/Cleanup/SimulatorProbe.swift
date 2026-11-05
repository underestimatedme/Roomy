// SPDX-License-Identifier: GPL-3.0-only
// 模拟器归 simctl 管：名称、上次使用时间、大小都问它，删也让它删。
// 注意：~/Library/Developer/CoreDevice/DeviceFS 是 CoreDevice 的 FSKit 虚拟挂载（mount 里是 devicefs），
// 里面看到的"大小"是设备数据的视图，不占 Mac 磁盘，绝不能当残留去删。

import Foundation

struct SimDevice {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let lastUsedAt: Date?
    let dataSize: UInt64
}

struct SimRuntime {
    let id: String
    let runtimeIdentifier: String
    let size: UInt64
    let deletable: Bool
}

enum SimulatorProbe {
    static let probeTimeout: TimeInterval = 10

    static func parseDevices(_ data: Data) -> [SimDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["devices"] as? [String: [[String: Any]]] else { return nil }
        let iso = ISO8601DateFormatter()
        return groups.flatMap { runtime, list in
            list.compactMap { d -> SimDevice? in
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { return nil }
                return SimDevice(udid: udid, name: name, runtime: runtime, state: d["state"] as? String ?? "",
                    lastUsedAt: (d["lastUsedAt"] as? String).flatMap(iso.date(from:)),
                    dataSize: (d["dataPathSize"] as? NSNumber)?.uint64Value ?? 0)
            }
        }
    }

    static func parseRuntimes(_ data: Data) -> [SimRuntime]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        return root.compactMap { id, r in
            guard let rid = r["runtimeIdentifier"] as? String else { return nil }
            return SimRuntime(id: r["identifier"] as? String ?? id, runtimeIdentifier: rid,
                size: (r["sizeBytes"] as? NSNumber)?.uint64Value ?? 0, deletable: r["deletable"] as? Bool ?? false)
        }
    }

    /// com.apple.CoreSimulator.SimRuntime.iOS-17-2 → iOS 17.2
    static func runtimeLabel(_ identifier: String) -> String {
        guard let tail = identifier.split(separator: ".").last else { return identifier }
        let parts = tail.split(separator: "-")
        guard parts.count >= 2 else { return String(tail) }
        return parts[0] + " " + parts.dropFirst().joined(separator: ".")
    }

    static func candidates(devices: [SimDevice], runtimes: [SimRuntime],
                           deviceFS: [(path: String, size: UInt64)], now: Date) -> [CleanupCandidate] {
        var out: [CleanupCandidate] = []
        for d in devices where d.state != "Booted" && CleanupArgument.isUUID(d.udid) {
            let evidence: String
            if let last = d.lastUsedAt {
                let days = Int(now.timeIntervalSince(last) / 86_400)
                evidence = Humanize.span(days: days).map { "\($0)没启动过" } ?? "今天还用过"
            } else {
                evidence = "从没启动过"
            }
            out.append(CleanupCandidate(source: "simulator", key: d.udid,
                title: "\(d.name) 模拟器 · \(runtimeLabel(d.runtime))", size: d.dataSize,
                evidence: evidence, risk: .amber, action: .simctlDeleteDevice(udid: d.udid)))
        }
        let used = Set(devices.map(\.runtime))
        for r in runtimes where r.deletable && CleanupArgument.isUUID(r.id) {
            if used.contains(r.runtimeIdentifier) {
                // 还有设备在用：只有它是唯一的运行时时才列出来并锁定；别的运行时可用时照旧不列
                if runtimes.count == 1 {
                    out.append(CleanupCandidate(source: "runtime", key: r.id,
                        title: "\(runtimeLabel(r.runtimeIdentifier)) 模拟器运行时", size: r.size,
                        evidence: "没有别的运行时可用", risk: .amber, action: nil)
                        .locked("唯一的模拟器运行时，仍有设备在用"))
                }
                continue
            }
            out.append(CleanupCandidate(source: "runtime", key: r.id,
                title: "\(runtimeLabel(r.runtimeIdentifier)) 模拟器运行时", size: r.size,
                evidence: "没有任何模拟器在用", risk: .amber, action: .simctlDeleteRuntime(id: r.id)))
        }
        return out
    }

    static func probe(runner: CommandRunning, tools: ToolLocator,
                      deviceFSRoot: String = HOME + "/Library/Developer/CoreDevice/DeviceFS",
                      now: Date = Date(), sizeOf: (String) -> UInt64? = { BulkWalker().size(of: $0) }) -> [CleanupCandidate] {
        guard let devices = listDevices(runner: runner, tools: tools) else { return [] }
        let runtimes = tools.path(for: .xcrun).flatMap { xcrun -> [SimRuntime]? in
            let r = runner.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: probeTimeout)
            return r.ok ? parseRuntimes(Data(r.stdout.utf8)) : nil
        } ?? []
        return candidates(devices: devices, runtimes: runtimes, deviceFS: [], now: now)
    }

    static func deviceBlocker(udid: String, runner: CommandRunning, tools: ToolLocator) -> String? {
        guard let devices = listDevices(runner: runner, tools: tools) else { return "无法读取模拟器列表" }
        guard let device = devices.first(where: { $0.udid == udid }) else { return "这台模拟器已经不存在了" }
        return device.state == "Booted" ? "这台模拟器正在运行，先关掉它" : nil
    }

    static func runtimeBlocker(id: String, runner: CommandRunning, tools: ToolLocator) -> String? {
        guard let devices = listDevices(runner: runner, tools: tools),
              let xcrun = tools.path(for: .xcrun) else { return "无法读取模拟器列表" }
        let r = runner.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: probeTimeout)
        guard r.ok, let runtimes = parseRuntimes(Data(r.stdout.utf8)) else { return "无法读取运行时列表" }
        guard let runtime = runtimes.first(where: { $0.id == id }) else { return "这个运行时已经不存在了" }
        return devices.contains { $0.runtime == runtime.runtimeIdentifier } ? "还有模拟器在用这个运行时" : nil
    }

    private static func listDevices(runner: CommandRunning, tools: ToolLocator) -> [SimDevice]? {
        guard let xcrun = tools.path(for: .xcrun) else { return nil }
        let r = runner.run(xcrun, ["simctl", "list", "-j", "devices"], timeout: probeTimeout)
        return r.ok ? parseDevices(Data(r.stdout.utf8)) : nil
    }
}
