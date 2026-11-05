// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct IncrementalScanPlannerTests {
    static func main() {
        let volumeID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let metadata = SnapshotMetadata(
            volumeUUID: volumeID, rootDeviceID: 42, filesystem: "apfs",
            osVersion: "26.0", permissionScope: "user", lastEventID: 40,
            completedAt: Date(timeIntervalSince1970: 1), schemaVersion: SnapshotFormat.schema
        )
        let sameVolume = VolumeIdentity(
            uuid: volumeID, deviceID: 42, filesystem: "apfs", permissionScope: "user"
        )
        let planner = IncrementalScanPlanner()

        precondition(planner.plan(snapshot: metadata, volume: sameVolume,
            events: EventBatch(changes: [], endID: 44)) == .reuse)
        let deniedMetadata = SnapshotMetadata(
            volumeUUID: volumeID, rootDeviceID: 42, filesystem: "apfs",
            osVersion: "26.0", permissionScope: "user", lastEventID: 40,
            completedAt: Date(), diagnostics: [
                ScanDiagnostic(path: "/Users/private", kind: .permissionDenied, errorNumber: 13)
            ])
        precondition(planner.plan(snapshot: deniedMetadata, volume: sameVolume,
            events: EventBatch(changes: [], endID: 44)) == .incremental(["/Users/private"]))
        let ordinary = EventBatch(changes: [
            VolumeChange(path: "/Users/a", flags: [.itemModified]),
            VolumeChange(path: "/Users/b", flags: [.itemRemoved])
        ], endID: 44)
        precondition(planner.plan(snapshot: metadata, volume: sameVolume, events: ordinary)
            == .incremental(["/Users/a", "/Users/b"]))

        let wrongSchema = SnapshotMetadata(
            volumeUUID: volumeID, rootDeviceID: 42, filesystem: "apfs",
            osVersion: "26.0", permissionScope: "user", lastEventID: 40,
            completedAt: Date(timeIntervalSince1970: 1), schemaVersion: SnapshotFormat.schema + 1
        )
        precondition(planner.plan(snapshot: wrongSchema, volume: sameVolume, events: ordinary)
            == .full(.schemaMismatch))

        let replacement = VolumeIdentity(
            uuid: UUID(), deviceID: 42, filesystem: "apfs", permissionScope: "user"
        )
        precondition(planner.plan(snapshot: metadata, volume: replacement, events: ordinary)
            == .full(.volumeChanged))
        precondition(planner.plan(snapshot: metadata, volume: sameVolume,
            events: EventBatch(changes: [], endID: 39)) == .full(.eventHistoryLost))
        precondition(planner.plan(snapshot: metadata, volume: sameVolume,
            events: EventBatch(changes: [], endID: 44, historyAvailable: false))
            == .full(.eventHistoryLost))

        for flags: VolumeChangeFlags in [.mustScanSubdirectories, .eventIDsWrapped] {
            let batch = EventBatch(changes: [VolumeChange(path: "/Users/a", flags: flags)], endID: 44)
            precondition(planner.plan(snapshot: metadata, volume: sameVolume, events: batch)
                == .full(.eventHistoryLost))
        }
        let rootChanged = EventBatch(changes: [
            VolumeChange(path: "/Users", flags: [.rootChanged]),
            VolumeChange(path: "/Users/a", flags: [.itemModified])
        ], endID: 44)
        precondition(planner.plan(snapshot: metadata, volume: sameVolume, events: rootChanged)
            == .full(.rootChanged))

        print("incremental planner ok")
    }
}
