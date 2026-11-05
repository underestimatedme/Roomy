// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@main struct AutomationPolicyTests {
 static func main() throws {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let volume = AutomationVolume(id: "vol", path: "/", total: 100_000_000_000, available: 9_000_000_000)
  var rule = AutomationRule(title: "test", days: 2, repeats: true, metric: .usedPercent, threshold: 90, mode: .confirm, scopes: [.init(kind: .appCache, path: "/tmp/cache", title: "cache")], volumeID: "vol", now: now)
  var runtime = AutomationRuntime(nextDue: now.addingTimeInterval(2*86400))
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now) == ["space"])
  AutomationPolicy.finish(rule: &rule, runtime: &runtime, now: now)
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now.addingTimeInterval(86401)).isEmpty, "full disk must not repeat")
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now.addingTimeInterval(2*86400)) == ["time"])
  var recover = AutomationVolume(id: "vol", path: "/", total: volume.total, available: 15_000_000_000)
  _ = AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: recover, now: now.addingTimeInterval(2*86400+1))
  _ = AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: recover, now: now.addingTimeInterval(2*86400+901))
  precondition(!runtime.spaceLatched)
  recover.id = "replacement"
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: recover, now: now.addingTimeInterval(3*86400)).isEmpty)
  precondition(runtime.blocker != nil, "wrong volume fails closed")
  runtime = AutomationRuntime(nextDue: now)
  rule.repeats = false
  AutomationPolicy.finish(rule: &rule, runtime: &runtime, now: now)
  precondition(!rule.enabled)
  rule.enabled = true; runtime = AutomationRuntime(nextDue: now); runtime.lastObserved = now
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now.addingTimeInterval(-301)).isEmpty)
  precondition(runtime.blocker != nil)
  rule.repeats = true; rule.days = 7
  runtime = AutomationRuntime(nextDue: now)
  let below = AutomationVolume(id: "vol", path: "/", total: volume.total, available: 12_000_000_000)
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: below, now: now) == ["time"])
  AutomationPolicy.finish(rule: &rule, runtime: &runtime, now: now)
  precondition(AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: volume, now: now.addingTimeInterval(86401)) == ["space"], "time-only finish must not consume a future space crossing")
  runtime.activeRunID = "pending"
  recover.id = "vol"
  _ = AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: recover, now: now.addingTimeInterval(86402))
  _ = AutomationPolicy.evaluate(rule: rule, runtime: &runtime, volume: recover, now: now.addingTimeInterval(87302))
  AutomationPolicy.finish(rule: &rule, runtime: &runtime, now: now.addingTimeInterval(87303))
  precondition(!runtime.spaceLatched, "completion must preserve recovery observed while awaiting confirmation")
  runtime = AutomationRuntime(nextDue: now)
  for delay in [1800.0, 7200, 86400] {
   AutomationPolicy.fail(runtime: &runtime, message: "temporary", now: now, permanent: false)
   precondition(runtime.retryAt == now.addingTimeInterval(delay) && runtime.blocker == nil)
  }
  AutomationPolicy.fail(runtime: &runtime, message: "temporary", now: now, permanent: false)
  precondition(runtime.blocker != nil && runtime.retryAt == nil)
  rule.days = 0
  do { try rule.validate(); fatalError("zero days allowed") } catch {}
  // A capacity reminder formats an old, large-but-finite threshold directly: no integer conversion, no trap.
  var huge = AutomationRule(title: "huge", days: nil, repeats: true, metric: .availableGB, threshold: 1e18, mode: .confirm, scopes: [], volumeID: "vol", now: now)
  try huge.validate()
  let hugeMessage = AutomationPolicy.reminderMessage(rule: huge, volume: volume)
  precondition(hugeMessage.contains("GB") && hugeMessage.contains("只发出提醒"))
  precondition(AutomationPolicy.reminderMessage(rule: huge, volume: nil).contains("无法读取"))
  var percent = huge
  percent.metric = .usedPercent
  let unknownPercent = AutomationPolicy.reminderMessage(rule: percent, volume: nil)
  precondition(unknownPercent.contains("无法读取") && !unknownPercent.contains("当前已用 0%"))
  var zeroTotal = volume
  zeroTotal.total = 0
  precondition(!AutomationPolicy.reminderMessage(rule: percent, volume: zeroTotal).contains("当前已用 0%"))
  precondition(AutomationPolicy.reminderMessage(rule: percent, volume: volume).contains("91%"))
  // An empty scope list is only legal for a rule without a schedule; a timed rule always needs an authorized scope.
  var noScope = AutomationRule(title: "no scope", days: 3, repeats: true, metric: nil, threshold: nil, mode: .confirm, scopes: [], volumeID: "vol", now: now)
  do { try noScope.validate(); fatalError("timed rule without scope accepted") } catch {}
  noScope.metric = .availableGB; noScope.threshold = 20; noScope.days = nil
  try noScope.validate()
  // A rule without a schedule can only ever report capacity, even if an old record still carries a due date.
  var capacityRuntime = AutomationRuntime(nextDue: now.addingTimeInterval(-86400))
  precondition(AutomationPolicy.evaluate(rule: noScope, runtime: &capacityRuntime, volume: volume, now: now) == ["space"])
  noScope.mode = .automatic
  do { try noScope.validate(); fatalError("scope-free capacity rule may not be automatic") } catch {}
  print("AutomationPolicyTests passed")
 }
}
