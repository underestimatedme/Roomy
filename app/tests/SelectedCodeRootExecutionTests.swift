// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct SelectedCodeRootExecutionTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("roomy-root-execution-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temp, withIntermediateDirectories: true)
        let root = realpath(temp, nil).map { p in defer { free(p) }; return String(cString: p) }!
        defer { try? fm.removeItem(atPath: root) }
        let project = root + "/project", artifact = project + "/generated"
        try fm.createDirectory(atPath: artifact, withIntermediateDirectories: true)
        let identity = CleanupIdentity.capture(path: project)!
        let record = SavedCodeRoot(path: project, deviceID: identity.deviceID, fileID: identity.fileID)
        let item = ScanItem.trashTarget(path: artifact, name: "fixture", size: 4096,
            rule: "fixture", evidence: "already eligible test target", risk: .amber)
        let candidate = CleanupListBuilder.fromRule(item), list = CleanupList(candidates: [candidate])
        var moved = false, env = CleanupEnvironment(); env.roots = [project]; env.selectedCodeRoots = []
        env.trash = { _ in moved = true; return nil }; env.diskFree = { 0 }
        precondition(!CleanupRunner.run(ids: [candidate.entry.id], list: list, env: env, progress: { _ in }).outcomes[0].ok,
            "ordinary roots retain their original shallow-path guard")
        env.selectedCodeRoots = [record]
        precondition(CleanupRunner.run(ids: [candidate.entry.id], list: list, env: env, progress: { _ in }).outcomes[0].ok && moved,
            "a user-selected exact root must support an already-authorized immediate child")
        moved = false
        env.roots = [(root as NSString).deletingLastPathComponent, project]
        let rootItem = ScanItem.trashTarget(path: project, name: "selected root", size: 4096,
            rule: "fixture", evidence: "fixture", risk: .amber)
        let rootCandidate = CleanupListBuilder.fromRule(rootItem)
        let rootResult = CleanupRunner.run(ids: [rootCandidate.entry.id], list: CleanupList(candidates: [rootCandidate]), env: env, progress: { _ in })
        precondition(!rootResult.outcomes[0].ok && !moved, "an ancestor scope must not authorize deleting the selected scan root itself")
        env.roots = [project]
        moved = false
        try fm.moveItem(atPath: project, toPath: root + "/old-project")
        try fm.createDirectory(atPath: project, withIntermediateDirectories: true)
        try fm.moveItem(atPath: root + "/old-project/generated", toPath: artifact)
        let result = CleanupRunner.run(ids: [candidate.entry.id], list: list, env: env, progress: { _ in })
        precondition(!result.outcomes[0].ok && !moved, "replacing the selected root must block even when the child inode still matches")
        print("SelectedCodeRootExecutionTests passed")
    }
}
