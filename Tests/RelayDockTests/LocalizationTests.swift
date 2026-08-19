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
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["en", "zh-Hans"])
        XCTAssertEqual(AppLanguage.resolved(stored: nil), .english)
        XCTAssertEqual(AppLanguage.resolved(stored: "unknown"), .english)
        XCTAssertEqual(AppLanguage.resolved(stored: "zh-Hans"), .simplifiedChinese)
    }

    func testEnglishCopyIsUsedByDefault() {
        L10n.resetToDefault()
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "Ready")
        XCTAssertEqual(
            L10n.t("Switched to {0}", zh: "已切换到 {0}", "Gateway 1"),
            "Switched to Gateway 1"
        )
        XCTAssertEqual(UpdateError.missingDigest.errorDescription, "GitHub has not published a SHA-256 digest for the update package; download was stopped.")
        XCTAssertEqual(KeychainMigrationError.migrationRequired.errorDescription, "Repair Keychain once first, then read or change a saved API key.")
    }

    func testSimplifiedChineseCopyIsReturnedAfterSwitch() {
        L10n.language = .simplifiedChinese
        XCTAssertEqual(L10n.t("Ready", zh: "准备就绪"), "准备就绪")
        XCTAssertEqual(
            L10n.t("Switched to {0}", zh: "已切换到 {0}", "Gateway 1"),
            "已切换到 Gateway 1"
        )
        XCTAssertEqual(UpdateError.missingDigest.errorDescription, "GitHub 尚未提供更新包的 SHA-256 digest，已停止下载。")
        XCTAssertEqual(KeychainMigrationError.migrationRequired.errorDescription, "请先点击“一次性修复 Keychain”，再读取或修改已保存的 API Key。")
        XCTAssertEqual(EndpointPreset.arkCodingPlan.title, "火山方舟")
    }

    @MainActor
    func testAppModelPersistsEnglishFirstLanguagePreference() {
        let suiteName = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(model.statusMessage, "Ready")

        model.language = .simplifiedChinese
        XCTAssertEqual(defaults.string(forKey: AppModel.languageKey), "zh-Hans")
        XCTAssertEqual(L10n.language, .simplifiedChinese)

        let relaunched = AppModel(defaults: defaults, scheduleAutomaticUpdateCheck: false)
        XCTAssertEqual(relaunched.language, .simplifiedChinese)
        XCTAssertEqual(relaunched.statusMessage, "准备就绪")
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
        XCTAssertEqual(plist["CFBundleLocalizations"] as? [String], ["en", "zh-Hans"])
    }
}
