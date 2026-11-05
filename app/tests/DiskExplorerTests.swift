// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private func expect(_ condition: Bool) { precondition(condition) }

@main struct DiskExplorerTests {
    static func main() throws {
        var index = ScanIndex(rootPath: "/sample")
        index.append(parentID: 0, fileID: 1, deviceID: 1, name: "sample", kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        index.append(parentID: 0, fileID: 2, deviceID: 1, name: "Projects", kind: .directory, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        index.append(parentID: 1, fileID: 3, deviceID: 1, name: "large.mov", kind: .file, logicalSize: 8192, allocatedSize: 8192, modifiedAt: 1, flags: [])
        index.append(parentID: 0, fileID: 3, deviceID: 1, name: "hardlink.mov", kind: .file, logicalSize: 8192, allocatedSize: 0, modifiedAt: 1, flags: [], physicalAllocatedSize: 8192)
        index.append(parentID: 0, fileID: 4, deviceID: 1, name: "link", kind: .symbolicLink, logicalSize: 0, allocatedSize: 0, modifiedAt: 1, flags: [])
        index.finalizeAggregates()
        let explorer = DiskExplorer(index: index, diagnostics: [ScanDiagnostic(path: "/sample/Projects/private", kind: .permissionDenied, errorNumber: 13)])
        let root = try explorer.page(id: "0")
        expect(root.size == 8192 && root.total == 3)
        expect(root.items[0].name == "Projects" && root.items[0].incomplete)
        let project = try explorer.page(id: "1")
        expect(project.breadcrumbs.map(\.id) == ["0", "1"] && project.items[0].path == "/sample/Projects/large.mov")
        let search = try explorer.page(id: "0", query: "PROJECTS LARGE", filesOnly: true)
        expect(search.total == 1 && search.items[0].id == "2")
        let large = try explorer.page(id: "0", filesOnly: true, minBytes: 4096)
        expect(large.total == 1 && large.items[0].name == "large.mov")
        let next = try explorer.page(id: "0", offset: 1, limit: 1)
        expect(next.total == 3 && next.items.count == 1 && next.offset == 1)
        do { _ = try explorer.page(id: "999"); preconditionFailure("unknown ID") } catch { }
        do { _ = try explorer.page(id: "2"); preconditionFailure("files cannot be browsed as folders") } catch { }
        print("DiskExplorerTests passed")
    }
}
