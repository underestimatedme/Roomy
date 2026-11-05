// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation

/// 只应答 ps：进程列表由测试给出
private final class ProcessList: CommandRunning, @unchecked Sendable {
    var commands: [String] = []
    var rawOutput: String? = nil
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        CommandResult(status: 0, stdout: rawOutput ?? commands.joined(separator: "\n"), stderr: "", timedOut: false)
    }
}

@main
struct LocalShareProbeTests {
    static func main() throws {
        let fm = FileManager.default
        let root = "/private/tmp/roomy-local-share-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: root) }
        func file(_ path: String, _ text: String = String(repeating: "x", count: 3000)) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let home = root + "/home", share = home + "/.local/share", code = root + "/code"
        let ps = ProcessList()
        let tools = ToolLocator(searchDirectories: [], isExecutable: { _ in true })

        // ── Android SDK 副本：没有任何引用进 A；被项目、shell、后台服务或模拟器引用进 C，并写明是谁
        // 证据复核不能依赖运行测试的机器上恰好有没有 ANDROID_HOME
        let savedAndroidHome = getenv("ANDROID_HOME").map { String(cString: $0) }
        unsetenv("ANDROID_HOME")
        defer { if let savedAndroidHome { setenv("ANDROID_HOME", savedAndroidHome, 1) } }
        let sdk = share + "/qa/android-sdk"
        for part in ["platform-tools", "build-tools", "platforms"] { try file(sdk + "/" + part + "/x.bin") }
        try fm.createDirectory(atPath: code, withIntermediateDirectories: true)
        try file(code + "/app/android/local.properties", "sdk.dir=/Users/someone/Library/Android/sdk\n")
        func copies() -> [CleanupCandidate] {
            SdkCopyProbe.candidates(searchRoots: [share], codeRoots: [code], home: home, androidHome: nil,
                                    standard: home + "/Library/Android/sdk")
        }
        let unused = copies()
        precondition(unused.count == 1 && unused[0].entry.path == sdk, "\(unused.compactMap(\.entry.path))")
        precondition(unused[0].entry.tier == .obsolete && unused[0].entry.defaultChecked && unused[0].entry.reversible, "\(unused[0].entry)")
        precondition(unused[0].entry.tierReason?.contains("sdkmanager") == true, unused[0].entry.tierReason ?? "nil")
        precondition(unused[0].entry.tierReason?.contains("未检查其他位置") == true,
            "a bounded scan must not claim to have checked everywhere: \(unused[0].entry.tierReason ?? "nil")")

        try file(code + "/app/android/local.properties", "sdk.dir=" + sdk.replacingOccurrences(of: ":", with: "\\:") + "\n")
        let byProject = copies()[0].entry
        precondition(byProject.tier == .review && !byProject.defaultChecked, "\(byProject)")
        precondition(byProject.tierReason?.contains(code + "/app/android/local.properties") == true, byProject.tierReason ?? "nil")
        try fm.removeItem(atPath: code + "/app/android/local.properties")

        try file(home + "/.zshrc", "export ANDROID_HOME=~/.local/share/qa/android-sdk\nexport PATH=$ANDROID_HOME/platform-tools:$PATH\n")
        precondition(copies()[0].entry.tier == .review && copies()[0].entry.tierReason?.contains("~/.zshrc") == true,
            copies()[0].entry.tierReason ?? "nil")
        try file(home + "/.zshrc", "export OLD=$HOME/.local/share/qa/android-sdk-old\n")
        precondition(copies()[0].entry.tier == .obsolete, "a sibling with a longer name is a different directory")
        try fm.removeItem(atPath: home + "/.zshrc")

        let agents = home + "/Library/LaunchAgents"
        let plist: [String: Any] = ["Label": "com.example.ci", "ProgramArguments": ["/bin/sh", "-c", "run"],
                                    "EnvironmentVariables": ["ANDROID_SDK_ROOT": sdk + "/"]]
        try fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: URL(fileURLWithPath: agents + "/com.example.ci.plist"))
        precondition(copies()[0].entry.tier == .review && copies()[0].entry.tierReason?.contains("com.example.ci") == true,
            copies()[0].entry.tierReason ?? "nil")
        try fm.removeItem(atPath: agents + "/com.example.ci.plist")

        try file(home + "/.android/avd/Pixel.avd/hardware-qemu.ini", "kernel.path = \(sdk)/system-images/android-34/kernel-ranchu\n")
        precondition(copies()[0].entry.tier == .review && copies()[0].entry.tierReason?.contains("Pixel") == true,
            copies()[0].entry.tierReason ?? "nil")
        try fm.removeItem(atPath: home + "/.android")

