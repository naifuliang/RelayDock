import AppKit
import Foundation

enum CursorLauncher {
    static let bundleIdentifier = "com.todesktop.230313mzl4w4u92"
    static let appURL = URL(fileURLWithPath: "/Applications/Cursor.app")
    static let executableURL = URL(fileURLWithPath: "/Applications/Cursor.app/Contents/MacOS/Cursor")

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    static var installedVersion: String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static func openNormally() throws {
        guard isInstalled else { throw LauncherError.cursorNotFound }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            running.activate(options: [.activateAllWindows])
            return
        }
        guard NSWorkspace.shared.open(appURL) else { throw LauncherError.cursorLaunchFailed }
    }

    static func terminate() async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        for application in applications { application.terminate() }
        guard !applications.isEmpty else { return }

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !isRunning { return }
        }
        throw LauncherError.cursorDidNotQuit
    }
}

enum LauncherError: LocalizedError {
    case cursorNotFound
    case cursorAlreadyRunning
    case cursorDidNotQuit
    case cursorLaunchFailed

    var errorDescription: String? {
        switch self {
        case .cursorNotFound: return L10n.t("Cursor.app was not found in /Applications.", zh: "没有在 /Applications 中找到 Cursor.app。")
        case .cursorAlreadyRunning: return L10n.t("Cursor is already running. Quit it first, or use Restart and probe.", zh: "Cursor 已经在运行。请先退出，或使用“重启并探测”。")
        case .cursorDidNotQuit: return L10n.t("Cursor did not quit within three seconds; quit it manually and retry.", zh: "Cursor 未能在三秒内退出，请手动退出后重试。")
        case .cursorLaunchFailed: return L10n.t("Could not open Cursor.app.", zh: "无法打开 Cursor.app。")
        }
    }
}
