import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portugueseBrazil = "pt-BR"

    var id: String { rawValue }

    /// Native display names. English is listed first in `allCases`.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .portugueseBrazil: return "Português (Brasil)"
        }
    }

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .simplifiedChinese: return Locale(identifier: "zh_Hans")
        case .traditionalChinese: return Locale(identifier: "zh_Hant")
        case .japanese: return Locale(identifier: "ja")
        case .korean: return Locale(identifier: "ko")
        case .spanish: return Locale(identifier: "es")
        case .french: return Locale(identifier: "fr")
        case .german: return Locale(identifier: "de")
        case .portugueseBrazil: return Locale(identifier: "pt_BR")
        }
    }

    func formatTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static let `default`: AppLanguage = .english

    /// Languages whose copy is stored in `L10nCatalog` rather than the `zh:` call-site argument.
    static var catalogLanguages: [AppLanguage] {
        allCases.filter { $0 != .english && $0 != .simplifiedChinese }
    }

    static func resolved(stored: String?) -> AppLanguage {
        stored.flatMap(AppLanguage.init(rawValue:)) ?? .default
    }
}

/// In-app copy. English is the source language; other locales fall back to English if a string is missing.
enum L10n {
    private final class LanguageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: AppLanguage = .english

        var language: AppLanguage {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    private static let box = LanguageBox()

    static var language: AppLanguage {
        get { box.language }
        set { box.language = newValue }
    }

    static func t(_ english: String, zh: String) -> String {
        template(english: english, zh: zh)
    }

    static func t(_ english: String, zh: String, _ args: String...) -> String {
        t(english, zh: zh, args)
    }

    static func t(_ english: String, zh: String, _ args: [String]) -> String {
        format(template(english: english, zh: zh), args)
    }

    static func resetToDefault() {
        language = .default
    }

    static func template(english: String, zh: String) -> String {
        switch language {
        case .english:
            return english
        case .simplifiedChinese:
            return zh
        default:
            return L10nCatalog.string(language, english: english) ?? english
        }
    }

    private static func format(_ template: String, _ args: [String]) -> String {
        var result = template
        for (index, arg) in args.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: arg)
        }
        return result
    }
}
