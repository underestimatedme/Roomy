// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
@main struct PermissionDiagnosticsTests {
 static func main() throws {
  let root = "/private/tmp/roomy-permissions-" + UUID().uuidString
  defer { try? FileManager.default.removeItem(atPath: root) }
  let id = "com.tencent.xinWeChat", path = root + "/Library/Containers/" + id + "/Data/Library/Caches"
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  let initial = PermissionDiagnostics.inspect(home: root, installedIDs: [id])
  precondition(initial.count == 1 && initial[0].state == "readable")
  precondition(chmod(path, 0) == 0); defer { _ = chmod(path, 0o755) }
  precondition(PermissionDiagnostics.inspect(home: root, installedIDs: [id])[0].state == "denied")
  precondition(chmod(path, 0o755) == 0)
  try FileManager.default.moveItem(atPath: path, toPath: root + "/held")
  precondition(PermissionDiagnostics.inspect(home: root, installedIDs: [id])[0].state == "missing")
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: root + "/held")
  precondition(PermissionDiagnostics.inspect(home: root, installedIDs: [id])[0].state == "unsafe")
  precondition(PermissionDiagnostics.inspect(home: root, installedIDs: ["com.unknown"] ).isEmpty)
  print("Permission diagnostics passed: actual readable, denied, missing, linked, uninstalled states")
 }
}
