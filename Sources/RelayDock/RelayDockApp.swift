import SwiftUI

@main
struct RelayDockApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("RelayDock", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 820, height: 620)

        MenuBarExtra("RelayDock", systemImage: model.proxyRunning ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted") {
            MenuBarView(model: model)
        }
    }
}
