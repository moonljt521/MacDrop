import SwiftUI

@main
struct MoonDropApp: App {

    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task { model.start() }
        }
    }
}
