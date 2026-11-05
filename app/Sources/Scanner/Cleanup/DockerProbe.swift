// SPDX-License-Identifier: GPL-3.0-only
// Docker 的数据在一个 .raw 镜像里，删文件回收不了，只能让 docker 自己删。
// 按对象列出：每个卷、每个镜像、每个已停止的容器各一行，执行时只删这一行列出的那个对象，
// 预览什么就删什么；构建缓存交给 docker builder prune。不再用 docker system prune。
// 只盘点本机守护进程；构建器名读 buildx 的本地目录，扫描时不去连任何远程构建器。

import Foundation

struct DockerInventory {
    struct Volume { let name: String; let size: UInt64; let mountedBy: [String]; var driver = "local" }
    struct Image { let id: String; let repository: String; let tag: String; let size: UInt64; let createdAt: Date?; let usedBy: Int }
    struct Container { let id: String; let name: String; let state: String; let size: UInt64; let volumes: [String] }
    var volumes: [Volume]
    var images: [Image]
    var containers: [Container]
    var buildCacheReclaimable: UInt64
    var builders: [String]?   // nil = 读不到 buildx 构建器目录，不知道有哪些构建器
}

enum DockerProbe {
    static let listTimeout: TimeInterval = 60   // df -v 要统计每个卷的大小，卷多时慢

