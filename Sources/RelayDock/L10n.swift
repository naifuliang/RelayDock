import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case de = "de"
    case fr = "fr"
    case es = "es"
    case ptBR = "pt-BR"
    case ru = "ru"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        case .ru: return "Русский"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .zhHans: return "zh_CN"
        case .zhHant: return "zh_TW"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .de: return "de"
        case .fr: return "fr"
        case .es: return "es"
        case .ptBR: return "pt_BR"
        case .ru: return "ru"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    static func matchingSystem(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for preferred in preferredLanguages {
            let id = preferred.lowercased().replacingOccurrences(of: "_", with: "-")
            if id.hasPrefix("zh-hant") || id.hasPrefix("zh-tw") || id.hasPrefix("zh-hk") || id.hasPrefix("zh-mo") {
                return .zhHant
            }
            if id.hasPrefix("zh") { return .zhHans }
            if id.hasPrefix("ja") { return .ja }
            if id.hasPrefix("ko") { return .ko }
            if id.hasPrefix("de") { return .de }
            if id.hasPrefix("fr") { return .fr }
            if id.hasPrefix("es") { return .es }
            if id.hasPrefix("pt") { return .ptBR }
            if id.hasPrefix("ru") { return .ru }
            if id.hasPrefix("en") { return .en }
        }
        return .en
    }
}

enum LanguagePreference: Equatable {
    case system
    case fixed(AppLanguage)

    var storageValue: String {
        switch self {
        case .system: return "system"
        case let .fixed(language): return language.rawValue
        }
    }

    static func parse(_ raw: String?) -> LanguagePreference {
        guard let raw, raw != "system", let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return .fixed(language)
    }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .system: return AppLanguage.matchingSystem(preferredLanguages: preferredLanguages)
        case let .fixed(language): return language
        }
    }
}

enum L10n {
    static let preferenceKey = "appLanguage"

    private static let lock = NSLock()
    private static let tables: [AppLanguage: [String: String]] = L10nCatalog.load()
    private static var resolvedLanguage = LanguagePreference.parse(
        UserDefaults.standard.string(forKey: preferenceKey)
    ).resolved()

    static var resolved: AppLanguage {
        lock.lock()
        defer { lock.unlock() }
        return resolvedLanguage
    }

    static func applyResolved(_ language: AppLanguage) {
        lock.lock()
        resolvedLanguage = language
        lock.unlock()
    }

    static func t(_ key: String, _ args: [String: String] = [:]) -> String {
        lock.lock()
        let language = resolvedLanguage
        lock.unlock()
        let value = tables[language]?[key]
            ?? tables[.en]?[key]
            ?? tables[.zhHans]?[key]
            ?? key
        return interpolate(value, args: args)
    }

    static func interpolate(_ template: String, args: [String: String]) -> String {
        args.reduce(template) { partial, item in
            partial.replacingOccurrences(of: "{\(item.key)}", with: item.value)
        }
    }

    static func keys() -> Set<String> {
        Set(tables[.en]?.keys ?? [])
    }

    static func table(for language: AppLanguage) -> [String: String] {
        tables[language] ?? [:]
    }
}

@MainActor
final class LocalizationStore: ObservableObject {
    static let shared = LocalizationStore()

    @Published private(set) var preference: LanguagePreference
    @Published private(set) var resolved: AppLanguage

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let preference = LanguagePreference.parse(defaults.string(forKey: L10n.preferenceKey))
        self.preference = preference
        let resolved = preference.resolved()
        self.resolved = resolved
        L10n.applyResolved(resolved)
    }

    func setPreference(_ preference: LanguagePreference) {
        self.preference = preference
        defaults.set(preference.storageValue, forKey: L10n.preferenceKey)
        let resolved = preference.resolved()
        self.resolved = resolved
        L10n.applyResolved(resolved)
    }
}
