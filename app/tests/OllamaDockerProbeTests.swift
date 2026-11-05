// SPDX-License-Identifier: GPL-3.0-only
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
private func fixture(_ name: String) throws -> String {
    try String(contentsOfFile: "tests/fixtures/cleanup/\(name)", encoding: .utf8)
}

@main
struct OllamaDockerProbeTests {
    static func main() throws {
        // ── Ollama
        precondition(OllamaProbe.parseSize("39 GB") == 39_000_000_000)
        precondition(OllamaProbe.parseSize("4.7 GB") == 4_700_000_000)
        precondition(OllamaProbe.parseSize("274 MB") == 274_000_000)
        precondition(OllamaProbe.parseSize("huge") == nil)
        precondition(OllamaProbe.parseAgo("3 months ago") == 90)
        precondition(OllamaProbe.parseAgo("2 weeks ago") == 14)
        precondition(OllamaProbe.parseAgo("a year ago") == 365)
        precondition(OllamaProbe.parseAgo("About an hour ago") == 0)
        precondition(OllamaProbe.parseAgo("Less than a second ago") == 0)
        precondition(OllamaProbe.parseAgo("whenever") == nil)

        let models = OllamaProbe.parseList(try fixture("ollama-list.txt"))
        precondition(models.map(\.name) == ["llama3.1:70b", "qwen2.5-coder:7b", "nomic-embed-text:latest"], "\(models)")
        let ollama = OllamaProbe.candidates(models)
        precondition(ollama[0].entry.title == "Ollama · llama3.1:70b" && ollama[0].entry.size == 39_000_000_000)
        precondition(ollama[0].entry.evidence == "3 个月没更新过" && !ollama[0].entry.defaultChecked)
        precondition(ollama[2].entry.evidence == "今天刚更新过")
        precondition(OllamaProbe.candidates([.init(name: "-rf", size: 1, idleDays: 1)]).isEmpty,
            "unsafe model names never become candidates")

        let tools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { _ in true })
        let runner = FakeRunner()
        runner.responses["/fake/ollama list"] = ok(try fixture("ollama-list.txt"))
        precondition(OllamaProbe.probe(runner: runner, tools: tools).count == 3)
        precondition(OllamaProbe.modelBlocker(model: "llama3.1:70b", runner: runner, tools: tools) == nil)
        precondition(OllamaProbe.modelBlocker(model: "gone:1b", runner: runner, tools: tools) == "这个模型已经不在 Ollama 里了")
        let noOllama = ToolLocator(searchDirectories: [], isExecutable: { $0 == "/usr/bin/xcrun" })
        precondition(OllamaProbe.probe(runner: runner, tools: noOllama).isEmpty)

        // ── Docker
        precondition(DockerProbe.parseBytes("1.898GB") == 1_898_000_000)
        precondition(DockerProbe.parseBytes("56.41MB (54%)") == 56_410_000)
        precondition(DockerProbe.parseBytes("512kB") == 512_000)
        precondition(DockerProbe.parseBytes("0B") == 0)
        precondition(DockerProbe.parseBytes("lots") == nil)

        precondition(!CleanupArgument.isDockerReference("-rf"))
        precondition(!CleanupArgument.isDockerReference(""))
        precondition(!CleanupArgument.isDockerReference("a b") && !CleanupArgument.isDockerReference("x;rm"))
        precondition(!CleanupArgument.isDockerReference("<none>:<none>"))
        precondition(!CleanupArgument.isDockerReference(String(repeating: "a", count: 257)))
        precondition(CleanupArgument.isDockerReference(String(repeating: "a", count: 256)))
        precondition(CleanupArgument.isDockerReference("v1") && CleanupArgument.isDockerReference("acme/web:1.0"))
        precondition(CleanupArgument.isDockerReference("registry.local:5000/acme/web@sha256:" + String(repeating: "f", count: 64)))

