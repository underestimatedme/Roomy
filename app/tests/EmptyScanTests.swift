// SPDX-License-Identifier: MPL-2.0
import Foundation

@main
struct EmptyScanTests {
    static func main() {
        var calls = 0
        let result = parallelSizes(count: 0, threads: 4) { _, _ in
            calls += 1
            return 1
        }
        guard result.isEmpty, calls == 0 else {
            fputs("FAIL: empty scan should return without invoking worker\n", stderr)
            exit(1)
        }
        print("empty scan ok")
    }
}
