// SPDX-License-Identifier: MPL-2.0
import Foundation

@main struct RoomyLocalizationTests {
    static func main() throws {
        precondition(RoomyLocalization.resolve("auto", preferred: ["zh-CN", "en-US"]) == "zh-Hans")
        precondition(RoomyLocalization.resolve("auto", preferred: ["en-GB", "zh-HK"]) == "en")
        precondition(RoomyLocalization.resolve("auto", preferred: ["fr-FR", "zh-Hant"]) == "zh-Hans")
        precondition(RoomyLocalization.resolve("auto", preferred: ["fr-FR"]) == "en")
        precondition(RoomyLocalization.resolve("en", preferred: ["zh-CN"]) == "en")
        precondition(RoomyLocalization.resolve("zh-Hans", preferred: ["en-US"]) == "zh-Hans")
        precondition(RoomyLocalization.resolve("unexpected", preferred: ["en-US"]) == "en")
        let domain = "com.atlaspaces.roomy.localization-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain(["unrelated": "preserved"], forName: domain)
        try RoomyLocalization.save("en", defaults: defaults, domain: domain)
        precondition(defaults.persistentDomain(forName: domain)?[RoomyLocalization.preferenceKey] as? String == "en")
        precondition(defaults.persistentDomain(forName: domain)?["unrelated"] as? String == "preserved")
        let before = defaults.persistentDomain(forName: domain)! as NSDictionary
        do { try RoomyLocalization.save("../../bad", defaults: defaults, domain: domain); fatalError("Invalid language accepted") }
        catch { precondition(defaults.persistentDomain(forName: domain)! as NSDictionary == before) }
        try RoomyLocalization.save("auto", defaults: defaults, domain: domain)
        precondition(defaults.persistentDomain(forName: domain)?[RoomyLocalization.preferenceKey] as? String == "auto")
        print("RoomyLocalizationTests passed (isolated preferences; no real app settings changed)")
    }
}