        let docker = "/fake/docker"
        // DOCKER_HOST 由测试注入，不读进程环境：下面的断言在任何 shell 里都成立
        let dockerTools = ToolLocator(searchDirectories: ["/fake"], isExecutable: { _ in true }, dockerHost: nil)
        let instances = FileManager.default.temporaryDirectory.appendingPathComponent("roomy-buildx-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: instances, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: instances) }
        try "{}".write(toFile: instances + "/live", atomically: true, encoding: .utf8)
        try "".write(toFile: instances + "/.DS_Store", atomically: true, encoding: .utf8)
        let contextKey = "\(docker) context inspect --format {{.Endpoints.docker.Host}}"
        let infoKey = "\(docker) info --format {{.ServerVersion}}"
        func inventoryRunner() throws -> FakeRunner {
            let r = FakeRunner()
            r.responses[contextKey] = ok("unix:///Users/me/.docker/run/docker.sock\n")
            r.responses[infoKey] = ok("29.0.0\n")
            r.responses["\(docker) system df -v --format json"] = ok(try fixture("docker-df-v.json"))
            r.responses["\(docker) ps -a --no-trunc --format {{json .}}"] = ok(try fixture("docker-ps-a.jsonl"))
            r.responses["\(docker) image ls --no-trunc --format {{json .}}"] = ok(try fixture("docker-images.jsonl"))
            return r
        }
        let anonFree = String(repeating: "1", count: 64), anonUsed = String(repeating: "2", count: 64)
        let web1 = "sha256:" + String(repeating: "a", count: 64), dangling = "sha256:" + String(repeating: "c", count: 64)
        let lint = "sha256:" + String(repeating: "e", count: 64)
        let dbContainer = String(repeating: "3", count: 64), oldJob = String(repeating: "4", count: 64)
        let pluginAnon = String(repeating: "5", count: 64)

        let invRunner = try inventoryRunner()
        guard let inv = DockerProbe.inventory(runner: invRunner, tools: dockerTools, buildxInstances: instances) else { preconditionFailure("inventory") }
        precondition(inv.volumes.count == 7 && inv.images.count == 5 && inv.containers.count == 2, "\(inv)")
        precondition(inv.buildCacheReclaimable == 1_500_000_000 + 300_000_000, "only unshared, unused cache: \(inv.buildCacheReclaimable)")
        precondition(inv.builders == ["live"], "builders come from the buildx instances directory: \(String(describing: inv.builders))")
        precondition(!invRunner.calls.contains { $0.contains("buildx") }, "a read-only scan never asks buildx (it may contact remote builders)")
        precondition(inv.volumes.first { $0.name == "db" }?.driver == "local" && inv.volumes.first { $0.name == pluginAnon }?.driver == "rexray/ebs")
        precondition(inv.volumes.first { $0.name == anonUsed }?.mountedBy == ["old-job"])
        precondition(inv.volumes.first { $0.name == "db" }?.mountedBy == ["app-db"])
        precondition(inv.volumes.first { $0.name == anonFree }?.mountedBy == [])
        precondition(inv.containers.first { $0.id == oldJob }.map { $0.name == "old-job" && $0.state == "exited" && $0.size == 12_000_000 } == true)
        precondition(inv.images.first { $0.id == web1 }.map { $0.usedBy == 0 && $0.size == 120_000_000 && $0.createdAt != nil } == true,
            "image size is what removing it alone frees (UniqueSize)")
        precondition(inv.images.first { $0.id == lint }.map { $0.repository == "tools/lint" && $0.tag == "latest" && $0.size == 90_000_000 } == true)
        precondition(inv.images.first { $0.id == dangling }?.createdAt != nil, "dangling images are absent from image ls; fall back to df")

        let rows = DockerProbe.candidates(inv)
        func row(_ key: String) -> CleanupCandidate? { rows.first { $0.entry.id == CleanupCandidate.stableID("docker", key) } }
        func removes(_ c: CleanupCandidate?, _ kind: DockerObjectKind, _ id: String, expecting: String? = nil) -> Bool {
            if case .dockerRemove(let k, let i, let e)? = c?.action { return k == kind && i == id && e == expecting }
            return false
        }
        // A：匿名孤立卷、孤立 buildx 状态卷、悬空镜像、被同仓库新标签取代的镜像、构建缓存
        let a1 = row("volume:\(anonFree)")
        precondition(a1?.entry.tier == .obsolete && a1!.entry.defaultChecked && removes(a1, .volume, anonFree) && a1!.entry.size == 300_000_000)
        precondition(a1!.entry.actionLabel == "用 docker volume rm 删除" && !a1!.entry.reversible)
        let ghost = row("volume:buildx_buildkit_ghost0_state")
        precondition(ghost?.entry.tier == .obsolete && removes(ghost, .volume, "buildx_buildkit_ghost0_state"))
        // 镜像动作带上预览时的镜像 ID：标签在扫描后被挪走，执行时能发现
        let dang = row("image:\(dangling)")
        precondition(dang?.entry.tier == .obsolete && removes(dang, .image, dangling, expecting: dangling) && dang!.entry.actionLabel == "用 docker image rm 删除")
        let old = row("image:acme/web:1.0@\(web1)")
        precondition(old?.entry.tier == .obsolete && removes(old, .image, "acme/web:1.0", expecting: web1) && old!.entry.evidence.contains("acme/web:2.0"))
        let cache = row("buildcache")
        if case .toolClean(.dockerBuilderPrune, let scope)? = cache?.action { precondition(scope == "docker") } else { preconditionFailure("build cache row") }
        precondition(cache!.entry.tier == .obsolete && cache!.entry.estimateIsApprox && cache!.entry.size == 1_800_000_000 && cache!.entry.path == nil)
        // C：其余没人用的镜像、没挂载的命名卷、已停止的容器
        let unused = row("image:tools/lint:latest@\(lint)")
        precondition(unused?.entry.tier == .review && !unused!.entry.defaultChecked && unused!.entry.selectable
            && removes(unused, .image, "tools/lint:latest", expecting: lint))
        let named = row("volume:cache-data")
        precondition(named?.entry.tier == .review && named!.entry.selectable && !named!.entry.defaultChecked && removes(named, .volume, "cache-data"))
        let stopped = row("container:\(oldJob)")
        precondition(stopped?.entry.tier == .review && removes(stopped, .container, oldJob) && stopped!.entry.size == 12_000_000)
        precondition(stopped!.entry.actionLabel == "用 docker container rm 删除")
        // 非 local 驱动的卷（插件管理，可能是远端存储）：即便是匿名、没挂载，也只进 C
        let plugin = row("volume:\(pluginAnon)"), nfs = row("volume:nfs-share")
        precondition(plugin?.entry.tier == .review && !plugin!.entry.defaultChecked && plugin!.entry.evidence.contains("rexray/ebs"), "\(String(describing: plugin?.entry))")
        precondition(nfs?.entry.tier == .review && !nfs!.entry.defaultChecked && removes(nfs, .volume, "nfs-share"))
        // 被挂载的卷：不能删，写明被谁挂载
        let usedAnon = row("volume:\(anonUsed)"), db = row("volume:db")
        precondition(usedAnon?.entry.tier == .locked && usedAnon?.action == nil && usedAnon!.entry.lockReason == "被容器 old-job 挂载")
        precondition(db?.entry.tier == .locked && db?.action == nil && db!.entry.lockReason == "被容器 app-db 挂载" && !db!.entry.selectable)
        // 在用的镜像、运行中的容器：不出现
        precondition(!rows.contains { $0.entry.title.contains("acme/web:2.0") || $0.entry.title.contains("postgres") } && row("container:\(dbContainer)") == nil)
        precondition(rows.count == 12, "\(rows.map(\.entry.title))")
        precondition(rows.allSatisfy { $0.entry.source == "docker" && $0.entry.path == nil })

        // 名字不合法的对象永远不会进命令
        var hostile = inv
        hostile.volumes.append(.init(name: "-rf", size: 1, mountedBy: [], driver: "local"))
        hostile.images.append(.init(id: "--force", repository: "<none>", tag: "<none>", size: 1, createdAt: nil, usedBy: 0))
        hostile.containers.append(.init(id: "-f", name: "x", state: "exited", size: 1, volumes: []))
        // 暂停 / 重启中的容器执行时会被拒，不列成"已停止"
        hostile.containers.append(.init(id: String(repeating: "6", count: 64), name: "p", state: "paused", size: 1, volumes: []))
        hostile.containers.append(.init(id: String(repeating: "7", count: 64), name: "r", state: "restarting", size: 1, volumes: []))
        precondition(DockerProbe.candidates(hostile).count == rows.count, "unsafe docker references never become candidates")
        // buildx 状态卷对应的构建器还在 → 不是 A，按命名卷进 C
        var live = inv; live.builders = ["live", "ghost"]
        precondition(DockerProbe.candidates(live).first { $0.entry.id == ghost!.entry.id }?.entry.tier == .review)
        // 读不到 buildx 构建器目录：构建器未知，状态卷进 C；其余 Docker 行照常显示，不变成"Docker 未运行"
        guard let unknown = DockerProbe.inventory(runner: try inventoryRunner(), tools: dockerTools,
                                                  buildxInstances: instances + "/missing") else { preconditionFailure("buildx dir must not hide docker") }
        precondition(unknown.builders == nil)
        let unknownRows = DockerProbe.candidates(unknown)
        precondition(unknownRows.count == rows.count && unknownRows.first { $0.entry.id == ghost!.entry.id }?.entry.tier == .review)
        precondition(DockerProbe.removeArguments(kind: .image, id: "acme/web:1.0") == ["image", "rm", "--no-prune", "acme/web:1.0"])
        precondition(DockerProbe.removeArguments(kind: .volume, id: "v1") == ["volume", "rm", "v1"])
        precondition(DockerProbe.removeArguments(kind: .container, id: "c1") == ["rm", "c1"])

        // probe：本机 → 逐对象；远程 → 一行提示；守护进程不在 → 一行提示；没有 docker → 无
        let probed = DockerProbe.probe(runner: try inventoryRunner(), tools: dockerTools, buildxInstances: instances)
        precondition(probed.map(\.entry.id) == rows.map(\.entry.id), "\(probed.map(\.entry.title))")
        // 远程：先判断本机与否，一条盘点命令都不发给远程守护进程
        let remote = try inventoryRunner()
        remote.responses[contextKey] = ok("tcp://10.0.0.5:2376\n")
        let remoteRows = DockerProbe.probe(runner: remote, tools: dockerTools, buildxInstances: instances)
        precondition(remoteRows.count == 1 && remoteRows[0].entry.title == "Docker 指向远程主机" && !remoteRows[0].entry.selectable)
        precondition(!remote.calls.contains { $0.contains("system df") || $0.contains(" ps ") || $0.contains("image ls") }, "\(remote.calls)")
        precondition(DockerProbe.daemonBlocker(runner: remote, tools: dockerTools) == "当前 docker context 指向远程主机，Roomy 只清理本机")
        var hostTools = dockerTools; hostTools.dockerHost = "tcp://10.0.0.5:2376"
        let viaHost = try inventoryRunner()
        let hostRows = DockerProbe.probe(runner: viaHost, tools: hostTools, buildxInstances: instances)
        precondition(hostRows.count == 1 && hostRows[0].entry.title == "Docker 指向远程主机", "DOCKER_HOST wins over a local context")
        precondition(!viaHost.calls.contains { $0.contains("system df") }, "\(viaHost.calls)")
        hostTools.dockerHost = "unix:///var/run/docker.sock"
        let localHost = try inventoryRunner()
        precondition(DockerProbe.daemonBlocker(runner: localHost, tools: hostTools) == nil)
        precondition(!localHost.calls.contains { $0.contains("context inspect") }, "DOCKER_HOST wins; context not consulted")
        let healthy = try inventoryRunner()
        precondition(DockerProbe.daemonBlocker(runner: healthy, tools: dockerTools) == nil)
        let downRunner = FakeRunner()
        downRunner.responses[contextKey] = ok("unix:///x.sock\n")
        let down = DockerProbe.probe(runner: downRunner, tools: dockerTools, buildxInstances: instances)
        precondition(down.count == 1 && down[0].entry.title == "Docker 未运行" && !down[0].entry.selectable)
        // 提示不只说 Docker Desktop：OrbStack、Colima 也是常见的 Docker 来源；并说明这次没统计 Docker 的空间
        precondition(down[0].entry.evidence.contains("OrbStack") && down[0].entry.evidence.contains("Docker Desktop")
            && down[0].entry.evidence.contains("没有统计"), down[0].entry.evidence)
        let broken = DockerProbe.probe(runner: FakeRunner(), tools: dockerTools, buildxInstances: instances)
        precondition(broken.count == 1 && broken[0].entry.title == "Docker 未运行", "context unreadable is not 'remote'")
        let partial = try inventoryRunner()
        partial.responses["\(docker) image ls --no-trunc --format {{json .}}"] = nil
        precondition(DockerProbe.inventory(runner: partial, tools: dockerTools, buildxInstances: instances) == nil, "any failed listing → nil")
        precondition(DockerProbe.probe(runner: healthy, tools: noOllama).isEmpty, "no docker binary → nothing")

        try objectBlockerRechecks(tools: dockerTools)
        try daemonDownFailsEveryDockerRow(tools: dockerTools)
        print("OllamaDockerProbeTests passed")
    }

