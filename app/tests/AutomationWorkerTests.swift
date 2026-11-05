// SPDX-License-Identifier: MPL-2.0
import Foundation
@main struct AutomationWorkerTests {
 static func main() throws {
  let root = "/private/tmp/roomy-automation-worker-" + UUID().uuidString
  let fm = FileManager.default
  try fm.createDirectory(atPath: root + "/cache", withIntermediateDirectories: true)
  defer { try? fm.removeItem(atPath: root) }
  try Data("old".utf8).write(to: URL(fileURLWithPath: root + "/cache/a"))
  let now = Date()
  let scope = AutomationScope(kind: .appCache, path: root + "/cache", title: "fixture")
  let rule = AutomationRule(title: "fixture", days: 1, repeats: true, metric: nil, threshold: nil, mode: .confirm, scopes: [scope], volumeID: "fixture", now: now.addingTimeInterval(-86400))
  let store = AutomationStore(directory: URL(fileURLWithPath: root + "/state"))
  try store.update { db in db.paused = false; db.rules = [rule]; db.runtimes[rule.id] = AutomationRuntime(nextDue: now) }
  var actions = 0
  var env = AutomationEnvironment()
  env.volume = { AutomationVolume(id: "fixture", path: root, total: 100, available: 50) }
  env.access = {}
  env.discover = { _ in
   let item = ScanItem.trashTarget(path: scope.path, name: "fixture", size: 3, rule: "应用可重建缓存", evidence: "fixture", risk: .amber)
   return [CleanupCandidate(source: "appcache", key: scope.path, title: "fixture", size: 3, evidence: "fixture", risk: .amber, action: .trash(item: item))]
  }
  env.perform = { snapshot, _ in actions += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "fixture blocked action", bytes: 0) }
  let worker = AutomationWorker(store: store, environment: env)
  try worker.tick(now: now)
  var db = try store.read()
  precondition(actions == 0 && db.runs.count == 1 && db.runs[0].status == .awaitingConfirmation)
  try worker.tick(now: now.addingTimeInterval(900))
  db = try store.read(); precondition(db.runs.count == 1)
  let run = db.runs[0]
  try Data("changed".utf8).write(to: URL(fileURLWithPath: root + "/cache/a"))
  do { try worker.approve(runID: run.id, token: run.token, ids: run.items.map(\.id), now: now); fatalError("stale content approved") } catch {}
  precondition(actions == 0)
  try worker.refresh(runID: run.id, now: now)
  let fresh = try store.read().runs[0]
  precondition(fresh.token != run.token)
  try worker.approve(runID: fresh.id, token: fresh.token, ids: fresh.items.map(\.id), now: now)
  precondition(actions == 1)
  // A legacy automatic rule is blocked before any discover or perform. Its rule and history stay visible.
  try store.update { db in
   db.rules[0].mode = .automatic
   db.runtimes[rule.id] = AutomationRuntime(nextDue: now)
  }
  try worker.tick(now: now)
  db = try store.read()
  precondition(actions == 1, "legacy automatic rule must not perform")
  precondition(db.runs.last?.status == .needsAttention)
  precondition(db.runs.last?.message == "旧自动清理已暂停，请新建定时扫描规则")
  precondition(db.rules[0].enabled && db.runtimes[rule.id]?.blocker != nil)
  try store.update { $0.paused = true }
  try worker.tick(now: now.addingTimeInterval(2*86400))
  precondition(actions == 1)
  // Manual confirm keeps the busy-operation coverage: a held deletion lease rejects approval, and the same
  // plan can be approved after the lease is released. A background tick never prepares or executes it.
  try store.update { db in
   db.paused = false
   db.rules[0].mode = .confirm
   db.runtimes[rule.id] = AutomationRuntime(nextDue: now)
  }
  try worker.tick(now: now)
  db = try store.read()
  precondition(db.runs.last?.status == .awaitingConfirmation && actions == 1)
  let planned = db.runs.last!
  do {
   let lease = try OperationLease.acquire(path: root + "/state/operation.lock")
   try withExtendedLifetime(lease) {
    do {
     try worker.approve(runID: planned.id, token: planned.token, ids: planned.items.map(\.id), now: now)
     fatalError("busy operation must reject approval")
    } catch {}
   }
  }
  precondition(actions == 1, "busy lease must not perform")
  try worker.approve(runID: planned.id, token: planned.token, ids: planned.items.map(\.id), now: now)
  precondition(actions == 2, "manual approval should execute after lease is released")
  // Crash recovery never repeats an operation whose outcome is unknown.
  try store.update { db in
   db.runtimes[rule.id] = AutomationRuntime(nextDue: now)
   var interrupted = AutomationRun(ruleID: rule.id, revision: rule.revision, title: rule.title, createdAt: now, updatedAt: now, reasons: ["time"])
   interrupted.status = .skipped; interrupted.intentID = "unknown"
   db.runs.append(interrupted); db.runtimes[rule.id]?.activeRunID = interrupted.id
  }
  try worker.tick(now: now)
  precondition(actions == 2)
  let uncertain = try store.read()
  precondition(uncertain.runtimes[rule.id]?.blocker != nil)
  // Pre-action failures preserve due work; transient errors use bounded retries.
  let retryStore = AutomationStore(directory: URL(fileURLWithPath: root + "/retry-state"))
  var once = rule; once.repeats = false; once.mode = .confirm; once.days = 1; once.metric = nil; once.threshold = nil
  try retryStore.update { db in db.paused = false; db.rules = [once]; db.runtimes[once.id] = AutomationRuntime(nextDue: now) }
  var retryEnv = env
  var attempts = 0
  let originalDiscovery = env.discover
  retryEnv.discover = { rule in
   attempts += 1
   if attempts == 1 { throw NSError(domain: "RoomyAutomation", code: 2, userInfo: [NSLocalizedDescriptionKey: "temporary scan timeout"]) }
   return try originalDiscovery(rule)
  }
  retryEnv.perform = { snapshot, _ in CleanupOutcome(id: snapshot.id, ok: false, message: "fixture blocked action", bytes: 0) }
  let retryWorker = AutomationWorker(store: retryStore, environment: retryEnv)
  try retryWorker.tick(now: now)
  let failed = try retryStore.read()
  precondition(failed.rules[0].enabled && failed.runtimes[once.id]?.blocker == nil, "transient error must preserve enabled rule")
  precondition(failed.runtimes[once.id]?.retryAt == now.addingTimeInterval(1800))
  try retryWorker.tick(now: now.addingTimeInterval(1799))
  precondition(attempts == 1)
  try retryWorker.tick(now: now.addingTimeInterval(1800))
  var retried = try retryStore.read()
  precondition(attempts == 2 && retried.rules[0].enabled)
  let recoveredPlan = retried.runs.last!
  precondition(recoveredPlan.status == .awaitingConfirmation)
  // Explicit manual confirmation preserves the retry path and finishes the single-run rule.
  try retryWorker.approve(runID: recoveredPlan.id, token: recoveredPlan.token, ids: recoveredPlan.items.map(\.id), now: now.addingTimeInterval(1800))
  retried = try retryStore.read()
  precondition(attempts == 3 && !retried.rules[0].enabled, "manual approval must finish the recovered plan")
  let permissionStore = AutomationStore(directory: URL(fileURLWithPath: root + "/permission-state"))
  try permissionStore.update { db in db.paused = false; db.rules = [rule]; db.runtimes[rule.id] = AutomationRuntime(nextDue: now) }
  retryEnv.discover = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
  var notices = 0; retryEnv.notify = { _ in notices += 1; return true }
  try AutomationWorker(store: permissionStore, environment: retryEnv).tick(now: now)
  let denied = try permissionStore.read()
  precondition(denied.rules[0].enabled && denied.runtimes[rule.id]?.nextDue == now && denied.runtimes[rule.id]?.blocker != nil)
  precondition(denied.runs[0].status == .needsAttention && notices == 1)
  // Capacity never authorizes cleanup: reminder only, with no discover and no perform.
  let spaceStore = AutomationStore(directory: URL(fileURLWithPath: root + "/space-state"))
  let capacity = AutomationRule(title: "低空间提醒", days: nil, repeats: true, metric: .availableGB, threshold: 20, mode: .confirm, scopes: [], volumeID: "fixture", now: now.addingTimeInterval(-3600))
  try capacity.validate()
  try spaceStore.update { db in db.paused = false; db.rules = [capacity]; db.runtimes[capacity.id] = AutomationRuntime() }
  var spaceDiscover = 0, spacePerform = 0, spaceNotices = 0
  var spaceEnv = AutomationEnvironment()
  var low = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000)
  spaceEnv.volume = { low }
  spaceEnv.access = {}
  spaceEnv.discover = { _ in spaceDiscover += 1; return [] }
  spaceEnv.perform = { snapshot, _ in spacePerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  spaceEnv.notify = { _ in spaceNotices += 1; return true }
  let spaceWorker = AutomationWorker(store: spaceStore, environment: spaceEnv)
  try spaceWorker.tick(now: now)
  var spaceDB = try spaceStore.read()
  precondition(spaceDB.runs.count == 1 && spaceDB.runs[0].isReminder && spaceDB.runs[0].status == .completed)
  precondition(spaceDiscover == 0 && spacePerform == 0, "capacity must not discover or perform")
  precondition(spaceDB.runs[0].outcomes.isEmpty && spaceNotices == 1 && spaceDB.runs[0].notified)
  precondition(spaceDB.runs[0].message.contains("19.0 GB") && spaceDB.runs[0].message.contains("20.0 GB"))
  precondition(!spaceDB.runs[0].message.contains("清理完成") && !spaceDB.runs[0].message.contains("移入"))
  // Persistent low space must not notify every 15 minutes.
  try spaceWorker.tick(now: now.addingTimeInterval(900))
  let cooled = try spaceStore.read()
  precondition(cooled.runs.count == 1 && spaceNotices == 1, "cooldown must stop reminder spam")
  // Recovery clears the latch; a new crossing reminds again.
  low = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 400_000_000_000)
  try spaceWorker.tick(now: now.addingTimeInterval(86401))
  try spaceWorker.tick(now: now.addingTimeInterval(87301))
  low = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000)
  try spaceWorker.tick(now: now.addingTimeInterval(2*86400))
  spaceDB = try spaceStore.read()
  precondition(spaceDB.runs.count == 2 && spaceNotices == 2, "recovery then a new crossing must remind again")
  precondition(spaceDiscover == 0 && spacePerform == 0)
  // The permission check can outlast the low-capacity reading: re-read the volume afterwards and never send
  // "100 GB is below 20 GB". A recovered disk records a skip without notify, discover or perform.
  let recoveredStore = AutomationStore(directory: URL(fileURLWithPath: root + "/space-recovered-state"))
  try recoveredStore.update { db in db.paused = false; db.rules = [capacity]; db.runtimes[capacity.id] = AutomationRuntime() }
  var recoveredVolume: AutomationVolume? = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000)
  var recoveredDiscover = 0, recoveredPerform = 0, recoveredNotices = 0
  var recoveredEnv = AutomationEnvironment()
  recoveredEnv.volume = { recoveredVolume }
  recoveredEnv.access = { recoveredVolume = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 100_000_000_000) }
  recoveredEnv.discover = { _ in recoveredDiscover += 1; return [] }
  recoveredEnv.perform = { snapshot, _ in recoveredPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  recoveredEnv.notify = { _ in recoveredNotices += 1; return true }
  try AutomationWorker(store: recoveredStore, environment: recoveredEnv).tick(now: now)
  let recovered = try recoveredStore.read()
  precondition(recovered.runs.count == 1 && recovered.runs[0].status == .skipped && recovered.runs[0].isReminder)
  precondition(recovered.runs[0].message.contains("已恢复") && !recovered.runs[0].message.contains("低于"),
   "a recovered disk must not keep the old low-capacity wording")
  precondition(recoveredNotices == 0 && recoveredDiscover == 0 && recoveredPerform == 0,
   "a disk that recovered during access must not remind, discover or perform")
  // An unreadable volume is unknown, never 0 GB: fail closed with the existing policy and send nothing.
  let unknownStore = AutomationStore(directory: URL(fileURLWithPath: root + "/space-unknown-state"))
  try unknownStore.update { db in db.paused = false; db.rules = [capacity]; db.runtimes[capacity.id] = AutomationRuntime() }
  var unknownVolume: AutomationVolume? = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000)
  var unknownDiscover = 0, unknownPerform = 0, unknownNotices = 0
  var unknownEnv = AutomationEnvironment()
  unknownEnv.volume = { unknownVolume }
  unknownEnv.access = { unknownVolume = nil }
  unknownEnv.discover = { _ in unknownDiscover += 1; return [] }
  unknownEnv.perform = { snapshot, _ in unknownPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  unknownEnv.notify = { _ in unknownNotices += 1; return true }
  try AutomationWorker(store: unknownStore, environment: unknownEnv).tick(now: now)
  let unknown = try unknownStore.read()
  precondition(unknown.runs.count == 1 && unknown.runs[0].status == .needsAttention)
  precondition(unknown.runs[0].message.contains("无法读取") && !unknown.runs[0].message.contains("0.0 GB"),
   "an unreadable volume must not be reported as zero capacity")
  precondition(unknown.runtimes[capacity.id]?.blocker != nil)
  precondition(unknownNotices == 0 && unknownDiscover == 0 && unknownPerform == 0)
  // A different volume id is equally unknown; it must not inherit the old low-capacity numbers.
  let changedStore = AutomationStore(directory: URL(fileURLWithPath: root + "/space-changed-state"))
  try changedStore.update { db in db.paused = false; db.rules = [capacity]; db.runtimes[capacity.id] = AutomationRuntime() }
  var changedVolume: AutomationVolume? = AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000)
  var changedDiscover = 0, changedPerform = 0, changedNotices = 0
  var changedEnv = AutomationEnvironment()
  changedEnv.volume = { changedVolume }
  changedEnv.access = { changedVolume?.id = "other-volume" }
  changedEnv.discover = { _ in changedDiscover += 1; return [] }
  changedEnv.perform = { snapshot, _ in changedPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  changedEnv.notify = { _ in changedNotices += 1; return true }
  try AutomationWorker(store: changedStore, environment: changedEnv).tick(now: now)
  let changed = try changedStore.read()
  precondition(changed.runs.count == 1 && changed.runs[0].status == .needsAttention)
  precondition(changed.runs[0].message.contains("身份") && !changed.runs[0].message.contains("低于"))
  precondition(changed.runtimes[capacity.id]?.blocker != nil)
  precondition(changedNotices == 0 && changedDiscover == 0 && changedPerform == 0)
  // A normal low reading still sends exactly one reminder with the real numbers.
  precondition(spaceDB.runs[0].message.contains("19.0 GB") && spaceNotices == 2)
  // Pausing during the permission check must not turn a claimed capacity event into a completed reminder.
  let pauseStore = AutomationStore(directory: URL(fileURLWithPath: root + "/pause-space-state"))
  try pauseStore.update { db in db.paused = false; db.rules = [capacity]; db.runtimes[capacity.id] = AutomationRuntime() }
  var pauseDiscover = 0, pausePerform = 0, pauseNotices = 0
  var pauseEnv = AutomationEnvironment()
  pauseEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000) }
  pauseEnv.access = { try pauseStore.update { $0.paused = true } }
  pauseEnv.discover = { _ in pauseDiscover += 1; return [] }
  pauseEnv.perform = { snapshot, _ in pausePerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  pauseEnv.notify = { _ in pauseNotices += 1; return true }
  let pauseWorker = AutomationWorker(store: pauseStore, environment: pauseEnv)
  try pauseWorker.tick(now: now)
  var pauseDB = try pauseStore.read()
  precondition(pauseDB.paused)
  precondition(pauseDB.runs.count == 1 && pauseDB.runs[0].status == .scanning && !pauseDB.runs[0].isReminder)
  precondition(pauseDB.runs[0].intentID == nil && pauseDB.runs[0].outcomes.isEmpty && !pauseDB.runs[0].notified)
  precondition(pauseNotices == 0 && pauseDiscover == 0 && pausePerform == 0, "paused rule must not remind, discover or perform")
  // Resuming keeps the claimed event: the reminder is delivered without scanning anything.
  pauseWorker.environment.access = {}
  try pauseStore.update { $0.paused = false }
  try pauseWorker.tick(now: now.addingTimeInterval(900))
  pauseDB = try pauseStore.read()
  precondition(pauseDB.runs.count == 1 && pauseDB.runs[0].isReminder && pauseDB.runs[0].status == .completed)
  precondition(pauseNotices == 1 && pauseDiscover == 0 && pausePerform == 0, "resumed reminder must notify without scanning")
  // An old scanning space run that already holds an intent is surfaced for review, never rewritten as a reminder.
  let intentStore = AutomationStore(directory: URL(fileURLWithPath: root + "/legacy-intent-state"))
  var interruptedSpace = AutomationRun(ruleID: capacity.id, revision: capacity.revision, title: capacity.title, createdAt: now, updatedAt: now, reasons: ["space"])
  interruptedSpace.status = .scanning
  interruptedSpace.intentID = "legacy-item"
  interruptedSpace.outcomes = [CleanupOutcome(id: "legacy-item", ok: false, message: "legacy partial result", bytes: 0)]
  try intentStore.update { db in
   db.paused = false; db.rules = [capacity]; db.runs = [interruptedSpace]
   db.runtimes[capacity.id] = AutomationRuntime(activeRunID: interruptedSpace.id)
  }
  var intentEnv = AutomationEnvironment()
  intentEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000) }
  intentEnv.access = {}
  try AutomationWorker(store: intentStore, environment: intentEnv).tick(now: now)
  let intentDB = try intentStore.read()
  precondition(intentDB.runs[0].outcomes.count == 1 && !intentDB.runs[0].isReminder, "uncertain legacy run must keep its results")
  precondition(intentDB.runs[0].status == .needsAttention && intentDB.runtimes[capacity.id]?.blocker != nil)
  // Existing results without an intent stay visible in the scanning state instead of being hidden.
  let staleStore = AutomationStore(directory: URL(fileURLWithPath: root + "/legacy-result-state"))
  var staleRun = AutomationRun(ruleID: capacity.id, revision: capacity.revision, title: capacity.title, createdAt: now, updatedAt: now, reasons: ["space"])
  staleRun.status = .scanning
  staleRun.outcomes = [CleanupOutcome(id: "legacy-item", ok: false, message: "legacy partial result", bytes: 0)]
  try staleStore.update { db in
   db.paused = false; db.rules = [capacity]; db.runs = [staleRun]
   db.runtimes[capacity.id] = AutomationRuntime(activeRunID: staleRun.id)
  }
  var staleDiscover = 0, stalePerform = 0, staleNotices = 0
  var staleEnv = AutomationEnvironment()
  staleEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 500_000_000_000, available: 19_000_000_000) }
  staleEnv.access = {}
  staleEnv.discover = { _ in staleDiscover += 1; return [] }
  staleEnv.perform = { snapshot, _ in stalePerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  staleEnv.notify = { _ in staleNotices += 1; return true }
  try AutomationWorker(store: staleStore, environment: staleEnv).tick(now: now)
  let staleDB = try staleStore.read()
  precondition(staleDB.runs[0].status == .scanning && !staleDB.runs[0].isReminder)
  precondition(staleDB.runs[0].outcomes.count == 1 && staleDB.runs[0].outcomes[0].message == "legacy partial result")
  precondition(staleNotices == 0 && staleDiscover == 0 && stalePerform == 0, "existing results must stay visible and untouched")
  // Legacy OR rules (time AND capacity, automatic) also only remind, even with zero candidates.
  let legacyStore = AutomationStore(directory: URL(fileURLWithPath: root + "/legacy-space-state"))
  let legacyRule = AutomationRule(title: "旧组合规则", days: 1, repeats: true, metric: .usedPercent, threshold: 40, mode: .automatic, scopes: [scope], volumeID: "fixture", now: now.addingTimeInterval(-86400))
  try legacyStore.update { db in db.paused = false; db.rules = [legacyRule]; db.runtimes[legacyRule.id] = AutomationRuntime(nextDue: now) }
  var legacyDiscover = 0, legacyPerform = 0, legacyNotices = 0
  var legacyEnv = AutomationEnvironment()
  legacyEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 100, available: 50) }
  legacyEnv.access = {}
  legacyEnv.discover = { _ in legacyDiscover += 1; return [] }
  legacyEnv.perform = { snapshot, _ in legacyPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  legacyEnv.notify = { _ in legacyNotices += 1; return false }
  try AutomationWorker(store: legacyStore, environment: legacyEnv).tick(now: now)
  var legacyDB = try legacyStore.read()
  precondition(legacyDB.runs.count == 1 && legacyDB.runs[0].isReminder && legacyDB.runs[0].status == .completed)
  precondition(legacyDB.runs[0].reasons.contains("time") && legacyDB.runs[0].reasons.contains("space"))
  precondition(legacyDiscover == 0 && legacyPerform == 0, "legacy OR rule must not discover or perform")
  precondition(legacyDB.runs[0].outcomes.isEmpty && legacyDB.rules[0].enabled)
  // A failed notification keeps the in-app reminder instead of dropping it.
  precondition(!legacyDB.runs[0].notified && legacyNotices == 1 && !legacyDB.runs[0].message.isEmpty)
  // An old automatic time-or-capacity rule whose only real trigger is capacity still only reminds,
  // even with an empty candidate list: nothing is discovered, prepared or performed.
  let spaceOnlyStore = AutomationStore(directory: URL(fileURLWithPath: root + "/legacy-space-only-state"))
  let spaceOnlyRule = AutomationRule(title: "旧组合只碰容量", days: 30, repeats: true, metric: .usedPercent, threshold: 40, mode: .automatic, scopes: [scope], volumeID: "fixture", now: now.addingTimeInterval(-86400))
  try spaceOnlyStore.update { db in
   db.paused = false; db.rules = [spaceOnlyRule]
   db.runtimes[spaceOnlyRule.id] = AutomationRuntime(nextDue: now.addingTimeInterval(10*86400))
  }
  var spaceOnlyDiscover = 0, spaceOnlyPerform = 0
  var spaceOnlyEnv = AutomationEnvironment()
  spaceOnlyEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 100, available: 50) }
  spaceOnlyEnv.access = {}
  spaceOnlyEnv.discover = { _ in spaceOnlyDiscover += 1; return [] }
  spaceOnlyEnv.perform = { snapshot, _ in spaceOnlyPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  spaceOnlyEnv.notify = { _ in true }
  try AutomationWorker(store: spaceOnlyStore, environment: spaceOnlyEnv).tick(now: now)
  let spaceOnly = try spaceOnlyStore.read()
  precondition(spaceOnly.runs.count == 1 && spaceOnly.runs[0].reasons == ["space"])
  precondition(spaceOnly.runs[0].isReminder && spaceOnly.runs[0].status == .completed)
  precondition(spaceOnlyDiscover == 0 && spaceOnlyPerform == 0, "capacity trigger must not discover or perform")
  // The same old combination on a healthy disk is blocked too: no discover, no perform, no automatic run.
  let healthyStore = AutomationStore(directory: URL(fileURLWithPath: root + "/legacy-healthy-state"))
  let healthyRule = AutomationRule(title: "旧组合定时", days: 1, repeats: true, metric: .usedPercent, threshold: 40, mode: .automatic, scopes: [scope], volumeID: "fixture", now: now.addingTimeInterval(-86400))
  try healthyStore.update { db in db.paused = false; db.rules = [healthyRule]; db.runtimes[healthyRule.id] = AutomationRuntime(nextDue: now) }
  var healthyDiscover = 0, healthyPerform = 0
  var healthyEnv = AutomationEnvironment()
  healthyEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 100, available: 90) }
  healthyEnv.access = {}
  healthyEnv.discover = { _ in
   healthyDiscover += 1
   let item = ScanItem.trashTarget(path: scope.path, name: "fixture", size: 3, rule: "应用可重建缓存", evidence: "fixture", risk: .amber)
   return [CleanupCandidate(source: "appcache", key: scope.path, title: "fixture", size: 3, evidence: "fixture", risk: .amber, action: .trash(item: item))]
  }
  healthyEnv.perform = { snapshot, _ in healthyPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "fixture blocked action", bytes: 0) }
  healthyEnv.notify = { _ in true }
  try AutomationWorker(store: healthyStore, environment: healthyEnv).tick(now: now)
  let healthy = try healthyStore.read()
  precondition(healthy.runs.count == 1 && healthy.runs[0].reasons == ["time"], "healthy disk must only report the time trigger")
  precondition(healthy.runs[0].status == .needsAttention)
  precondition(healthy.runs[0].message == "旧自动清理已暂停，请新建定时扫描规则")
  precondition(healthyDiscover == 0 && healthyPerform == 0, "legacy automatic must not discover or perform")
  precondition(healthy.rules[0].enabled && healthy.runtimes[healthyRule.id]?.blocker != nil)
  // Automatic execution must reject a queued space run even when it reaches awaitingConfirmation.
  let bypassStore = AutomationStore(directory: URL(fileURLWithPath: root + "/bypass-state"))
  let bypassRule = legacyRule
  var scanning = AutomationRun(ruleID: bypassRule.id, revision: bypassRule.revision, title: bypassRule.title, createdAt: now, updatedAt: now, reasons: ["space"])
  scanning.status = .scanning
  try bypassStore.update { db in
   db.paused = false; db.rules = [bypassRule]; db.runs = [scanning]
   db.runtimes[bypassRule.id] = AutomationRuntime(nextDue: now, activeRunID: scanning.id)
  }
  var bypassDiscover = 0, bypassPerform = 0
  var bypassEnv = AutomationEnvironment()
  bypassEnv.volume = { AutomationVolume(id: "fixture", path: root, total: 100, available: 50) }
  bypassEnv.access = {}
  bypassEnv.discover = { _ in
   bypassDiscover += 1
   let item = ScanItem.trashTarget(path: scope.path, name: "fixture", size: 3, rule: "应用可重建缓存", evidence: "fixture", risk: .amber)
   return [CleanupCandidate(source: "appcache", key: scope.path, title: "fixture", size: 3, evidence: "fixture", risk: .amber, action: .trash(item: item))]
  }
  bypassEnv.perform = { snapshot, _ in bypassPerform += 1; return CleanupOutcome(id: snapshot.id, ok: false, message: "must not run", bytes: 0) }
  bypassEnv.notify = { _ in true }
  // A queued space scan becomes a reminder: it is finished without any discover or perform.
  try AutomationWorker(store: bypassStore, environment: bypassEnv).tick(now: now)
  let bypassed = try bypassStore.read()
  precondition(bypassDiscover == 0 && bypassPerform == 0, "queued space scan must never discover or perform")
  precondition(bypassed.runs[0].isReminder && bypassed.runs[0].status == .completed, "queued space scan must finish as a reminder")
  precondition(bypassed.runtimes[bypassRule.id]?.blocker == nil && bypassed.runs[0].message.contains("只发出提醒"))
  // A real move of generated temporary data must be durably recoverable.
  try worker.acknowledge(runID: uncertain.runs.last!.id, now: now)
  try store.update { db in db.runtimes[rule.id] = AutomationRuntime(nextDue: now) }
  env.perform = { snapshot, _ in
   try! fm.moveItem(atPath: snapshot.item.path, toPath: root + "/trashed-fixture")
   return CleanupOutcome(id: snapshot.id, ok: true, message: "moved", bytes: 7, trashedTo: root + "/trashed-fixture")
  }
  let durableWorker = AutomationWorker(store: store, environment: env)
  try durableWorker.tick(now: now)
  let durabilityPlan = try store.read().runs.last!
  precondition(durabilityPlan.status == .awaitingConfirmation)
  // A confirm rule only prepares in the background; the move needs explicit approval.
  try durableWorker.approve(runID: durabilityPlan.id, token: durabilityPlan.token, ids: durabilityPlan.items.map(\.id), now: now)
  let ledger = TrashLedger(url: URL(fileURLWithPath: root + "/state/pending-trash.json"), trashRoots: [root])
  precondition(ledger.recoveryItems().contains { $0.originalPath == scope.path })
  print("AutomationWorkerTests passed")
 }
}
