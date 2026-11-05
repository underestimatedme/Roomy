// SPDX-License-Identifier: MPL-2.0
import CoreServices
import Foundation
import Darwin

@main
struct LiveVolumeEventTrackerTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roomy-fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let start = UInt64(FSEventsGetCurrentEventId())
        // Root creation can arrive after the checkpoint; it is a valid event,
        // not HistoryDone. Check sentinel filtering independently of that race.
        precondition(VolumeEventTracker.change(path: root.path,
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)) == nil)
        let batch: EventBatch
        do { batch = try await VolumeEventTracker().changes(since: start, root: root) }
        catch VolumeEventTrackerError.streamStartFailed {
            print("SKIP: current host refuses FSEvents stream; cached fallback is covered separately")
            exit(77)
        }
        catch VolumeEventTrackerError.streamCreationFailed {
            print("SKIP: current host cannot create FSEvents stream; cached fallback is covered separately")
            exit(77)
        }
        precondition(batch.changes.allSatisfy {
            let event = URL(fileURLWithPath: $0.path).standardizedFileURL.path
            let expected = root.standardizedFileURL.path
            return event == expected || event.hasPrefix(expected + "/")
        }, "event collection must remain within the requested root")
        precondition(batch.endID >= start)
        print("live volume event tracker ok")
    }
}
