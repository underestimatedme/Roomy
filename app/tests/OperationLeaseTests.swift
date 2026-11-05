// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct OperationLeaseTests {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--lock-child" {
            do { _ = try OperationLease.acquire(path: CommandLine.arguments[2]); exit(0) }
            catch { exit(23) }
        }
        let sample = "/private/tmp/roomy-lease-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: sample, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sample) }
        let path = sample + "/operation.lock"
        var first: OperationLease? = try OperationLease.acquire(path: path)
        let child = ProcessRunner().run(CommandLine.arguments[0], ["--lock-child", path], timeout: 5)
        guard child.status == 23 else { fatalError("another process must refuse overlapping mutations") }
        first = nil
        _ = first
        let second = try OperationLease.acquire(path: path)
        withExtendedLifetime(second) {}
        let link = sample + "/linked.lock"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        do { _ = try OperationLease.acquire(path: link); fatalError("symlink lock must be refused") }
        catch {}
        print("operation lease ok")
    }
}
