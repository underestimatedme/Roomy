// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@main struct AutomationStoreTests {
 static func main() throws {
  let root = URL(fileURLWithPath: "/private/tmp/roomy-automation-store-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = AutomationStore(directory: root)
  let initial = try store.read(); precondition(initial.paused)
  try store.update { $0.paused = false }
  let updated = try store.read(); precondition(!updated.paused)
  let now = Date()
  var rule = AutomationRule(title: "pause", days: nil, repeats: true, metric: .usedPercent, threshold: 90, mode: .confirm,
      scopes: [.init(kind: .appCache, path: "/tmp/cache", title: "cache")], volumeID: "fixture", now: now)
  let volume = AutomationVolume(id: "fixture", path: "/", total: 100, available: 9)
  var runtime = AutomationRuntime()
  let reasons = AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now)
  var pending = AutomationRun(ruleID: rule.id, revision: rule.revision, title: rule.title, createdAt: now, updatedAt: now, reasons: reasons)
  pending.status = .awaitingConfirmation; runtime.activeRunID = pending.id
  var database = AutomationDatabase(); database.rules = [rule]; database.runs = [pending]; database.runtimes[rule.id] = runtime
  database.invalidateRuns(ruleID: rule.id, message: "paused")
  rule.enabled = false; rule.revision += 1
  runtime = database.runtimes[rule.id]!; runtime.activeRunID = nil
  rule.enabled = true; rule.revision += 1
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now.addingTimeInterval(900)) == ["space"], "resume must restore unexecuted space event")
  pending.status = .running; pending.intentID = "uncertain"
  database.runs = [pending]; database.runtimes[rule.id] = runtime
  database.invalidateRuns(ruleID: rule.id, message: "paused")
  precondition(database.runtimes[rule.id]!.spaceLatched && database.runs[0].status == .needsAttention, "uncertain work must not be rearmed")
  pending.status = .completed; pending.intentID = nil
  database.runs = [pending]
  database.invalidateRuns(ruleID: rule.id, message: "paused")
  precondition(database.runtimes[rule.id]!.spaceLatched && database.runs[0].status == .completed, "completed work must stay consumed")
  let file = root.appendingPathComponent("automation.json")
  let original = try Data(contentsOf: file)
  try Data("{\"schema\":999}".utf8).write(to: file)
  do { _ = try store.read(); fatalError("unknown schema allowed") } catch {}
  try original.write(to: file)
  // A record written before the optional reminderOnly field existed must still decode and must not look like a reminder.
  let oldRunID = UUID().uuidString, oldToken = UUID().uuidString, stamp = now.timeIntervalSinceReferenceDate
  let oldJSON = """
  {"schema":1,"paused":false,"rules":[],"runtimes":{},"runs":[{"id":"\(oldRunID)","ruleID":"\(rule.id)","revision":1,"title":"旧记录","createdAt":\(stamp),"updatedAt":\(stamp),"status":"completed","reasons":["time"],"token":"\(oldToken)","items":[],"outcomes":[],"message":"","notified":true,"freedBytes":0}]}
  """
  try Data(oldJSON.utf8).write(to: file)
  let old = try store.read()
  precondition(old.runs.count == 1 && !old.runs[0].isReminder && old.runs[0].status == .completed, "old JSON without reminderOnly must still decode")
  precondition(old.runs[0].reasons == ["time"])
  try original.write(to: file)
  try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original"))
  try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("original"))
  do { _ = try store.read(); fatalError("symlink allowed") } catch {}
  print("AutomationStoreTests passed")
 }
}
