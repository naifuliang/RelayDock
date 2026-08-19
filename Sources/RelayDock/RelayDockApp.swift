import SwiftUI

@main
struct RelayDockApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("RelayDock", id: "main") {
            ContentView(model: model)
                .environment(\.locale, model.language.locale)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .defaultSize(width: 1120, height: 800)

        MenuBarExtra("RelayDock", systemImage: model.bridgeRunning ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted") {
            MenuBarView(model: model)
                .environment(\.locale, model.language.locale)
        }
    }
}