    /// docker 用十进制单位，且可能带 " (57%)" / " (virtual 491MB)" 后缀
    static func parseBytes(_ text: String) -> UInt64? {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("kB", 1e3), ("KB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12), ("B", 1)]
        for (suffix, scale) in units where token.hasSuffix(suffix) {
            guard let value = Double(token.dropLast(suffix.count)) else { return nil }
            return UInt64((value * scale).rounded())
        }
        return nil
    }

    /// "2026-10-29 18:52:19 +0400 +04"：最后的时区缩写不可靠，只取前三段
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: " ").prefix(3)
        guard parts.count == 3 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: parts.joined(separator: " "))
    }

    // MARK: 盘点

    /// buildx 把每个构建器存成 instances 目录下的一个文件，文件名即构建器名（DOCKER_CONFIG 可改位置）
    static var defaultBuildxInstances: String {
        let config = ProcessInfo.processInfo.environment["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? HOME + "/.docker"
        return config + "/buildx/instances"
    }

    /// 读不到返回 nil。不用 docker buildx ls：它会去连远程 / Kubernetes / 云端构建器
    static func builders(instances: String) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: instances) else { return nil }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 三条只读命令拼出完整盘点；任一条失败返回 nil。调用前须已确认 docker 指向本机
    static func inventory(runner: CommandRunning, tools: ToolLocator,
                          buildxInstances: String = defaultBuildxInstances) -> DockerInventory? {
        guard let docker = tools.path(for: .docker) else { return nil }
        func run(_ args: [String]) -> String? {
            let r = ToolInvocation.run(.docker, executable: docker, args, runner: runner, tools: tools, timeout: listTimeout)
            return r.ok ? r.stdout : nil
        }
        guard let dfText = run(["system", "df", "-v", "--format", "json"]),
              let df = try? JSONSerialization.jsonObject(with: Data(dfText.utf8)) as? [String: Any],
              let psText = run(["ps", "-a", "--no-trunc", "--format", "{{json .}}"]),
              let imageText = run(["image", "ls", "--no-trunc", "--format", "{{json .}}"]) else { return nil }

        func rows(_ key: String) -> [[String: Any]] { df[key] as? [[String: Any]] ?? [] }
        func string(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }
        func bytes(_ row: [String: Any], _ key: String) -> UInt64? { parseBytes(string(row, key)) }
        func jsonLines(_ text: String) -> [[String: Any]] {
            text.split(whereSeparator: \.isNewline).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }

        // 容器大小（可写层）来自 df；挂载的卷名来自 ps 的 Mounts（逗号分隔，绑定挂载是路径）
        var containerSize: [String: UInt64] = [:]
        for row in rows("Containers") { containerSize[string(row, "ID")] = bytes(row, "Size") ?? 0 }
        let containers = jsonLines(psText).map { row -> DockerInventory.Container in
            let id = string(row, "ID")
            let mounts = string(row, "Mounts").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return .init(id: id, name: string(row, "Names"), state: string(row, "State"),
                         size: containerSize[id] ?? 0, volumes: mounts.filter { !$0.isEmpty })
        }
        let volumes = rows("Volumes").map { row -> DockerInventory.Volume in
            let name = string(row, "Name")
            return .init(name: name, size: bytes(row, "Size") ?? 0,
                         mountedBy: containers.filter { $0.volumes.contains(name) }.map(\.name), driver: string(row, "Driver"))
        }
        // 镜像创建时间以 image ls 为准；悬空镜像不在 image ls 里，退回 df 自带的
        var created: [String: Date] = [:]
        for row in jsonLines(imageText) { created[string(row, "ID")] = parseDate(string(row, "CreatedAt")) }
        let images = rows("Images").map { row -> DockerInventory.Image in
            let id = string(row, "ID")
            // UniqueSize：只删这一个镜像能放出的空间（共享层不算）
            return .init(id: id, repository: string(row, "Repository"), tag: string(row, "Tag"),
                         size: bytes(row, "UniqueSize") ?? bytes(row, "Size") ?? 0,
                         createdAt: created[id] ?? parseDate(string(row, "CreatedAt")),
                         usedBy: Int(string(row, "Containers")) ?? 0)
        }
        // 与 docker system df 的 Reclaimable 一致：不共享、也不在用的缓存
        let reclaimable = rows("BuildCache").reduce(UInt64(0)) { sum, row in
            guard string(row, "Shared") != "true", string(row, "InUse") != "true" else { return sum }
            return sum + (bytes(row, "Size") ?? 0)
        }
        return DockerInventory(volumes: volumes, images: images, containers: containers,
                               buildCacheReclaimable: reclaimable, builders: builders(instances: buildxInstances))
    }

    // MARK: 定档

    static func isAnonymousVolume(_ name: String) -> Bool {
        name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// buildx_buildkit_<构建器>0_state 的构建器名；不是这种卷返回 nil
    static func buildxStateBuilder(_ volume: String) -> (builder: String, node: String)? {
        let prefix = "buildx_buildkit_", suffix = "_state"
        guard volume.hasPrefix(prefix), volume.hasSuffix(suffix), volume.count > prefix.count + suffix.count else { return nil }
        let node = String(volume.dropFirst(prefix.count).dropLast(suffix.count))
        guard node.hasSuffix("0"), node.count > 1 else { return nil }
        return (String(node.dropLast()), node)
    }

    /// 不再接受删除的容器状态：执行时会被拒，不列成"已停止"
    static let activeContainerStates: Set<String> = ["running", "restarting", "paused", "removing"]

    static func shortID(_ id: String) -> String {
        String((id.hasPrefix("sha256:") ? String(id.dropFirst(7)) : id).prefix(12))
    }

    private static let obsoleteVolumeReason = "匿名卷没有任何容器挂载，通常是删掉容器后留下的"
    private static let reviewNote = "删除后无法恢复"

    static func candidates(_ inv: DockerInventory) -> [CleanupCandidate] {
        var out: [CleanupCandidate] = []
        func add(_ key: String, _ title: String, _ size: UInt64, _ evidence: String, _ action: CleanupAction,
                 _ tier: CleanupTier, approx: Bool = false) {
            out.append(CleanupCandidate(source: "docker", key: key, title: title, size: size, evidence: evidence,
                risk: .amber, action: action, estimateIsApprox: approx, tier: tier, tierReason: evidence))
        }
        let short = shortID

        for v in inv.volumes where CleanupArgument.isDockerReference(v.name) {
            let key = "volume:\(v.name)", action = CleanupAction.dockerRemove(kind: .volume, id: v.name)
            let anonymous = isAnonymousVolume(v.name)
            let title = anonymous ? "Docker 匿名卷 · \(short(v.name))" : "Docker 卷 · \(v.name)"
            if !v.mountedBy.isEmpty {
                let base = CleanupCandidate(source: "docker", key: key, title: title, size: v.size,
                    evidence: "数据卷", risk: .amber, action: action)
                out.append(base.locked("被容器 \(v.mountedBy.joined(separator: "、")) 挂载"))
            } else if v.driver != "local" {
                // 插件驱动的卷，数据可能在远端存储上：从不默认勾选
                add(key, title, v.size, "由 \(v.driver.isEmpty ? "未知" : v.driver) 驱动管理的卷，删除可能同时删掉它背后的存储；" + reviewNote,
                    action, .review)
            } else if anonymous {
                add(key, title, v.size, obsoleteVolumeReason, action, .obsolete)
            } else if let buildx = buildxStateBuilder(v.name), let builders = inv.builders,
                      !builders.contains(buildx.builder), !builders.contains(buildx.node) {
                add(key, "Docker 构建器状态卷 · \(v.name)", v.size,
                    "构建器 \(buildx.builder) 已不存在，这是它留下的状态卷", action, .obsolete)
            } else {
                add(key, title, v.size, "命名卷，当前没有容器挂载；里面可能是数据库等数据，" + reviewNote, action, .review)
            }
        }

        let tagged = Set(inv.images.filter { $0.repository != "<none>" }.map(\.id))
        for image in inv.images where image.usedBy == 0 {
            let hasTag = image.repository != "<none>" && image.tag != "<none>"
            let ref = hasTag ? "\(image.repository):\(image.tag)" : image.id
            guard CleanupArgument.isDockerReference(ref) else { continue }
            // 带上镜像 ID：标签在扫描后指向别的镜像时，id 和执行前的复核都会不同
            let key = hasTag ? "image:\(ref)@\(image.id)" : "image:\(ref)"
            let action = CleanupAction.dockerRemove(kind: .image, id: ref, expectedID: image.id)
            if image.repository == "<none>", !tagged.contains(image.id) {
                add(key, "Docker 悬空镜像 · \(short(image.id))", image.size,
                    "没有标签、也没有容器使用的悬空镜像，通常是重新构建后留下的旧层", action, .obsolete, approx: true)
                continue
            }
            // 没有标签、但同一个镜像 ID 还有别的带标签引用：不是真正的悬空镜像（A），档位偏好要分开记
            defer {
                if !hasTag, tagged.contains(image.id), let last = out.indices.last, out[last].entry.id == CleanupCandidate.stableID("docker", key) {
                    out[last].entry.preferenceKey = .init(owner: "docker", kind: "image",
                        scope: CleanupPreferenceKey.digest("<none>@tagged-elsewhere"))
                }
            }
            let newer = hasTag ? inv.images.filter { other in
                other.repository == image.repository && other.tag != image.tag && other.tag != "<none>"
                    && other.id != image.id
                    && (other.createdAt.flatMap { a in image.createdAt.map { a > $0 } } ?? false)
            }.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) } : nil
            if let newer {
                add(key, "Docker 镜像 · \(ref)", image.size,
                    "同仓库有更新的标签 \(newer.repository):\(newer.tag)，这个旧标签没有容器使用", action, .obsolete, approx: true)
            } else {
                add(key, "Docker 镜像 · \(ref)", image.size,
                    "没有容器使用；删除后再用需要重新拉取或构建", action, .review, approx: true)
            }
        }

        if inv.buildCacheReclaimable > 0 {
            add("buildcache", "Docker 构建缓存", inv.buildCacheReclaimable,
                "当前没有被使用的构建缓存，下次构建会重新生成", .toolClean(.dockerBuilderPrune, scope: "docker"),
                .obsolete, approx: true)
        }

        for c in inv.containers where !activeContainerStates.contains(c.state) && CleanupArgument.isDockerReference(c.id) {
            add("container:\(c.id)", "Docker 已停止的容器 · \(c.name)", c.size,
                "已停止（\(c.state)）；容器里写入的改动会一起删除，" + reviewNote,
                .dockerRemove(kind: .container, id: c.id), .review)
            // 容器 ID 每次重建都会变，档位偏好按容器名记（没有名字才退回 ID）
            out[out.count - 1].entry.preferenceKey = .init(owner: "docker", kind: "container",
                scope: CleanupPreferenceKey.digest(c.name.isEmpty ? c.id : c.name))
        }
        return out
    }

    static func probe(runner: CommandRunning, tools: ToolLocator,
                      buildxInstances: String = defaultBuildxInstances) -> [CleanupCandidate] {
        guard let docker = tools.path(for: .docker) else { return [] }
        let down = [CleanupCandidate(source: "docker", key: "down", title: "Docker 未运行", size: 0,
            evidence: "连不上 Docker，这次没有统计 Docker 的空间；启动 Docker Desktop、OrbStack 或 Colima 后重新扫描，可以逐个清理不用的镜像、数据卷、容器和构建缓存", risk: .amber, action: nil)]
        // 先确认指向本机，再盘点：远程主机一条命令都不发
        guard let host = endpoint(docker: docker, runner: runner, tools: tools) else { return down }
        guard host.hasPrefix("unix://") else {
            return [CleanupCandidate(source: "docker", key: "remote", title: "Docker 指向远程主机", size: 0,
                evidence: "当前 docker context 不是本机，Roomy 不会去清理别的机器", risk: .amber, action: nil)]
        }
        guard let inv = inventory(runner: runner, tools: tools, buildxInstances: buildxInstances) else { return down }
        return candidates(inv)
    }

    // MARK: 执行

    static func removeArguments(kind: DockerObjectKind, id: String) -> [String] {
        switch kind {
        case .volume: return ["volume", "rm", id]
        case .image: return ["image", "rm", "--no-prune", id]   // 不连带删没列出来的无标签父镜像
        case .container: return ["rm", id]
        }
    }

    static func daemonBlocker(runner: CommandRunning, tools: ToolLocator) -> String? {
        guard let docker = tools.path(for: .docker) else { return "找不到 docker" }
        guard endpoint(docker: docker, runner: runner, tools: tools)?.hasPrefix("unix://") == true else { return "当前 docker context 指向远程主机，Roomy 只清理本机" }
        return runner.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 10).ok ? nil : "Docker 未运行"
    }

    /// 删除前复核这一个对象：还在、仍是预览时那个（expectedID）、没被任何容器（包括已停止的）使用。nil = 可以删
    static func objectBlocker(kind: DockerObjectKind, id: String, expectedID: String? = nil,
                              runner: CommandRunning, tools: ToolLocator) -> String? {
        if let why = daemonBlocker(runner: runner, tools: tools) { return why }
        guard CleanupArgument.isDockerReference(id) else { return "Docker 对象标识不合法" }
        guard let docker = tools.path(for: .docker) else { return "找不到 docker" }
        func run(_ args: [String]) -> CommandResult {
            ToolInvocation.run(.docker, executable: docker, args, runner: runner, tools: tools, timeout: 10)
        }
        let inspect: [String]
        switch kind {
        case .volume: inspect = ["volume", "inspect", "--format", "{{.Name}}", id]
        case .image: inspect = ["image", "inspect", "--format", "{{.Id}}", id]
        case .container: inspect = ["container", "inspect", "--format", "{{.State.Status}}", id]
        }
        let found = run(inspect)
        guard found.ok else { return "已不存在" }
        if kind == .image, let expectedID,
           found.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != expectedID { return "已变化，请重新扫描" }
        let filter: String
        switch kind {
        case .volume: filter = "volume=\(id)"
        case .image: filter = "ancestor=\(id)"
        case .container:
            let state = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return ["running", "restarting", "paused"].contains(state) ? "容器正在运行" : nil
        }
        let users = run(["ps", "-a", "--filter", filter, "-q"])
        guard users.ok else { return "无法确认是否有容器在用，请重新扫描" }
        return users.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "已被容器使用"
    }

    /// docker 实际连接的地址：DOCKER_HOST 优先于 context。读不到返回 nil；本机必须是 unix socket
    private static func endpoint(docker: String, runner: CommandRunning, tools: ToolLocator) -> String? {
        if let host = tools.dockerHost, !host.isEmpty { return host }
        let r = runner.run(docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: 10)
        let host = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.ok && !host.isEmpty ? host : nil
    }
}