        // 读取失败/过大/深度截断都不是“没有引用”
        try fm.createDirectory(atPath: code + "/app/android/local.properties", withIntermediateDirectories: true)
        let unreadableProperties = copies()[0].entry
        precondition(unreadableProperties.tier == .review && !unreadableProperties.defaultChecked, "\(unreadableProperties)")
        precondition(unreadableProperties.tierReason?.contains("没能完整检查") == true, unreadableProperties.tierReason ?? "nil")
        try fm.removeItem(atPath: code + "/app/android")

        try file(code + "/app/android/local.properties",
                 "sdk.dir=" + sdk + "\n" + String(repeating: "#", count: 70_000))
        let hugeProperties = copies()[0].entry
        precondition(hugeProperties.tier == .review && !hugeProperties.defaultChecked, "\(hugeProperties)")
        precondition(hugeProperties.tierReason?.contains("没能完整检查") == true, hugeProperties.tierReason ?? "nil")
        try fm.removeItem(atPath: code + "/app/android")

        let deep = code + "/a/b/c/d/e/f/g"
        try file(deep + "/local.properties", "sdk.dir=" + sdk + "\n")
        let deepScan = copies()[0].entry
        precondition(deepScan.tier == .review && !deepScan.defaultChecked, "\(deepScan)")
        precondition(deepScan.tierReason?.contains("层级太深") == true, deepScan.tierReason ?? "nil")
        try fm.removeItem(atPath: code + "/a")

        try fm.createDirectory(atPath: home + "/.zshrc", withIntermediateDirectories: true)
        let shellUnknown = copies()[0].entry
        precondition(shellUnknown.tier == .review && shellUnknown.tierReason?.contains("无法读取") == true,
            shellUnknown.tierReason ?? "nil")
        try fm.removeItem(atPath: home + "/.zshrc")

