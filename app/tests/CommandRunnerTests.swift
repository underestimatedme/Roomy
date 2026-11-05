// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct CommandRunnerTests {
    static func main() {
        let runner = ProcessRunner()

        let echo = runner.run("/bin/echo", ["a b", ";", "$(id)"], timeout: 5)
        precondition(echo.ok && echo.stdout == "a b ; $(id)\n", "arguments must pass through literally: \(echo)")

        let failing = runner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"], timeout: 5)
        precondition(failing.status == 3 && failing.stderr == "oops\n" && !failing.ok, "\(failing)")

        // 大输出同时写 stdout 和 stderr，不能死锁
        let noisy = runner.run("/bin/sh", ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"], timeout: 10)
        precondition(noisy.ok && noisy.stdout.utf8.count == 200000 && noisy.stderr.utf8.count == 200000, "\(noisy.status)")

        let started = Date()
        let slow = runner.run("/bin/sleep", ["30"], timeout: 0.5)
        precondition(slow.timedOut && !slow.ok, "\(slow)")
        precondition(Date().timeIntervalSince(started) < 5, "timeout must kill the child promptly")

        // 主进程退出了，但后台子进程还占着 stdout：没读完的输出绝不能当成"成功且为空"
        let leaked = runner.run("/bin/sh", ["-c", "echo ' M dirty-file'; sleep 4 &"], timeout: 5)
        precondition(!leaked.ok, "unfinished output must not count as success: \(leaked)")

        // 从代理的 shell 里启动时可能带着 GIT_DIR / GIT_WORK_TREE，不能让 git 子进程看错仓库
        setenv("GIT_DIR", "/somewhere/else/.git", 1)
        setenv("GIT_WORK_TREE", "/somewhere/else", 1)
        let env = runner.run("/usr/bin/env", [], timeout: 5)
        precondition(env.ok && !env.stdout.contains("GIT_DIR=") && !env.stdout.contains("GIT_WORK_TREE="), "GIT_ variables leaked to child")
        precondition(env.stdout.contains("PATH="), "other variables are kept")
        unsetenv("GIT_DIR"); unsetenv("GIT_WORK_TREE")

        // 工具命令：环境整体替换（PATH 等由调用方拼好），工作目录可指定
        let custom = runner.run("/usr/bin/env", [], environment: ["PATH": "/opt/x/bin:/usr/bin", "ROOMY_PROBE": "1", "GIT_DIR": "/x"],
                                directory: "/private/tmp", timeout: 5)
        precondition(custom.ok && custom.stdout.contains("PATH=/opt/x/bin:/usr/bin") && custom.stdout.contains("ROOMY_PROBE=1"), custom.stdout)
        precondition(!custom.stdout.contains("GIT_DIR="), "GIT_ variables are never passed to tools")
        let cwd = runner.run("/bin/pwd", [], environment: [:], directory: "/private/tmp", timeout: 5)
        precondition(cwd.ok && cwd.stdout == "/private/tmp\n", cwd.stdout)
        let toolEnv = ToolInvocation.environment(for: .npm, executable: "/opt/node/bin/npm",
            tools: ToolLocator(searchDirectories: ["/a", "/b"], isExecutable: { _ in true }), base: ["PATH": "/usr/bin:/custom", "LANG": "C"])
        precondition(toolEnv["PATH"] == "/opt/node/bin:/a:/b:/usr/bin:/bin:/usr/sbin:/sbin:/custom", toolEnv["PATH"] ?? "nil")
        precondition(toolEnv["LANG"] == "C" && toolEnv["GOTOOLCHAIN"] == nil)
        let goEnv = ToolInvocation.environment(for: .go, executable: "/usr/local/go/bin/go", tools: ToolLocator(searchDirectories: []), base: [:])
        precondition(goEnv["GOTOOLCHAIN"] == "local" && goEnv["PATH"] == "/usr/local/go/bin:/usr/bin:/bin:/usr/sbin:/sbin", goEnv["PATH"] ?? "nil")

        // 标准输入：原样写入（含 NUL），大输入不死锁，子进程不读也不会让本进程收到 SIGPIPE
        let piped = runner.run("/usr/bin/wc", ["-c"], input: "a\0b\0c\0", timeout: 5)
        precondition(piped.ok && piped.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "6", "\(piped)")
        let big = String(repeating: "x", count: 1_000_000)
        let bigPiped = runner.run("/bin/cat", [], input: big, timeout: 10)
        precondition(bigPiped.ok && bigPiped.stdout.utf8.count == 1_000_000, "\(bigPiped.status)")
        let unread = runner.run("/usr/bin/true", [], input: big, timeout: 5)
        precondition(unread.ok, "a child that never reads stdin must not kill the caller: \(unread)")
        // 没有实现 stdin 的替身仍然能编译，并走无输入的重载
        struct Plain: CommandRunning {
            func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
                CommandResult(status: 0, stdout: "plain", stderr: "", timedOut: false)
            }
        }
        precondition(Plain().run("/x", [], input: "ignored", timeout: 1).stdout == "plain")

        let missing = runner.run("/nonexistent/tool", [], timeout: 1)
        precondition(missing.status == -1 && !missing.ok, "\(missing)")

        let locator = ToolLocator(searchDirectories: ["/a", "/b"],
            isExecutable: { $0 == "/b/docker" || $0 == "/usr/bin/xcrun" })
        precondition(locator.path(for: .docker) == "/b/docker")
        precondition(locator.path(for: .ollama) == nil)
        precondition(locator.path(for: .xcrun) == "/usr/bin/xcrun")
        precondition(locator.path(for: .git) == nil)

        // ── /usr/bin/pip3 只作 pip3 的后备，且只在 xcode-select -p 成功时用（没装命令行工具时它是会弹安装框的占位程序）
        final class Probe: @unchecked Sendable { var asked = 0 }
        func systemPip(_ installed: Bool, executable: @escaping (String) -> Bool, dirs: [String] = ["/a"]) -> (ToolLocator, Probe) {
            let probe = Probe()
            let tools = ToolLocator(searchDirectories: dirs, isExecutable: executable, dockerHost: nil,
                                    developerToolsInstalled: { probe.asked += 1; return installed })
            return (tools, probe)
        }
        let usrBin: (String) -> Bool = { $0.hasPrefix("/usr/bin/") }
        let (withCLT, cltProbe) = systemPip(true, executable: usrBin)
        precondition(withCLT.path(for: .pip3) == "/usr/bin/pip3", "\(String(describing: withCLT.path(for: .pip3)))")
        for other in [Tool.npm, .go, .uv, .pnpm, .brew, .docker, .ollama] {
            precondition(withCLT.path(for: other) == nil, "/usr/bin is a fallback for pip3 only, not \(other)")
        }
        precondition(cltProbe.asked >= 1)
        let (noCLT, _) = systemPip(false, executable: usrBin)
        precondition(noCLT.path(for: .pip3) == nil, "no Command Line Tools: never run the /usr/bin/pip3 shim")
        let (preferred, preferredProbe) = systemPip(true, executable: { $0 == "/a/pip3" || $0 == "/usr/bin/pip3" })
        precondition(preferred.path(for: .pip3) == "/a/pip3" && preferredProbe.asked == 0, "search directories win; xcode-select not asked")
        let (absent, absentProbe) = systemPip(true, executable: { _ in false })
        precondition(absent.path(for: .pip3) == nil && absentProbe.asked == 0, "no /usr/bin/pip3: xcode-select not asked")
        precondition(ToolLocator.xcodeSelect == "/usr/bin/xcode-select" && ToolLocator.systemPip3 == "/usr/bin/pip3")

        precondition(CleanupArgument.isUUID("A86E8B12-7CF0-4A69-B453-6DC989371771"))
        precondition(!CleanupArgument.isUUID("A86E8B12-7CF0-4A69-B453-6DC98937177;"))
        precondition(!CleanupArgument.isUUID("--all"))
        precondition(CleanupArgument.isModelName("llama3.1:70b"))
        precondition(CleanupArgument.isModelName("hf.co/bartowski/Qwen-7B:Q4_K_M"))
        for bad in ["", "-rf", "--help", "a b", "a;b", "模型", "$(id)", "a\nb"] {
            precondition(!CleanupArgument.isModelName(bad), "must reject \(bad)")
        }
        print("CommandRunnerTests passed")
    }
}
