// SPDX-License-Identifier: MPL-2.0
import Foundation

private final class MaintenanceScanBox: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)
    var result: Result<ScanCompletion, Error>?
}

/// Free CLI adapters for the same bounded, validated maintenance services as the GUI.
/// The caller supplies the shared global operation lease before any mutation.
enum CLIMaintenance {
    static func run(_ options: CLIOptions, home: String = NSHomeDirectory(), stateDirectory: URL? = nil,
                    applicationRoots: [String]? = nil,
                    prepareMutation: () throws -> Void) throws -> CLIResponse {
        guard !options.apply || options.yes else { throw cliError("此操作需要明确的 --apply --yes；未执行") }
        guard !options.yes || options.apply else { throw cliError("--yes 必须与 --apply 同时使用") }
        let state = stateDirectory ?? URL(fileURLWithPath: home + "/Library/Application Support/Roomy", isDirectory: true)
        func applications() -> [ApplicationRecord] {
            ApplicationCatalog.discover(roots: applicationRoots ?? ["/Applications", home + "/Applications", "/System/Applications"],
                runningPaths: [], sizeOf: { _ in nil }).apps
        }
        func safePath(_ path: String) throws -> String {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.utf8.contains(0), !expanded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw cliError("目录路径包含无效部分") }
            let value = URL(fileURLWithPath: expanded).path
            guard CleanupIdentity.capture(path: value)?.kind == .directory,
                  ApplicationAssociations.directoryIdentities(value) != nil else { throw cliError("目录不可安全读取或包含符号链接") }
            return value
        }
        switch options.command {
        case "permissions":
            let locations = PermissionDiagnostics.inspect(home: home, installedIDs: Set(applications().map(\.bundleID)))
            return CLIResponse(data: ["locations": try cliObject(locations)], text: "应用数据访问检查（未统计不代表零占用）：\n"
                + locations.map { "\(cliSafeText($0.title))  \($0.state)  \(cliSafeText($0.path))\n  \(cliSafeText($0.detail))" }.joined(separator: "\n"))
        case "growth":
            let store = SpaceGrowthStore(directory: state.appendingPathComponent("SpaceGrowth", isDirectory: true))
            if let subject = options.subject {
                let path = try safePath(subject), box = MaintenanceScanBox()
                Task {
                    do { box.result = .success(try await runIndexScan(root: URL(fileURLWithPath: path), workerCount: 4)) }
                    catch { box.result = .failure(error) }
                    box.signal.signal()
                }
                box.signal.wait()
                let scan = try box.result!.get()
                let report = try store.record(index: scan.index, diagnostics: scan.diagnostics)
                return CLIResponse(data: ["report": try cliObject(report)], text: growthText(report), status: report.status == "incomparable" ? 3 : 0)
            }
            let reports = try store.latestReports()
            return CLIResponse(data: ["reports": try cliObject(reports)], text: reports.isEmpty ? "尚无增长记录；使用 roomy growth PATH 建立完整扫描基线。" : reports.map(growthText).joined(separator: "\n\n"))
        default: throw cliError("未知维护命令")
        }
    }

    private static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
    /// 对比基线是至少一天前的那次扫描（没有就用最早一次），这里写明是哪天
    private static func comparedWith(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return "对比 \(f.string(from: date)) 的扫描。"
    }
    private static func growthText(_ report: SpaceGrowthReport) -> String {
        let change = report.deltaBytes.map { ($0 >= 0 ? "+" : "−") + bytes(UInt64($0.magnitude)) } ?? "尚不可比较"
        return "\(cliSafeText(report.rootPath)) · 已分配占用 \(bytes(report.currentAllocatedBytes)) · 变化 \(change)\n"
            + (report.reason.map(cliSafeText) ?? (report.status == "baseline" ? "已建立基线；间隔 1 小时以上再次完整扫描后比较。" : (report.shouldRemind ? "占用增长达到 1 GiB，建议查看增长目录。" : "") + comparedWith(report.previousCapturedAt)))
            + "\n占用变化不等于可释放空间。\n" + report.rows.filter { $0.deltaBytes != 0 }.prefix(20).map {
                "\($0.deltaBytes >= 0 ? "+" : "−")\(bytes(UInt64($0.deltaBytes.magnitude)))  \($0.kind)  \(cliSafeText($0.path))"
            }.joined(separator: "\n")
    }
}
