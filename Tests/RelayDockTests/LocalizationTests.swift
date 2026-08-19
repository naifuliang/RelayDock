import XCTest
@testable import RelayDock

final class LocalizationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.resetToDefault()
    }

    override func tearDown() {
        L10n.resetToDefault()
        super.tearDown()
    }

    func testEnglishIsTheDefaultAndFirstLanguage() {
        XCTAssertEqual(AppLanguage.default, .english)
        XCTAssertEqual(AppLanguage.allCases.first, .english)
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR"]
        )
        XCTAssertEqual(AppLanguage.resolved(stored: nil), .english)
        XCTAssertEqual(AppLanguage.resolved(stored: "unknown"), .english)
        XCTAssertEqual(AppLanguage.resolved(stored: "zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolved(stored: "ja"), .japanese)
        XCTAssertEqual(AppLanguage.resolved(stored: "pt-BR"), .portugueseBrazil)
    }

    func testEnglishCopyIsUsedByDefault() {
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "Ready")
        XCTAssertEqual(
            L10n.t("Switched to {0}", zh: "已切换到 {0}", "Gateway 1"),
            "Switched to Gateway 1"
        )
        XCTAssertEqual(
            UpdateError.missingDigest.errorDescription,
            "GitHub has not published a SHA-256 digest for the update package; download was stopped."
        )
    }

    func testSimplifiedChineseCopyIsReturnedAfterSwitch() {
        L10n.language = .simplifiedChinese
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "准备就绪")
        XCTAssertEqual(
            L10n.t("Switched to {0}", zh: "已切换到 {0}", "Gateway 1"),
            "已切换到 Gateway 1"
        )
        XCTAssertEqual(EndpointPreset.arkCodingPlan.title, "火山方舟")
    }

    func testCatalogLanguagesReturnLocalizedCopyAndFallBackToEnglish() {
        L10n.language = .japanese
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "準備完了")
        XCTAssertEqual(L10n.t("Language", zh: "语言"), "言語")
        XCTAssertEqual(
            L10n.t("Switched to {0}", zh: "已切换到 {0}", "Gateway 1"),
            "Gateway 1 に切り替えました"
        )

        L10n.language = .traditionalChinese
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "準備就緒")
        XCTAssertEqual(L10n.t("Language", zh: "语言"), "語言")

        L10n.language = .korean
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "준비됨")
        L10n.language = .spanish
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "Listo")
        L10n.language = .french
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "Prêt")
        L10n.language = .german
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "Bereit")
        L10n.language = .portugueseBrazil
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "Pronto")

        L10n.language = .japanese
        XCTAssertEqual(
            L10n.t("A string that is not in the catalog yet", zh: "目录里还没有"),
            "A string that is not in the catalog yet"
        )
    }

    func testEveryCatalogLanguageHasTheSameCompleteKeySet() {
        let languages = AppLanguage.catalogLanguages
        XCTAssertEqual(
            languages.map(\.rawValue),
            ["zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR"]
        )
        let expected = L10nCatalog.keys(for: .japanese)
        XCTAssertEqual(expected.count, 263)
        for language in languages {
            XCTAssertEqual(L10nCatalog.keys(for: language), expected, language.rawValue)
        }
        XCTAssertTrue(expected.contains("Ready"))
        XCTAssertTrue(expected.contains("Repair Keychain once"))
        XCTAssertTrue(expected.contains("Endpoints"))
        XCTAssertTrue(expected.contains("Models"))
        XCTAssertTrue(expected.contains("Launchers"))
        XCTAssertEqual(L10nCatalog.string(.japanese, english: "Ready"), "準備完了")
        XCTAssertEqual(L10nCatalog.string(.traditionalChinese, english: "Ready"), "準備就緒")
    }

    @MainActor
    func testAppModelPersistsEnglishFirstLanguagePreference() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(model.statusMessage, "Ready")

        model.language = .japanese
        XCTAssertEqual(defaults.string(forKey: AppModel.languageKey), "ja")
        XCTAssertEqual(L10n.language, .japanese)
        XCTAssertEqual(model.statusMessage, "準備完了")

        let relaunched = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false)
        XCTAssertEqual(relaunched.language, .japanese)
        XCTAssertEqual(relaunched.statusMessage, "準備完了")
    }

    @MainActor
    func testChangingLanguageRerendersCurrentStatusOnTheSameInstance() {
        let suiteName = "LocalizationTests.rerender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(model.statusMessage, "Ready")

        model.language = .japanese
        XCTAssertEqual(model.statusMessage, "準備完了")

        model.language = .simplifiedChinese
        XCTAssertEqual(model.statusMessage, "准备就绪")

        model.language = .english
        XCTAssertEqual(model.statusMessage, "Ready")
    }

    func testBundleDeclaresEnglishAsTheDevelopmentRegion() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("support/Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(
            plist["CFBundleLocalizations"] as? [String],
            ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR"]
        )
    }
}