    private static func dockerEnv(_ runner: FakeRunner, tools: ToolLocator) -> CleanupEnvironment {
        var env = CleanupEnvironment()
        env.runner = runner; env.tools = tools; env.roots = ["/nonexistent-roomy-root"]
        env.diskFree = { 0 }
        env.trash = { _ in preconditionFailure("docker objects never go to the trash") }
        return env
    }

    private static func dockerRow(_ kind: DockerObjectKind, _ id: String, size: UInt64 = 40, expecting: String? = nil) -> CleanupCandidate {
        CleanupCandidate(source: "docker", key: "\(kind.rawValue):\(id)", title: id, size: size, evidence: "e",
            risk: .amber, action: .dockerRemove(kind: kind, id: id, expectedID: expecting), tier: .obsolete)
    }

    /// 执行前逐个复核：预览后被容器用上了 / 已经没了 → 不删，也绝不退回 system prune
    static func objectBlockerRechecks(tools: ToolLocator) throws {
        let docker = "/fake/docker"
        let runner = FakeRunner()
        runner.responses["\(docker) context inspect --format {{.Endpoints.docker.Host}}"] = ok("unix:///x.sock")
        runner.responses["\(docker) info --format {{.ServerVersion}}"] = ok("29.0.0")
        runner.responses["\(docker) volume inspect --format {{.Name}} v1"] = ok("v1\n")
        runner.responses["\(docker) ps -a --filter volume=v1 -q"] = ok("abc\n")
        runner.responses["\(docker) volume rm v1"] = ok("v1\n")
        // v2：没被用 → 真删
        runner.responses["\(docker) volume inspect --format {{.Name}} v2"] = ok("v2\n")
        runner.responses["\(docker) ps -a --filter volume=v2 -q"] = ok("")
        runner.responses["\(docker) volume rm v2"] = ok("v2\n")
        // 镜像：预览后起了用它的容器
        runner.responses["\(docker) image inspect --format {{.Id}} acme/web:1.0"] = ok("sha256:x\n")
        runner.responses["\(docker) ps -a --filter ancestor=acme/web:1.0 -q"] = ok("def\n")
        // 镜像：标签在扫描后被重新构建，指向了另一个镜像
        runner.responses["\(docker) image inspect --format {{.Id}} acme/web:moved"] = ok("sha256:\(String(repeating: "9", count: 64))\n")
        runner.responses["\(docker) ps -a --filter ancestor=acme/web:moved -q"] = ok("")
        runner.responses["\(docker) image rm --no-prune acme/web:moved"] = ok("")
        // 镜像：还是预览的那个，没人用 → 删，且不连带删父镜像
        let apiID = "sha256:" + String(repeating: "f", count: 64)
        runner.responses["\(docker) image inspect --format {{.Id}} acme/api:1.0"] = ok(apiID + "\n")
        runner.responses["\(docker) ps -a --filter ancestor=acme/api:1.0 -q"] = ok("")
        runner.responses["\(docker) image rm --no-prune acme/api:1.0"] = ok("Untagged: acme/api:1.0\n")
        // 镜像 tools/lint:latest 已经被手动删掉
        // 容器：还在跑 / 已停止
        runner.responses["\(docker) container inspect --format {{.State.Status}} c-run"] = ok("running\n")
        runner.responses["\(docker) container inspect --format {{.State.Status}} c-old"] = ok("exited\n")
        runner.responses["\(docker) rm c-old"] = ok("c-old\n")

        let v1 = dockerRow(.volume, "v1"), v2 = dockerRow(.volume, "v2", size: 77)
        let img = dockerRow(.image, "acme/web:1.0", expecting: "sha256:x"), gone = dockerRow(.image, "tools/lint:latest", expecting: "sha256:e")
        let moved = dockerRow(.image, "acme/web:moved", expecting: "sha256:" + String(repeating: "8", count: 64))
        let api = dockerRow(.image, "acme/api:1.0", size: 33, expecting: apiID)
        let running = dockerRow(.container, "c-run"), stopped = dockerRow(.container, "c-old", size: 9)
        let bad = dockerRow(.volume, "-rf")
        let all = [v1, v2, img, gone, moved, api, running, stopped, bad]
        let list = CleanupList(candidates: all)
        let summary = CleanupRunner.run(ids: all.map(\.entry.id), list: list, env: dockerEnv(runner, tools: tools)) { _ in }
        let byID = Dictionary(uniqueKeysWithValues: summary.outcomes.map { ($0.id, $0) })
        precondition(byID[v1.entry.id]!.ok == false && byID[v1.entry.id]!.message == "已被容器使用", "\(byID[v1.entry.id]!)")
        precondition(byID[v2.entry.id]!.ok && byID[v2.entry.id]!.bytes == 77, "\(byID[v2.entry.id]!)")
        precondition(!byID[img.entry.id]!.ok && byID[img.entry.id]!.message == "已被容器使用")
        precondition(!byID[gone.entry.id]!.ok && byID[gone.entry.id]!.message == "已不存在", byID[gone.entry.id]!.message)
        precondition(!byID[moved.entry.id]!.ok && byID[moved.entry.id]!.message == "已变化，请重新扫描", byID[moved.entry.id]!.message)
        precondition(!runner.calls.contains { $0.contains("rm --no-prune acme/web:moved") }, "a moved tag is never removed")
        precondition(byID[api.entry.id]!.ok && byID[api.entry.id]!.bytes == 33, "\(byID[api.entry.id]!)")
        precondition(runner.calls.contains("\(docker) image rm --no-prune acme/api:1.0"))
        precondition(!byID[running.entry.id]!.ok && byID[running.entry.id]!.message == "容器正在运行")
        precondition(byID[stopped.entry.id]!.ok && byID[stopped.entry.id]!.bytes == 9)
        precondition(summary.permanentBytes == 77 + 33 + 9)
        precondition(!byID[bad.entry.id]!.ok && byID[bad.entry.id]!.message == "Docker 对象标识不合法")
        precondition(!runner.calls.contains("\(docker) volume rm v1"), "\(runner.calls)")
        precondition(!runner.calls.contains { ($0.contains("image rm") && !$0.hasSuffix("acme/api:1.0")) || $0.contains("rm c-run") || $0.contains("-rf") }, "\(runner.calls)")
        precondition(!runner.calls.contains { $0.contains("system prune") })
        // 复审导出里写明每个对象
        let review = try CleanupReview(ids: [v2.entry.id, stopped.entry.id, api.entry.id], list: list).markdown(appVersion: "t")
        precondition(review.contains("Docker 卷：v2") && review.contains("Docker 容器：c-old"), review)
        precondition(review.contains("Docker 镜像：acme/api:1.0（镜像 ID ffffffffffff）"), review)
    }

    /// 守护进程不在：每一项都失败，消息一致，不跑任何删除命令
    static func daemonDownFailsEveryDockerRow(tools: ToolLocator) throws {
        let runner = FakeRunner()
        runner.responses["/fake/docker context inspect --format {{.Endpoints.docker.Host}}"] = ok("unix:///x.sock")
        let rows = [dockerRow(.volume, "v1"), dockerRow(.image, "acme/web:1.0", expecting: "sha256:x"), dockerRow(.container, "c-old"),
                    CleanupCandidate(source: "docker", key: "buildcache", title: "Docker 构建缓存", size: 5, evidence: "e",
                        risk: .amber, action: .toolClean(.dockerBuilderPrune, scope: "docker"), estimateIsApprox: true, tier: .obsolete)]
        let summary = CleanupRunner.run(ids: rows.map(\.entry.id), list: CleanupList(candidates: rows),
                                        env: dockerEnv(runner, tools: tools)) { _ in }
        precondition(summary.outcomes.allSatisfy { !$0.ok && $0.message == "Docker 未运行" }, "\(summary.outcomes)")
        precondition(!runner.calls.contains { $0.contains(" rm ") || $0.contains("prune") }, "\(runner.calls)")
    }
}
