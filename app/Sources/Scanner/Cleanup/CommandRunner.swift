// SPDX-License-Identifier: MPL-2.0
// 外部命令的唯一出口。直接 exec 绝对路径，不经过 shell，参数原样传给子进程。

import Foundation

struct CommandResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    var ok: Bool { status == 0 && !timedOut }
}

protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult
    /// 工具命令用：environment 整体替换子进程环境（GIT_ 变量仍会去掉），directory 为工作目录
    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             timeout: TimeInterval) -> CommandResult
    /// 参数放不下或不该出现在命令行里时用：input 原样写入子进程的标准输入（git check-ignore --stdin -z）
    func run(_ executable: String, _ arguments: [String], input: String, timeout: TimeInterval) -> CommandResult
}

extension CommandRunning {
    /// 测试替身默认忽略标准输入；ProcessRunner 真正写入
    func run(_ executable: String, _ arguments: [String], input: String, timeout: TimeInterval) -> CommandResult {
        run(executable, arguments, timeout: timeout)
    }

    /// 测试替身默认忽略环境和目录；ProcessRunner 真正使用它们
    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             timeout: TimeInterval) -> CommandResult {
        run(executable, arguments, timeout: timeout)
    }
}

private final class PipeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return value }
}

struct ProcessRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        launch(executable, arguments, environment: ProcessInfo.processInfo.environment, directory: nil, input: nil, timeout: timeout)
    }

    func run(_ executable: String, _ arguments: [String], input: String, timeout: TimeInterval) -> CommandResult {
        launch(executable, arguments, environment: ProcessInfo.processInfo.environment, directory: nil,
               input: Data(input.utf8), timeout: timeout)
    }

    func run(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
             timeout: TimeInterval) -> CommandResult {
        launch(executable, arguments, environment: environment, directory: directory, input: nil, timeout: timeout)
    }

    private func launch(_ executable: String, _ arguments: [String], environment: [String: String], directory: String?,
                        input: Data?, timeout: TimeInterval) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdin = input == nil ? nil : Pipe()
        process.standardInput = stdin ?? FileHandle.nullDevice
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        // 不继承 GIT_DIR / GIT_WORK_TREE 之类：从代理的 shell 里启动时，它们会让 git 看错仓库
        process.environment = environment.filter { !$0.key.hasPrefix("GIT_") }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }
        if let stdin, let input {
            // 子进程没读完就退出时写端会收到 SIGPIPE：关掉它，让写入只返回错误而不是杀掉本进程
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? stdin.fileHandleForReading.close()
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        // stdout 和 stderr 同时读，任何一边写满管道都不会卡住子进程
        let outSink = PipeSink(), errSink = PipeSink()
        let readers = DispatchGroup()
        let outHandle = out.fileHandleForReading, errHandle = err.fileHandleForReading
        DispatchQueue.global().async(group: readers) { outSink.set(outHandle.readDataToEndOfFile()) }
        DispatchQueue.global().async(group: readers) { errSink.set(errHandle.readDataToEndOfFile()) }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // 子进程退出后输出还没读完（比如后台孙进程占着管道）：结果不完整，按失败处理
        if readers.wait(timeout: .now() + 2) == .timedOut {
            return CommandResult(status: -1, stdout: "", stderr: "子进程的输出没有读完", timedOut: timedOut)
        }
        return CommandResult(status: process.terminationStatus,
            stdout: String(decoding: outSink.data, as: UTF8.self),
            stderr: String(decoding: errSink.data, as: UTF8.self), timedOut: timedOut)
    }
}

enum Tool: String { case xcrun, git, ollama, docker, mdfind, launchctl, ps, sysctl, tmutil, npm, go, pip3, uv, pnpm, brew }

struct ToolLocator {
    var searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin",
                                   "\(HOME)/.local/bin", "\(HOME)/.cargo/bin", "/usr/local/go/bin"]
    var isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    /// DOCKER_HOST：docker 先看它再看 context。测试注入，不直接读进程环境
    var dockerHost: String? = ProcessInfo.processInfo.environment["DOCKER_HOST"]
    /// 是否装了命令行工具或 Xcode（xcode-select -p 退出码 0）。测试注入；默认每个进程只查一次
    var developerToolsInstalled: () -> Bool = { ToolLocator.systemDeveloperToolsInstalled }

    static let systemPip3 = "/usr/bin/pip3"
    static let xcodeSelect = "/usr/bin/xcode-select"
    /// xcode-select -p 只打印开发者目录，从不弹安装框；没装时退出码非 0
    static let systemDeveloperToolsInstalled: Bool = ProcessRunner().run(xcodeSelect, ["-p"], timeout: 5).ok

    func path(for tool: Tool) -> String? {
        if tool == .pip3, let found = searchDirectories.map({ "\($0)/pip3" }).first(where: isExecutable) { return found }
        // /usr/bin/pip3 是系统占位程序：没装命令行工具时一运行就会弹出安装对话框，所以只在已装时才用它，且只给 pip3 用
        if tool == .pip3 { return isExecutable(Self.systemPip3) && developerToolsInstalled() ? Self.systemPip3 : nil }
        switch tool {
        case .xcrun: return isExecutable("/usr/bin/xcrun") ? "/usr/bin/xcrun" : nil
        case .git:   return isExecutable("/usr/bin/git") ? "/usr/bin/git" : nil
        case .mdfind: return isExecutable("/usr/bin/mdfind") ? "/usr/bin/mdfind" : nil
        case .launchctl: return isExecutable("/bin/launchctl") ? "/bin/launchctl" : nil
        case .ps: return isExecutable("/bin/ps") ? "/bin/ps" : nil
        case .sysctl: return isExecutable("/usr/sbin/sysctl") ? "/usr/sbin/sysctl" : nil
        case .tmutil: return isExecutable("/usr/bin/tmutil") ? "/usr/bin/tmutil" : nil
        case .ollama, .docker, .npm, .go, .pip3, .uv, .pnpm, .brew:
            return searchDirectories.map { "\($0)/\(tool.rawValue)" }.first(where: isExecutable)
        }
    }
}

enum CleanupArgument {
    static func isUUID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    /// launchd 标签：不以 "-" 开头，只含字母数字和 ._-
    static func isLaunchLabel(_ value: String) -> Bool {
        guard let first = value.first, first != "-", value.count <= 200 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Docker 卷名、镜像引用（repo:tag、sha256:…、@digest）、容器 ID：不以 "-" 开头，只含 [A-Za-z0-9._:/@-]
    static func isDockerReference(_ value: String) -> Bool {
        guard let first = value.first, first != "-", value.count <= 256 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:/@-".contains($0)) }
    }

    /// 不以 "-" 开头，防止被当成命令选项
    static func isModelName(_ value: String) -> Bool {
        guard let first = value.first, first != "-", value.count <= 200 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._:/-".contains($0)) }
    }
}
