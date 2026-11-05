// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct CodeRootStoreTests {
    static func main() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("roomy-selected-roots-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: temp, withIntermediateDirectories: true)
        let root = realpath(temp, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) }!
        defer { try? fm.removeItem(atPath: root) }
        let folder = root + "/Projects/Code With Spaces", nested = folder + "/client"
        try fm.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: root + "/settings/code-roots.json")
        let store = CodeRootStore(url: url, home: root)
        try store.add(paths: [nested])
        try store.add(paths: [nested])
        if fm.fileExists(atPath: nested.uppercased()) { try store.add(paths: [nested.uppercased()]) }
        let reopened = CodeRootStore(url: url, home: root)
        var regressions: [String] = []
        let saved = try reopened.records(); precondition(saved.map(\.path) == [nested], "manual selection must persist exactly, without broadening to its parent")
        let available = try reopened.availableRoots(); precondition(available == [nested])
        precondition(CodeRoots.configuration(store: reopened, automatic: []).roots == [nested], "next scan must see newly saved roots without app restart")
        if !CodeRoots.configuration(store: reopened, automatic: [root]).roots.contains(nested) {
            regressions.append("explicit nested scan start was collapsed beneath automatic parent")
        }
        for invalid in ["/", "/opt", root, "/System/Library", "/system/library", "/etc", "/private/etc", folder + "/missing"] {
            do {
                try store.add(paths: [invalid]); regressions.append("invalid root accepted: \(invalid)")
                for value in try store.records() where value.path != nested { try store.remove(path: value.path) }
            }
            catch { }
        }
        try fm.moveItem(atPath: nested, toPath: folder + "/old-client")
        try fm.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let replaced = try reopened.availableRoots(); precondition(replaced.isEmpty, "replaced directory identity must not silently become a configured scan root")
        let status = try reopened.statuses(); precondition(status[0].state == "changed")
        try reopened.remove(path: nested)
        let removed = try reopened.records(); precondition(removed.isEmpty, "removing a scan root changes configuration, never project data")
        precondition(fm.fileExists(atPath: nested))
        try Data("broken configuration".utf8).write(to: url)
        let scope = CodeRoots.configuration(store: reopened, automatic: [folder])
        precondition(scope.roots == [folder] && !scope.warnings.isEmpty, "corrupt configuration must be disclosed, not silently reported as a complete scan")
        do { _ = try reopened.records(); preconditionFailure("corrupt configuration accepted") } catch { }
        precondition(regressions.isEmpty, regressions.joined(separator: "; "))

        // 首次启动的选择：选过以后扫描范围只认选中的目录（可以为空），自动发现的只作候选
        let chosenURL = URL(fileURLWithPath: root + "/settings/chosen-roots.json")
        let picker = CodeRootStore(url: chosenURL, home: root)
        let pickedBefore = try picker.isChosen()
        precondition(!pickedBefore && CodeRoots.configuration(store: picker, automatic: [folder]).roots == [folder], "before a choice, automatic roots still count")
        precondition(CodeRoots.configuration(store: picker, automatic: [folder], includeAutomaticCandidates: false).roots == [folder],
                     "scan optimization cannot remove active automatic roots before the first choice")
        let other = root + "/Work"; try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        try picker.choose(paths: [other, other])
        var chosen = CodeRoots.configuration(store: CodeRootStore(url: chosenURL, home: root), automatic: [folder])
        precondition(chosen.chosen && chosen.roots == [other] && chosen.automatic == [folder], "the choice is the whole scope: \(chosen.roots)")
        let scanChoice=CodeRoots.configuration(store: picker,automatic:[folder],includeAutomaticCandidates:false)
        precondition(scanChoice.roots==chosen.roots && scanChoice.chosen==chosen.chosen && scanChoice.warnings==chosen.warnings,
                     "scan and picker must have identical selected scope and warnings")
        try picker.choose(paths: [])
        chosen = CodeRoots.configuration(store: picker, automatic: [folder])
        precondition(chosen.chosen && chosen.roots.isEmpty, "choosing nothing scans no code folders")
        try picker.add(paths: [nested])
        let keptAfterAdd = try picker.isChosen()
        precondition(keptAfterAdd && CodeRoots.configuration(store: picker, automatic: [folder]).roots == [nested], "later edits keep the choice")
        try picker.remove(path: nested)
        let keptAfterRemove = try picker.isChosen()
        precondition(keptAfterRemove, "removing the last folder keeps the choice")
        do { try picker.choose(paths: ["/System"]); preconditionFailure("invalid chosen root accepted") } catch { }
        let keptAfterReject = try picker.isChosen()
        precondition(keptAfterReject && CodeRoots.configuration(store: picker, automatic: [folder]).roots.isEmpty, "a rejected choice changes nothing")
        try Data("corrupt choice".utf8).write(to:chosenURL)
        let scanFallback=CodeRoots.configuration(store:picker,automatic:[folder],includeAutomaticCandidates:false)
        precondition(scanFallback.roots==[folder] && !scanFallback.warnings.isEmpty,
                     "corrupt configuration must retain the original automatic fallback and disclose the error")
        print("CodeRootStoreTests passed")
    }
}
