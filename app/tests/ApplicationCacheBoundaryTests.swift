// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct ApplicationCacheBoundaryTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("roomy-browser-boundaries-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let chrome = root.path + "/Library/Caches/Google/Chrome"
        let firefox = root.path + "/Library/Caches/Firefox"
        for path in [chrome + "/Default/Cache", chrome + "/Default/Storage", firefox + "/Profiles/abcd1234.default-release/cache2"] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let browser = RULES.first { $0.name == "浏览器缓存" }!
        let planned = expandPaths(browser.paths.map { $0.replacingOccurrences(of: HOME, with: root.path) }, codeRoots: [])
        precondition(!planned.contains(chrome) && !planned.contains(firefox), "browser planning must not authorize entire cache/profile roots containing unreviewed storage")
        print("ApplicationCacheBoundaryTests passed: broad browser roots are not authorized")
    }
}
