// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main
struct ScanTypesTests {
    static func main() throws {
        let flags: EntryFlags = [.package, .mayShareContent]
        let entry = ScanEntry(
            id: 7,
            parentID: 2,
            fileID: 91,
            deviceID: 3,
            nameID: 4,
            kind: .file,
            logicalSize: 12,
            allocatedSize: 4096,
            modifiedAt: 100,
            flags: flags
        )

        let data = try JSONEncoder().encode(entry)
        let copy = try JSONDecoder().decode(ScanEntry.self, from: data)

        precondition(copy == entry)
        precondition(copy.identity == FileIdentity(deviceID: 3, fileID: 91))
        precondition(copy.flags.contains(.package))
        precondition(copy.flags.contains(.mayShareContent))
        print("scan types ok")
    }
}
