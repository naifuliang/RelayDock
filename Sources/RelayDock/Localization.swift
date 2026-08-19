import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Native display names. English is listed first in `allCases`.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US")
        case .simplifiedChinese: return Locale(identifier: "zh_Hans")
        }
    }

    static let `default`: AppLanguage = .english

    static func resolved(stored: String?) -> AppLanguage {
        stored.flatMap(AppLanguage.init(rawValue:)) ?? .default
    }
}

/// In-app copy. English is the source language; Simplified Chinese is the first translation.
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
        language == .simplifiedChinese ? zh : english
    }

    static func t(_ english: String, zh: String, _ args: String...) -> String {
        format(t(english, zh: zh), args)
    }

    static func resetToDefault() {
        language = .default
    }

    private static func format(_ template: String, _ args: [String]) -> String {
        var result = template
        for (index, arg) in args.enumerated() {
            result = result.replacingOccurrences(of: "{\(index)}", with: arg)
        }
        return result
    }
}
