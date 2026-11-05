// SPDX-License-Identifier: GPL-3.0-only
import Foundation
@main struct AutomationDiscoveryTests {
 static func main() throws {
  let fm = FileManager.default
  let home = "/private/tmp/roomy-automation-discovery-" + UUID().uuidString
  let path = home + "/Library/Developer/Xcode/DerivedData/Fixture/Build/Intermediates.noindex"
  try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  defer { try? fm.removeItem(atPath: home) }
  guard let volume = AutomationDiscovery.volume(home: home) else { fatalError("fixture volume unavailable") }
  let rule = AutomationRule(title: "fixture", days: 1, repeats: false, metric: nil, threshold: nil, mode: .confirm,
    scopes: [.init(kind: .derivedObjects, path: path, title: "objects")], volumeID: volume.id, now: Date())
  let absent = try AutomationDiscovery.discover(rule: rule, home: home)
  precondition(absent.isEmpty, "genuinely absent target is an empty run")
  try fm.createSymbolicLink(atPath: path, withDestinationPath: home + "/absent-target")
  do { _ = try AutomationDiscovery.discover(rule: rule, home: home); fatalError("existing uninspectable target silently consumed") } catch {}
  try tieredManifestBoundary(home: home, volumeID: volume.id)
  print("AutomationDiscoveryTests passed")
 }

 /// 分级清理 v2：A 档的工具清理和 Docker 删除即使有 learned A 覆盖，也不会进入自动清理；自动清理只接受废纸篓动作。
 static func tieredManifestBoundary(home: String, volumeID: String) throws {
  let fm = FileManager.default
  let npmKey = CleanupPreferenceKey(owner: "npm 下载缓存", kind: "tool", scope: CleanupPreferenceKey.digest("/fixture/.npm/_cacache"))
  let dockerKey = CleanupPreferenceKey(owner: "Docker 匿名卷", kind: "docker", scope: CleanupPreferenceKey.digest("volume:anon"))
  var tool = CleanupCandidate(source: "owner-cache", key: "npm", title: "npm 缓存", size: 10, evidence: "fixture", risk: .amber,
    action: .toolClean(.npmCache, scope: "/fixture/.npm/_cacache"), tier: .obsolete)
  var docker = CleanupCandidate(source: "docker", key: "volume:anon", title: "匿名卷", size: 10, evidence: "fixture", risk: .amber,
    action: .dockerRemove(kind: .volume, id: "anon"), tier: .obsolete)
  tool.entry.preferenceKey = npmKey; docker.entry.preferenceKey = dockerKey
  let learned = [npmKey, dockerKey].map {
    CleanupTierOverride(key: $0, tier: .obsolete, fromTier: .rebuildable, origin: .learned, reason: "你清过 3 次", at: Date())
  }
  let manifest = [tool, docker]
  let overridden = CleanupTierOverrides.apply(manifest.map(\.entry), overrides: learned)
  precondition(overridden.allSatisfy { !$0.reversible && $0.tier != .locked }, "fixture rows are irreversible candidates")
  let manifestIDs = Set(manifest.map { $0.entry.id })

  // 自动清理范围只有两种，且都是废纸篓动作；任何工具/Docker 范围都无法被规则表达
  for kind in ["toolClean", "dockerRemove", "docker", "tool"] {
   let json = Data(#"{"kind":"\#(kind)","path":"/fixture","title":"x"}"#.utf8)
   precondition((try? JSONDecoder().decode(AutomationScope.self, from: json)) == nil, "scope kind \(kind) must not decode")
  }

  // 有真实内容的编译对象范围：发现结果只含 .trash，且不含清单里的 A 档工具/Docker 项
  let derived = home + "/Library/Developer/Xcode/DerivedData/Fixture2/Build/Intermediates.noindex"
  try fm.createDirectory(atPath: derived, withIntermediateDirectories: true)
  let file = derived + "/object.o"
  // 真正的 Mach-O 目标文件头（MH_MAGIC_64、arm64、MH_OBJECT），证据核验才会接受
  var object = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
  object.append(Data(repeating: 0, count: 4096 - object.count))
  precondition(object.count == 4096)
  try object.write(to: URL(fileURLWithPath: file))
  try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: file)
  try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -400 * 86400)], ofItemAtPath: derived)
  let rule = AutomationRule(title: "boundary", days: 1, repeats: false, metric: nil, threshold: nil, mode: .automatic,
    scopes: [.init(kind: .derivedObjects, path: derived, title: "objects"), .init(kind: .appCache, path: home + "/Library/Caches/absent", title: "absent")],
    volumeID: volumeID, now: Date())
  // 发现必须真正接受这个范围（否则这条断言是空的）：结果恰好是这个编译对象目录的一条废纸篓动作
  let found = try AutomationDiscovery.discover(rule: rule, home: home)
  precondition(found.count == 1 && found[0].entry.path == derived, "discover accepts the object fixture: \(found.map(\.entry.title))")
  for candidate in found {
   guard case .trash(let item)? = candidate.action else { fatalError("automation discovered a non-trash action: \(candidate.entry.title)") }
   precondition(item.path == derived && candidate.entry.reversible, "the only action is moving the scoped directory to the Trash")
   precondition(!manifestIDs.contains(candidate.entry.id), "A-tier tool/docker rows must not appear in automation")
  }
  // 能解码的范围只有这两种
  for kind in ["appCache", "derivedObjects"] {
   let json = Data(#"{"kind":"\#(kind)","path":"/fixture","title":"x"}"#.utf8)
   precondition((try? JSONDecoder().decode(AutomationScope.self, from: json)) != nil, "scope kind \(kind) decodes")
  }
 }
}
