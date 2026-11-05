// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Presentation preferences only. Language never changes a scan, rule, path or authorization decision.
enum RoomyLocalization {
    static let preferenceKey = "RoomyLanguage"
    static let choices = ["auto", "zh-Hans", "en"]
    static func resolve(_ selection: String, preferred: [String]) -> String {
        if selection == "en" || selection == "zh-Hans" { return selection }
        for value in preferred {
            let language = value.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            if language == "zh" { return "zh-Hans" }
            if language == "en" { return "en" }
        }
        return "en"
    }
    static var domain: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.atlaspaces.roomy"
        return bundle == "com.atlaspaces.roomy.scheduler" ? "com.atlaspaces.roomy" : bundle
    }
    static var selection: String {
        let value = UserDefaults.standard.persistentDomain(forName: domain)?[preferenceKey] as? String ?? "auto"
        return choices.contains(value) ? value : "auto"
    }
    static var language: String { resolve(selection, preferred: Locale.preferredLanguages) }
    static func text(_ chinese: String, _ english: String) -> String { language == "en" ? english : chinese }
    @discardableResult static func save(_ value: String, defaults: UserDefaults = .standard, domain: String = domain) throws -> String {
        guard choices.contains(value) else { throw NSError(domain: "RoomyLocalization", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported language"]) }
        var preferences = defaults.persistentDomain(forName: domain) ?? [:]
        preferences[preferenceKey] = value
        defaults.setPersistentDomain(preferences, forName: domain)
        return resolve(value, preferred: Locale.preferredLanguages)
    }
    static var scriptConfig: String {
        let data = try! JSONSerialization.data(withJSONObject: ["selection": selection, "language": language])
        return String(decoding: data, as: UTF8.self)
    }
}
