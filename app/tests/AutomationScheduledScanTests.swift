// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct AutomationScheduledScanTests {
 static func main() throws {
  let root = "/private/tmp/roomy-automation-scan-" + UUID().uuidString
  let fm = FileManager.default
  try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(atPath: root) }
  let now = Date()
  let volume = AutomationVolume(id: "fixture", path: root, total: 1_000_000_000, available: 500_000_000)
  // The JS test and the native test both read this file; neither side invents its own payload.
  // run-reliability.py copies this test into app/build/reliability-support/arm64, so #filePath
  // can point at the copy. Keep the same static fixture and try the original adjacent path,
  // then repo cwd (app/tests/fixtures), then app cwd (tests/fixtures).
  let fixtureCandidates = [
   URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("fixtures/automation-scan-request.json"),
   URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("app/tests/fixtures/automation-scan-request.json"),
   URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tests/fixtures/automation-scan-request.json")
  ]
  guard let fixtureURL = fixtureCandidates.first(where: { fm.fileExists(atPath: $0.path) }),
        let fixtureData = try? Data(contentsOf: fixtureURL),
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any] else {
   throw automationError("无法读取共享扫描请求 fixture")
  }
  let summary = AutomationScanSummary(scannedAt: now, itemCount: 3, actionableCount: 2,
   estimatedBytes: 4_000_000_000, warnings: [],
   preview: [AutomationScanSummary.Preview(title: "缓存", bytes: 3_000_000_000)])
  func save(_ store: AutomationStore, days: Int = 7, repeats: Bool = true, title: String = "定时扫描") throws -> AutomationRuleRequest.Saved {
   var args = fixture
   args["days"] = days
   args["repeats"] = repeats
   args["title"] = title
   return try AutomationRuleRequest.save(args: args, volume: volume, store: store, now: now)
  }
  // The static fixture is a valid request on its own, not just a dictionary the test can reshape.
  let contractStore = AutomationStore(directory: URL(fileURLWithPath: root + "/contract"))
  let contract = try AutomationRuleRequest.save(args: fixture, volume: volume, store: contractStore, now: now)
  precondition(contract.rule.isScanRule && contract.rule.days == 7 && contract.rule.scopes.isEmpty)
  precondition(contract.rule.title == "定时扫描" && contract.nextDue == now.addingTimeInterval(7*86400))
  // Real payload -> request -> store -> due tick -> summary -> notification -> next due.
  let store = AutomationStore(directory: URL(fileURLWithPath: root + "/state"))
  let saved = try save(store)
  var db = try store.read()
  precondition(db.paused, "saving a rule must not unpause the worker")
  precondition(db.rules.count == 1 && db.rules[0].isScanRule && db.rules[0].scopes.isEmpty)
  precondition(saved.nextDue == now.addingTimeInterval(7*86400) && saved.revision == 1)
  try store.update { db in db.paused = false; db.runtimes[saved.id]?.nextDue = now }
  var scans = 0, discovers = 0, performs = 0, notices = 0
  var env = AutomationEnvironment()
  env.volume = { volume }
  env.access = {}
  env.scan = { _ in scans += 1; return summary }
  env.discover = { _ in discovers += 1; return [] }
  env.perform = { snapshot, _ in performs += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  env.notify = { _ in notices += 1; return true }
  let worker = AutomationWorker(store: store, environment: env)
  try worker.tick(now: now)
  db = try store.read()
  precondition(scans == 1 && discovers == 0 && performs == 0)
  precondition(db.runs.count == 1)
  let run = db.runs[0]
  precondition(run.isScanOnly && run.status == .completed)
  precondition(run.items.isEmpty && run.outcomes.isEmpty && run.intentID == nil && run.freedBytes == 0)
  precondition(run.scanSummary == summary && run.notified && notices == 1)
  precondition(run.message.contains("估算") && run.message.contains("没有删除") && !run.message.contains("已释放"))
  precondition(db.rules[0].enabled)
  precondition(db.runtimes[saved.id]?.nextDue == now.addingTimeInterval(7*86400))
  // A scan record has no confirmation entry: refresh and approve must both fail.
  do { try worker.refresh(runID: run.id, now: now); fatalError("scan refreshed") } catch {}
  do { try worker.approve(runID: run.id, token: run.token, ids: ["x"], now: now); fatalError("scan approved") } catch {}
  precondition(discovers == 0 && performs == 0)
  // A schedule that is not due does not scan.
  let notDueStore = AutomationStore(directory: URL(fileURLWithPath: root + "/not-due"))
  let notDue = try save(notDueStore, title: "未到期")
  try notDueStore.update { db in db.paused = false; db.runtimes[notDue.id]?.nextDue = now.addingTimeInterval(3600) }
  var notDueScans = 0
  var notDueEnv = AutomationEnvironment()
  notDueEnv.volume = { volume }
  notDueEnv.access = {}
  notDueEnv.scan = { _ in notDueScans += 1; return summary }
  try AutomationWorker(store: notDueStore, environment: notDueEnv).tick(now: now)
  let notDueDB = try notDueStore.read()
  precondition(notDueScans == 0 && notDueDB.runs.isEmpty)
  // A single-run scan disables the rule after one completed scan.
  let onceStore = AutomationStore(directory: URL(fileURLWithPath: root + "/once"))
  let once = try save(onceStore, repeats: false, title: "单次扫描")
  try onceStore.update { db in db.paused = false; db.runtimes[once.id]?.nextDue = now }
  var onceScans = 0
  var onceEnv = AutomationEnvironment()
  onceEnv.volume = { volume }
  onceEnv.access = {}
  onceEnv.scan = { _ in onceScans += 1; return summary }
  try AutomationWorker(store: onceStore, environment: onceEnv).tick(now: now)
  let onceDB = try onceStore.read()
  precondition(onceScans == 1 && onceDB.runs[0].status == .completed)
  precondition(!onceDB.rules[0].enabled && onceDB.runtimes[once.id]?.nextDue == nil)
  // Permission denial never scans, never publishes a summary, and stays visible as attention.
  let deniedStore = AutomationStore(directory: URL(fileURLWithPath: root + "/denied"))
  let denied = try save(deniedStore, title: "许可拒绝")
  try deniedStore.update { db in db.paused = false; db.runtimes[denied.id]?.nextDue = now }
  var deniedScans = 0, deniedNotices = 0
  var deniedEnv = AutomationEnvironment()
  deniedEnv.volume = { volume }
  deniedEnv.access = { throw automationError("后台许可检查未通过") }
  deniedEnv.scan = { _ in deniedScans += 1; return summary }
  deniedEnv.notify = { _ in deniedNotices += 1; return true }
  try AutomationWorker(store: deniedStore, environment: deniedEnv).tick(now: now)
  let deniedDB = try deniedStore.read()
  precondition(deniedScans == 0)
  precondition(deniedDB.runs[0].status == .needsAttention && deniedDB.runs[0].message.contains("许可"))
  precondition(deniedDB.rules[0].enabled && deniedDB.runtimes[denied.id]?.blocker != nil)
  precondition(deniedNotices == 1)
  // A transient scan error retries under the existing policy; the retry publishes a real summary.
  let retryStore = AutomationStore(directory: URL(fileURLWithPath: root + "/retry"))
  let retry = try save(retryStore, title: "重试扫描")
  try retryStore.update { db in db.paused = false; db.runtimes[retry.id]?.nextDue = now }
  var attempts = 0, retryNotices = 0
  var retryEnv = AutomationEnvironment()
  retryEnv.volume = { volume }
  retryEnv.access = {}
  retryEnv.scan = { _ in
   attempts += 1
   if attempts == 1 { throw automationError("temporary scan timeout", transient: true) }
   return summary
  }
  retryEnv.notify = { _ in retryNotices += 1; return true }
  let retryWorker = AutomationWorker(store: retryStore, environment: retryEnv)
  try retryWorker.tick(now: now)
  var retryDB = try retryStore.read()
  precondition(attempts == 1 && retryDB.runs[0].status == .needsAttention)
  precondition(retryDB.runtimes[retry.id]?.retryAt == now.addingTimeInterval(1800))
  try retryWorker.tick(now: now.addingTimeInterval(1799))
  precondition(attempts == 1)
  try retryWorker.tick(now: now.addingTimeInterval(1800))
  retryDB = try retryStore.read()
  precondition(attempts == 2 && retryDB.runs.count == 2 && retryDB.runs[1].status == .completed)
  precondition(retryDB.rules[0].enabled && retryNotices == 2)
  // Editing the rule while the scan runs must not publish success.
  let editStore = AutomationStore(directory: URL(fileURLWithPath: root + "/edit"))
  let edit = try save(editStore, title: "编辑扫描")
  try editStore.update { db in db.paused = false; db.runtimes[edit.id]?.nextDue = now }
  var editScans = 0
  var editEnv = AutomationEnvironment()
  editEnv.volume = { volume }
  editEnv.access = {}
  editEnv.scan = { _ in
   editScans += 1
   try? editStore.update { db in
    db.rules[0].title = "edited"
    db.rules[0].revision += 1
    db.invalidateRuns(ruleID: db.rules[0].id, message: "规则已修改，旧的确认已失效")
   }
   return summary
  }
  try AutomationWorker(store: editStore, environment: editEnv).tick(now: now)
  let editDB = try editStore.read()
  precondition(editScans == 1 && editDB.runs[0].status == .skipped && editDB.runs[0].scanSummary == nil)
  // Pausing while the scan runs must not publish success either.
  let pauseStore = AutomationStore(directory: URL(fileURLWithPath: root + "/pause"))
  let pause = try save(pauseStore, title: "暂停扫描")
  try pauseStore.update { db in db.paused = false; db.runtimes[pause.id]?.nextDue = now }
  var pauseScans = 0, pauseNotices = 0
  var pauseEnv = AutomationEnvironment()
  pauseEnv.volume = { volume }
  pauseEnv.access = {}
  pauseEnv.scan = { _ in
   pauseScans += 1
   try? pauseStore.update { $0.paused = true }
   return summary
  }
  pauseEnv.notify = { _ in pauseNotices += 1; return true }
  try AutomationWorker(store: pauseStore, environment: pauseEnv).tick(now: now)
  let pauseDB = try pauseStore.read()
  precondition(pauseScans == 1 && pauseDB.paused)
  precondition(pauseDB.runs[0].status == .scanning && pauseDB.runs[0].scanSummary == nil)
  precondition(pauseNotices == 0)
  // A volume change while the scan runs must fail closed, not publish the old disk's summary.
  let changedStore = AutomationStore(directory: URL(fileURLWithPath: root + "/changed"))
  let changed = try save(changedStore, title: "换卷扫描")
  try changedStore.update { db in db.paused = false; db.runtimes[changed.id]?.nextDue = now }
  var current = volume
  var changedScans = 0
  var changedEnv = AutomationEnvironment()
  changedEnv.volume = { current }
  changedEnv.access = {}
  changedEnv.scan = { _ in
   changedScans += 1
   current = AutomationVolume(id: "other", path: root, total: 1_000_000_000, available: 500_000_000)
   return summary
  }
  try AutomationWorker(store: changedStore, environment: changedEnv).tick(now: now)
  let changedDB = try changedStore.read()
  precondition(changedScans == 1 && changedDB.runs[0].status == .needsAttention)
  precondition(changedDB.runs[0].message.contains("磁盘") && changedDB.runs[0].scanSummary == nil)
  precondition(changedDB.runtimes[changed.id]?.blocker != nil)
  // An invalid summary fails the run instead of turning it into a zero-byte success.
  let invalidStore = AutomationStore(directory: URL(fileURLWithPath: root + "/invalid"))
  let invalid = try save(invalidStore, title: "无效摘要")
  try invalidStore.update { db in db.paused = false; db.runtimes[invalid.id]?.nextDue = now }
  var invalidEnv = AutomationEnvironment()
  invalidEnv.volume = { volume }
  invalidEnv.access = {}
  invalidEnv.scan = { _ in
   AutomationScanSummary(scannedAt: now, itemCount: 1, actionableCount: 1, estimatedBytes: 1,
    warnings: [], preview: Array(repeating: AutomationScanSummary.Preview(title: "x", bytes: 1), count: 6))
  }
  try AutomationWorker(store: invalidStore, environment: invalidEnv).tick(now: now)
  let invalidDB = try invalidStore.read()
  precondition(invalidDB.runs[0].status == .needsAttention && invalidDB.runs[0].scanSummary == nil)
  precondition(invalidDB.runtimes[invalid.id]?.blocker != nil)
  // A legacy automatic rule keeps its data but never discovers, scans or performs.
  let legacyScope = AutomationScope(kind: .appCache, path: root + "/cache", title: "fixture")
  let legacyRule = AutomationRule(title: "旧自动清理", days: 1, repeats: true, metric: nil, threshold: nil,
   mode: .automatic, scopes: [legacyScope], volumeID: volume.id, now: now.addingTimeInterval(-86400))
  try legacyRule.validate()
  let legacyStore = AutomationStore(directory: URL(fileURLWithPath: root + "/legacy"))
  try legacyStore.update { db in
   db.paused = false; db.rules = [legacyRule]; db.runtimes[legacyRule.id] = AutomationRuntime(nextDue: now)
  }
  var legacyDiscovers = 0, legacyPerforms = 0, legacyScans = 0, legacyNotices = 0
  var legacyEnv = AutomationEnvironment()
  legacyEnv.volume = { volume }
  legacyEnv.access = {}
  legacyEnv.scan = { _ in legacyScans += 1; return summary }
  legacyEnv.discover = { _ in legacyDiscovers += 1; return [] }
  legacyEnv.perform = { snapshot, _ in legacyPerforms += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  legacyEnv.notify = { _ in legacyNotices += 1; return true }
  try AutomationWorker(store: legacyStore, environment: legacyEnv).tick(now: now)
  let legacyDB = try legacyStore.read()
  precondition(legacyDB.runs.count == 1 && legacyDB.runs[0].status == .needsAttention)
  precondition(legacyDB.runs[0].message == "旧自动清理已暂停，请新建定时扫描规则")
  precondition(legacyScans == 0 && legacyDiscovers == 0 && legacyPerforms == 0)
  precondition(legacyDB.rules[0].enabled && legacyDB.runtimes[legacyRule.id]?.blocker != nil)
  precondition(legacyNotices == 1)
  print("AutomationScheduledScanTests passed")
 }
}