        try fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: agents + "/com.example.broken.plist"))
        let agentUnknown = copies()[0].entry
        precondition(agentUnknown.tier == .review && agentUnknown.tierReason?.contains("无法读取") == true,
            agentUnknown.tierReason ?? "nil")
        try fm.removeItem(atPath: agents)

        try fm.createDirectory(atPath: home + "/.android/avd/Broken.avd/config.ini", withIntermediateDirectories: true)
        let avdUnknown = copies()[0].entry
        precondition(avdUnknown.tier == .review && avdUnknown.tierReason?.contains("无法读取") == true,
            avdUnknown.tierReason ?? "nil")
        try fm.removeItem(atPath: home + "/.android")

        precondition(!SdkCopyProbe.sdkDirectories(in: [code, share], directoryLimit: 1, home: home).complete,
            "a cut-off walk is incomplete")
        precondition(SdkCopyProbe.sdkDirectories(in: [code], home: home).complete)

        // 模拟器、adb 等正在从这份 SDK 运行：清单里锁定；读不到进程列表降为 C；执行前再查一次
        let emulator = "\(sdk)/emulator/qemu/darwin-aarch64/qemu-system-aarch64 -avd Pixel"
        let sdkList = CleanupListBuilder.build(items: [], probes: unused, running: RunningOwners(commands: [emulator]))
        precondition(sdkList.entries[0].tier == .locked, "\(sdkList.entries[0])")
        precondition(RunningOwners.markUnverified(CleanupListBuilder.build(items: [], probes: unused)).entries[0].tier == .review)
        guard case .trash(let sdkItem)? = unused[0].action else { preconditionFailure("SDK copy is a trash action") }
        ps.commands = [emulator]
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) != nil, "in use at execution")
        ps.commands = ["/sbin/launchd"]
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) == nil)
        // 扫描之后项目才开始引用这份 SDK：执行前必须重新查引用，不能按扫描时的"没人用"放行
        try file(code + "/app/android/local.properties", "sdk.dir=" + sdk + "\n")
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) != nil,
            "a project added after the scan must block execution")
        try fm.removeItem(atPath: code + "/app/android/local.properties")
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) == nil)

        // 初始已引用 C：扫描时未默认勾选，用户逐项确认后，证据不变可以执行
        try file(code + "/app/android/local.properties", "sdk.dir=" + sdk + "\n")
        let referencedC = copies()[0]
        precondition(referencedC.entry.tier == .review && !referencedC.entry.defaultChecked, "\(referencedC.entry)")
        guard case .trash(let referencedItem)? = referencedC.action else { preconditionFailure("referenced SDK is a trash action") }
        precondition(OwnerCachePolicy.executionBlocker(referencedItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) == nil,
            "unchanged references that the user explicitly selected must remain executable")
        // C 之后新增额外引用：必须拒绝
        try file(home + "/.zshrc", "export ANDROID_HOME=" + sdk + "\n")
        precondition(OwnerCachePolicy.executionBlocker(referencedItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) != nil,
            "an additional reference after the scan must block execution")
        try fm.removeItem(atPath: home + "/.zshrc")
        precondition(OwnerCachePolicy.executionBlocker(referencedItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) == nil)
        // C 之后未知状态变化：同样拒绝
        try fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: agents + "/com.example.broken.plist"))
        precondition(OwnerCachePolicy.executionBlocker(referencedItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) != nil,
            "a new unreadable source after the scan must block execution")
        try fm.removeItem(atPath: agents)
        // 扫描时就已经无法读取、用户已看到并确认：同一未知证据可以执行；文件变得可读后状态变化，拒绝
        try fm.createDirectory(atPath: agents, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: agents + "/com.example.broken.plist"))
        let unknownC = copies()[0]
        guard case .trash(let unknownItem)? = unknownC.action else { preconditionFailure("unknown SDK is a trash action") }
        precondition(OwnerCachePolicy.executionBlocker(unknownItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) == nil,
            "the same explicitly-confirmed unknown evidence must remain executable")
        try fm.removeItem(atPath: agents + "/com.example.broken.plist")
        try file(agents + "/com.example.ci.plist", "not a plist either")
        precondition(OwnerCachePolicy.executionBlocker(unknownItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil) != nil,
            "a change in unknown state must invalidate the preview")
        try fm.removeItem(atPath: agents)
        try fm.removeItem(atPath: code + "/app/android")

        // ANDROID_HOME 在扫描后变化：必须拒绝
        ps.commands = ["/sbin/launchd"]
        setenv("ANDROID_HOME", sdk, 1)
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code], home: home) != nil, "ANDROID_HOME switch after the scan must block execution")
        unsetenv("ANDROID_HOME")
        // 扫描范围/标准位置变化：同样拒绝
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code + "-gone"], home: home, androidHome: nil) != nil, "scope change must block execution")
        precondition(OwnerCachePolicy.executionBlocker(sdkItem, runner: ps, tools: tools,
            codeRoots: [code], home: home + "-other", androidHome: nil) != nil, "standard location change must block execution")
        // 旧证据缺失（上一版只有角色+路径，没有引用指纹）：安全重扫，不能直接放行
        var legacyItem = sdkItem
        legacyItem.cleanupEvidence = CleanupEvidenceSnapshot(version: 1,
            fingerprint: "sdk-copy:" + sdk, kind: OwnerCachePolicy.evidenceKind)
        precondition(OwnerCachePolicy.executionBlocker(legacyItem, runner: ps, tools: tools,
            codeRoots: [code], home: home, androidHome: nil)?.contains("引用检查证据") == true,
            "old evidence without the reference fingerprint must be rescanned")

        // 空白行 ps 输出也不是"没有进程在运行"
        ps.rawOutput = "\n   \n"
        precondition(RunningOwners.capture(runner: ps, tools: tools) == nil, "whitespace-only ps output is untrusted")
        ps.rawOutput = nil

        // 实际 CleanupRunner 调用链：与 helper 使用同一套 scope 和证据
        var moved: [String] = []
        var env = CleanupEnvironment()
        env.runner = ps
        env.tools = tools
        env.roots = [home]
        env.home = home
        env.codeRoots = [code]
        env.androidHome = nil
        env.selectedCodeRoots = []
        env.trash = { moved.append($0); return nil }
        env.diskFree = { 0 }
        let runnable = copies()[0]
        precondition(runnable.entry.tier == .obsolete)
        let aRun = CleanupRunner.run(ids: [runnable.entry.id], list: CleanupList(candidates: [runnable]), env: env) { _ in }
        precondition(aRun.outcomes.first?.ok == true && moved == [sdk], "\(aRun.outcomes) \(moved)")

        try file(code + "/app/android/local.properties", "sdk.dir=" + sdk + "\n")
        let runnerC = copies()[0]
        precondition(runnerC.entry.tier == .review && !runnerC.entry.defaultChecked)
        moved.removeAll()
        let cRun = CleanupRunner.run(ids: [runnerC.entry.id], list: CleanupList(candidates: [runnerC]), env: env) { _ in }
        precondition(cRun.outcomes.first?.ok == true && moved == [sdk],
            "explicitly selected C must execute through CleanupRunner: \(cRun.outcomes)")
        try file(home + "/.zshrc", "export ANDROID_HOME=" + sdk + "\n")
        moved.removeAll()
        let changedRun = CleanupRunner.run(ids: [runnerC.entry.id], list: CleanupList(candidates: [runnerC]), env: env) { _ in }
        precondition(changedRun.outcomes.first?.ok == false && moved.isEmpty,
            "a new reference after the scan must stop CleanupRunner: \(changedRun.outcomes)")
        precondition(changedRun.outcomes.first?.message.contains("新的引用") == true, changedRun.outcomes.first?.message ?? "nil")
        try fm.removeItem(atPath: home + "/.zshrc")

        setenv("ANDROID_HOME", sdk, 1)
        var switched = CleanupEnvironment()
        switched.runner = ps
        switched.tools = tools
        switched.roots = [home]
        switched.home = home
        switched.codeRoots = [code]
        switched.selectedCodeRoots = []
        switched.trash = { moved.append($0); return nil }
        switched.diskFree = { 0 }
        precondition(switched.androidHome == sdk, "CleanupEnvironment must read the live ANDROID_HOME")
        moved.removeAll()
        let switchedRun = CleanupRunner.run(ids: [runnerC.entry.id], list: CleanupList(candidates: [runnerC]), env: switched) { _ in }
        precondition(switchedRun.outcomes.first?.ok == false && moved.isEmpty,
            "CleanupRunner must reject an ANDROID_HOME switch: \(switchedRun.outcomes)")
        unsetenv("ANDROID_HOME")
        try fm.removeItem(atPath: code + "/app/android")

        // ── 自定义位置的 DerivedData：布局齐全才算；最近构建过进 B，30 天没构建进 A；Xcode 在运行就锁定
        let derived = share + "/qa/ios-build"
        try file(derived + "/info.plist", "<plist/>")
        try file(derived + "/ModuleCache.noindex/Module.pcm")
        try file(derived + "/Build/Products/Debug-iphonesimulator/App.o")
        try file(share + "/qa/evidence/info.plist", "<plist/>")
        let recent = DerivedDataCopyProbe.candidates(searchRoots: [share])
        precondition(recent.count == 1 && recent[0].entry.path == derived, "\(recent.compactMap(\.entry.path))")
        precondition(recent[0].entry.tier == .rebuildable && recent[0].entry.reversible, "\(recent[0].entry)")
        let quiet = DerivedDataCopyProbe.candidates(searchRoots: [share], now: Date().addingTimeInterval(40 * 86_400))
        precondition(quiet[0].entry.tier == .obsolete && quiet[0].entry.defaultChecked, "\(quiet[0].entry)")
        let derivedList = CleanupListBuilder.build(items: [], probes: quiet,
            running: RunningOwners(commands: ["/Applications/Xcode.app/Contents/MacOS/Xcode"]))
        precondition(derivedList.entries[0].tier == .locked && derivedList.entries[0].category == "xcode", "\(derivedList.entries[0])")
        precondition(copies().compactMap(\.entry.path) == [sdk], "the DerivedData next to the SDK is not an SDK")

        // ── 旧版本发布目录：后台服务正在用的版本和它之前最近的一个保留，更早的进 A；之后才装的版本不动
        let releases = share + "/agent/releases"
        for version in ["0.1", "0.2", "0.3", "0.4"] {
            try file(releases + "/" + version + "/bin/agent", "#!/bin/sh\n")
            usleep(20_000)
        }
        try file(releases + "/0.5-staged/bin/agent", "#!/bin/sh\n")
        try fm.createSymbolicLink(atPath: releases + "/current", withDestinationPath: releases + "/0.4")
        func old(_ program: String) -> [CleanupCandidate] {
            ReleaseHistoryProbe.candidates(agents: [(label: "com.example.agent", path: program)])
        }
        let stale = old(releases + "/0.4/bin/agent")
        precondition(stale.compactMap(\.entry.path).sorted() == [releases + "/0.1", releases + "/0.2"], "\(stale.compactMap(\.entry.path))")
        precondition(stale.allSatisfy { $0.entry.tier == .obsolete && $0.entry.defaultChecked && $0.entry.reversible })
        precondition(stale.contains { $0.entry.title == "旧版本发布目录 · agent 0.1" }, "\(stale.map(\.entry.title))")
        let reason = stale[0].entry.tierReason ?? ""
        precondition(reason.contains("com.example.agent") && reason.contains("0.4") && reason.contains("0.3"), reason)
        precondition(old(releases + "/current/bin/agent").compactMap(\.entry.path).sorted() == [releases + "/0.1", releases + "/0.2"],
            "a current symlink resolves to the release it points at, and is never listed itself")
        precondition(old(releases + "/9.9/bin/agent").isEmpty, "an agent pointing at a missing release proves nothing")
        precondition(old(share + "/agent/bin/agent").isEmpty, "no releases directory, nothing to list")
        precondition(ReleaseHistoryProbe.candidates(agents: [(label: "a", path: releases + "/0.4/bin/agent"),
                                                             (label: "b", path: releases + "/0.3/bin/agent")])
            .compactMap(\.entry.path) == [releases + "/0.1"], "every release a service runs is kept, and the newest older one for rollback")
        precondition(ReleaseHistoryProbe.candidates(agents: [(label: "a", path: releases + "/0.4/bin/agent"),
                                                             (label: "b", path: releases + "/0.2/bin/agent")]).isEmpty,
            "0.3 rolls back 0.4 and 0.1 rolls back 0.2")

        // 复制出来的版本会带着同样的创建时间：同一时刻创建的按版本名的自然顺序排（a07 在 a08 之前）
        let tied = share + "/tied/releases"
        for version in ["r1", "r1-a07", "r1-a08"] { try file(tied + "/" + version + "/bin/agent", "#!/bin/sh\n"); usleep(20_000) }
        let sameMoment = Date().addingTimeInterval(60)
        for version in ["r1-a08", "r1-a07"] { try fm.setAttributes([.creationDate: sameMoment], ofItemAtPath: tied + "/" + version) }
        let tiedStale = ReleaseHistoryProbe.candidates(agents: [(label: "t", path: tied + "/r1-a08/bin/agent")])
        precondition(tiedStale.compactMap(\.entry.path) == [tied + "/r1"], "\(tiedStale.compactMap(\.entry.path))")
        precondition(tiedStale[0].entry.tierReason?.contains("回滚用的 r1-a07 保留") == true, tiedStale[0].entry.tierReason ?? "nil")

        let releaseList = CleanupListBuilder.build(items: [], probes: stale,
            running: RunningOwners(commands: [releases + "/0.1/bin/agent serve"]))
        let lockedRelease = releaseList.entries.first { $0.path == releases + "/0.1" }
        precondition(lockedRelease?.tier == .locked && lockedRelease?.category == "leftover", "\(String(describing: lockedRelease))")
        precondition(RunningOwners.markUnverified(CleanupListBuilder.build(items: [], probes: stale)).entries.allSatisfy { $0.tier == .review })
        guard let first = stale.first(where: { $0.entry.path == releases + "/0.1" }), case .trash(let releaseItem)? = first.action else {
            preconditionFailure("old release is a trash action")
        }
        guard let second = stale.first(where: { $0.entry.path == releases + "/0.2" }), case .trash(let rollbackItem)? = second.action else {
            preconditionFailure("the next old release is a trash action")
        }
        ps.commands = ["/sbin/launchd"]
        precondition(ReleaseHistoryProbe.executionBlocker(path: releaseItem.path,
            agents: [(label: "com.example.agent", path: releases + "/0.4/bin/agent")]) == nil)
        precondition(ReleaseHistoryProbe.executionBlocker(path: releaseItem.path,
            agents: [(label: "com.example.agent", path: releases + "/0.1/bin/agent")]) != nil, "rolled back to it after the scan")
        // 服务从 0.4 回滚到 0.3 后，0.2 变成 0.3 的回滚副本，执行前必须保留
        precondition(ReleaseHistoryProbe.executionBlocker(path: rollbackItem.path,
            agents: [(label: "com.example.agent", path: releases + "/0.3/bin/agent")]) != nil,
            "after a rollback, 0.2 becomes the rollback copy")
        // 对照：0.1 比 0.3 更早，也不是回滚副本，同一次回滚后仍然可以清
        precondition(ReleaseHistoryProbe.executionBlocker(path: releaseItem.path,
            agents: [(label: "com.example.agent", path: releases + "/0.3/bin/agent")]) == nil,
            "0.1 stays eligible after the same rollback")
        // 服务列表读空：不是"没有服务在用"，执行前拒绝
        precondition(ReleaseHistoryProbe.executionBlocker(path: releaseItem.path, agents: []) != nil,
            "an empty agent list is not proof that nothing uses the release")
        // 服务换到更新的版本：0.1 仍然比所有服务版本旧，且不是回滚副本，可以继续清
        precondition(ReleaseHistoryProbe.executionBlocker(path: releaseItem.path,
            agents: [(label: "com.example.agent", path: releases + "/0.5-staged/bin/agent")]) == nil,
            "moving forward keeps an older stale release eligible")
        // 服务指向不存在的版本：情况不明，拒绝执行
        precondition(ReleaseHistoryProbe.executionBlocker(path: releaseItem.path,
            agents: [(label: "com.example.agent", path: releases + "/9.9/bin/agent")]) != nil,
            "an agent pointing at a missing release blocks execution")
        ps.commands = [releases + "/0.1/bin/agent serve"]
        precondition(OwnerCachePolicy.executionBlocker(releaseItem, runner: ps) != nil, "a process runs it at execution")

        // ── 生产依赖收集：ProgramArguments 的每一项绝对路径都算；坏 plist 时依赖未知，不列也不执行
        let dependencyDir = share + "/LaunchAgents"
        try fm.createDirectory(atPath: dependencyDir, withIntermediateDirectories: true)
        func dependency(_ label: String, _ arguments: [String]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": arguments],
                                                          format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: dependencyDir + "/\(label).plist"))
        }
        try dependency("com.example.direct", [releases + "/0.4/bin/agent"])
        try dependency("com.example.wrapped", ["/bin/sh", releases + "/0.2/bin/agent"])
        let deps = AppLeftoverProbe.agentDependencies(directory: dependencyDir)
        precondition(deps.contains { $0.label == "com.example.wrapped" && $0.path == releases + "/0.2/bin/agent" },
            "all absolute ProgramArguments are dependencies: \(deps)")
        precondition(ReleaseHistoryProbe.candidates(agentsDirectory: dependencyDir).isEmpty,
            "0.2 is in use by a wrapped service, and 0.1/0.3 are rollback copies")
        precondition(ReleaseHistoryProbe.executionBlocker(path: releases + "/0.1", agentsDirectory: dependencyDir) != nil,
            "a release used as a rollback copy must not execute")
        // 正常直接配置仍可清理
        let directDir = share + "/DirectLaunchAgents"
        try fm.createDirectory(atPath: directDir, withIntermediateDirectories: true)
        let directData = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.direct", "ProgramArguments": [releases + "/0.4/bin/agent"]],
            format: .xml, options: 0)
        try directData.write(to: URL(fileURLWithPath: directDir + "/com.example.direct.plist"))
        precondition(ReleaseHistoryProbe.candidates(agentsDirectory: directDir).compactMap(\.entry.path).sorted()
            == [releases + "/0.1", releases + "/0.2"], "a direct complete config still cleans old releases")
        precondition(ReleaseHistoryProbe.executionBlocker(path: releases + "/0.1", agentsDirectory: directDir) == nil)
        // B 的 plist 损坏、A 仍可读：不能只按 A 继续列陈旧候选或执行
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: dependencyDir + "/com.example.wrapped.plist"))
        precondition(!AppLeftoverProbe.agentDependencySnapshot(directory: dependencyDir).isComplete)
        precondition(ReleaseHistoryProbe.candidates(agentsDirectory: dependencyDir).isEmpty,
            "a corrupt service config makes the whole dependency list unknown")
        precondition(ReleaseHistoryProbe.executionBlocker(path: releases + "/0.1", agentsDirectory: dependencyDir) != nil,
            "unknown dependencies must block stale execution")

        // ── 应用包内部的 releases：不列、不执行，删掉会破坏代码签名
        let bundled = share + "/Applications/Foo.app/Contents/Resources/releases"
        for version in ["1.0", "1.1"] { try file(bundled + "/" + version + "/bin/agent", "#!/bin/sh\n"); usleep(20_000) }
        precondition(ReleaseHistoryProbe.candidates(agents: [(label: "com.example.app", path: bundled + "/1.1/bin/agent")]).isEmpty,
            "an app bundle's release history is not a cleanup candidate")
        precondition(ReleaseHistoryProbe.executionBlocker(path: bundled + "/1.0",
            agents: [(label: "com.example.app", path: bundled + "/1.1/bin/agent")]) != nil,
            "an app bundle release is never executed")

        print("LocalShareProbeTests passed")
    }
}
