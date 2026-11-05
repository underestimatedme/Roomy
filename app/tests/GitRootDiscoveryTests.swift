// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

@main
struct GitRootDiscoveryTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("roomy-git-roots-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let home = realpath(temporary, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }!
        defer { try? fm.removeItem(atPath: home) }
        func write(_ relative: String, _ text: String) throws {
            let path = home + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        func repo(_ path: String) throws {
            try write(path + "/.git/HEAD", "ref: refs/heads/main\n")
            try write(path + "/.git/config", "[core]\nrepositoryformatversion = 0\n")
            try fm.createDirectory(atPath: home + "/" + path + "/.git/objects", withIntermediateDirectories: true)
        }
        try repo("UnusualWorkspace/team/project")
        try repo("Dependencies/node_modules/package")
        try repo("Documents/private-project")
        try write("NotCode/fake/.git/README", "not a repository")
        try write("Backing/metadata/worktrees/task/HEAD", "ref: refs/heads/task\n")
        try write("Backing/metadata/worktrees/task/commondir", "../..\n")
        try write("Backing/metadata/config", "[core]\nrepositoryformatversion = 0\n")
        try fm.createDirectory(atPath: home + "/Backing/metadata/objects", withIntermediateDirectories: true)
        try write("IndependentTasks/task/.git", "gitdir: ../../Backing/metadata/worktrees/task\n")
        try write("IndirectPrivate/task/.git", "gitdir: ../../Documents/private-project/.git\n")
        try fm.createSymbolicLink(atPath: home + "/LinkedWorkspace", withDestinationPath: home + "/UnusualWorkspace")
        let roots = CodeRoots.discover(home: home)
        precondition(roots.contains(home + "/UnusualWorkspace"), "Git-only users must not need Claude history or a known folder name")
        precondition(roots.contains(home + "/IndependentTasks"), "a linked worktree gitfile is a code workspace")
        for excluded in ["Dependencies", "Documents", "NotCode", "Backing", "LinkedWorkspace", "IndirectPrivate"] {
            precondition(!roots.contains(home + "/" + excluded), "not a discoverable working tree: \(excluded)")
        }
        let limited = GitRepositoryDiscovery.discover(searchRoots: [home], directoryLimit: 1)
        precondition(limited.incomplete && limited.visitedDirectories == 1, "budget cutoff must be reported without descending beyond the limit")
        var regressions: [String] = []
        if fm.fileExists(atPath: home + "/documents/private-project/.git/HEAD") {
            try write("CasePointer/task/.git", "gitdir: ../../documents/private-project/.git\n")
            try write("CaseCommon/task/.git", "gitdir: ../../Backing/metadata/worktrees/case\n")
            try write("Backing/metadata/worktrees/case/HEAD", "ref: refs/heads/main\n")
            try write("Backing/metadata/worktrees/case/commondir", "../../../../documents/private-project/.git\n")
            let caseRoots = CodeRoots.discover(home: home)
            if caseRoots.contains(home + "/CasePointer") || caseRoots.contains(home + "/CaseCommon") {
                regressions.append("case aliases of protected gitdir/commondir bypassed exclusions")
            }
        }
        try repo("FifoProject")
        try fm.removeItem(atPath: home + "/FifoProject/.git/HEAD")
        precondition(mkfifo(home + "/FifoProject/.git/HEAD", 0o600) == 0)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = GitRepositoryDiscovery.discover(searchRoots: [home + "/FifoProject"])
            completed.signal()
        }
        if completed.wait(timeout: .now() + 2) != .success { regressions.append("FIFO Git metadata hung discovery") }
        try repo("WideProject")
        for index in 0..<2100 { try write("WideProject/file\(index)", "x") }
        let wide = GitRepositoryDiscovery.discover(searchRoots: [home + "/WideProject"], secondsPerRoot: 10)
        if !wide.incomplete || !wide.repositories.isEmpty { regressions.append("oversized directory was fully read and trusted") }
        precondition(regressions.isEmpty, regressions.joined(separator: "; "))
        print("GitRootDiscoveryTests passed")
    }
}
